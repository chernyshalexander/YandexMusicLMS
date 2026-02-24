package Plugins::yandex::Track;

use strict;
use warnings;
use Data::Dumper;
use JSON::XS::VersionOneAndTwo;
use Digest::MD5 qw(md5_hex);
use Slim::Utils::Log;
use Slim::Networking::SimpleAsyncHTTP;

# XML::Simple может быть причиной проблем
# use XML::Simple;


my $log = logger('plugin.yandex');

sub new {
    my ($class, $data,$client) = @_;
    $log->debug("Yandex Track: calling constructor NEW");
    my $self = bless {
        raw => $data,
        id => $data->{id},
        title => $data->{title},
        artists => $data->{artists},
        albums => $data->{albums},
        duration_ms => $data->{durationMs},
        available => $data->{available},
        download_info => undef,
        client     => $client,
    }, $class;
    return $self;
}

#  асинхронный метод для получения инфы о загрузке 
sub get_download_info {
    my $self = shift;
    my $cb = shift;
    my $url = "https://api.music.yandex.net/tracks/" . $self->{id} . "/download-info";

    $log->info("Yandex Track: calling get_download_info");

    # убедимся, что колбэк - это функция
    unless (defined $cb && ref($cb) eq 'CODE') {
        # Логируем критическую ошибку и выходим
         $log->error("Yandex Track: get_download_info called without a valid callback!");
        return;
    }


    
    $log->info("Yandex Track: get_download_info");

    # Всегда используем асинхронный запрос
    # Используем стандартный get, т.к. ответ гарантированно в JSON
    $self->{client}->{request}->get(
        $url,
        undef,
        sub {
            #  $result - это уже готовый хэш с данными
            my $result = shift;
            $self->{download_info} = $result;
            $cb->($result);
        },
        sub {
            #  $error_msg - это уже готовая строка с ошибкой
            my $error_msg = shift;
            $cb->(undef, "HTTP request failed: $error_msg");
        }
    );
}



# Асинхронный get_direct_url,  использующий централизованный запрос 
sub get_direct_url {
    my $self = shift;
    my $cb = shift;

    $self->get_download_info( sub {
        my ($info, $error) = @_;

        if ($error || !$info || !$info->{result}) {
            $cb->(undef, "No download info: " . ($error || 'unknown'));
            return;
        }

        my $max_bitrate = Slim::Utils::Prefs::preferences('plugin.yandex')->get('max_bitrate') || 320;
        my $target_info;
        
        # Sort available streams by bitrate descending
        my @sorted_info = sort { $b->{bitrateInKbps} <=> $a->{bitrateInKbps} } 
                          grep { $_->{codec} eq 'mp3' } 
                          @{$info->{result}};

        # Find the highest bitrate that is <= max_bitrate
        foreach my $info_item (@sorted_info) {
            if ($info_item->{bitrateInKbps} <= $max_bitrate) {
                $target_info = $info_item;
                last;
            }
        }
        
        # Fallback: if all streams are strictly higher than max_bitrate, just pick the lowest available one
        if (!$target_info && @sorted_info) {
            $target_info = $sorted_info[-1];
        }

        unless ($target_info && $target_info->{downloadInfoUrl}) {
            $cb->(undef, "No suitable MP3 stream found");
            return;
        }

        my $dw_url = $target_info->{downloadInfoUrl} . '&format=json';

        # Используем get_raw, т.к. ответ может быть XML
        $self->{client}->{request}->get_raw(
            $dw_url,
            undef,
            sub {
                #  $content - это raw строка с ответом
                my $content = shift;
                
                  my $data = eval { decode_json($content) };
                if ($@) {
                    my ($host, $path, $ts, $s) = $content =~ /host="([^"]+)"\s+path="([^"]+)"\s+ts="([^"]+)"\s+s="([^"]+)"/;
                    unless ($host && $path && $ts && $s) {
                        $cb->(undef, "Failed to parse response as JSON or XML");
                        return;
                    }
                    $data = {
                        host => $host,
                        path => $path,
                        ts => $ts,
                        s => $s,
                    };
                }
                my $sign = md5_hex("XGRlBW9FXlekgbPrRHuSiA" . substr($data->{path}, 1) . $data->{s});
                my $initial_direct_url = "https://$data->{host}/get-mp3/$sign/$data->{ts}$data->{path}";

                # Resolve potential 308 Redirect 
                $log->info("YANDEX: Resolving redirect for: $initial_direct_url");
                
                my $http_resolver = Slim::Networking::SimpleAsyncHTTP->new(
                    sub {
                        my $http = shift;
                        
                        # Пытаемся получить код ответа и заголовки разными способами
                        my $code = $http->code || 200;
                        
                        # Если это редирект (308, 301, 302)
                        if ($code =~ /^30/) {
                            my $location;
                            # Способ 1: через метод headers
                            if ($http->can('headers')) {
                                $location = $http->headers->header('Location');
                            }
                            # Способ 2: через params (иногда headers там)
                            elsif ($http->can('params') && $http->params && $http->params->{headers}) {
                                $location = $http->params->{headers}->{'Location'};
                            }
                            
                            if ($location) {
                                $log->info("YANDEX: Resolved redirect $code. New URL: $location");
                                $cb->($location, undef, $target_info->{bitrateInKbps} * 1000);
                                return;
                            }
                        }
                        
                        $log->info("YANDEX: No redirect detected (Code: $code) or Location missing. Using original URL.");
                        $cb->($initial_direct_url, undef, $target_info->{bitrateInKbps} * 1000);
                    },
                    sub {
                        my ($http, $error) = @_;
                        $log->warn("YANDEX: Redirect resolution failed ($error). Using original URL.");
                        $cb->($initial_direct_url, undef, $target_info->{bitrateInKbps} * 1000);
                    },
                    {
                        maxRedirects => 0,
                        timeout => 10,
                    }
                );
                
                $http_resolver->head($initial_direct_url);
            },
            sub {
                # $error_msg - это строка
                my $error_msg = shift;
                $cb->(undef, "XML/JSON request failed: $error_msg");
            }
        );
    });
}



1;