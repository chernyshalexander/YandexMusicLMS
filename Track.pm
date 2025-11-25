package Plugins::yandex::Track;

use strict;
use warnings;
use Data::Dumper;
use File::Slurp;
use JSON;
use Digest::MD5 qw(md5_hex);
use XML::Simple; # Или используйте JSON, если ответ приходит в JSON, но обычно там XML

sub new {
    my ($class, $data) = @_;
    my $self = {
        raw => $data,
        id => $data->{id},
        title => $data->{title},
        artists => $data->{artists},
        albums => $data->{albums},
        duration_ms => $data->{durationMs},
        available => $data->{available},
        download_info => undef,
    };
    bless $self, $class;
    return $self;
}

sub get_download_info {
    my ($self, $client) = @_;
    my $result = $client->{request}->get("https://api.music.yandex.net/tracks/" . $self->{id} . "/download-info");
    #print Dumper($result);
    #write_file('debug-dw-info.json', encode_json($result));
    $self->{download_info} = $result;
}
sub get_stream_url {
    my ($self, $client) = @_;

    # 1. Получаем инфо о загрузке
    unless ($self->{download_info}) {
        $self->get_download_info($client);
    }
    
    # 2. Ищем downloadInfoUrl с самым высоким битрейтом
    my $target_info;
    foreach my $info (@{$self->{download_info}->{result} || []}) {
        # Приоритет MP3 320, но можно брать первый попавшийся mp3
        if ($info->{codec} eq 'mp3') {
            $target_info = $info;
            last if $info->{bitrateInKbps} == 320;
        }
    }
    
    return undef unless $target_info && $target_info->{downloadInfoUrl};

    # 3. Делаем запрос к downloadInfoUrl
    my $dw_url = $target_info->{downloadInfoUrl};
    my $res_xml = $client->{request}->{ua}->get($dw_url);
    
    unless ($res_xml->is_success) {
        die "Failed to fetch download info XML";
    }

    # 4. Парсим XML (ответ приходит вида <download-info><host>...</host><path>...</path><ts>...</ts><s>...</s></download-info>)
    # Если XML::Simple недоступен, можно использовать regex, так как структура простая
    my $content = $res_xml->decoded_content;
    
    my ($host) = $content =~ /<host>(.*?)<\/host>/;
    my ($path) = $content =~ /<path>(.*?)<\/path>/;
    my ($ts)   = $content =~ /<ts>(.*?)<\/ts>/;
    my ($s)    = $content =~ /<s>(.*?)<\/s>/;

    unless ($host && $path && $ts && $s) {
        # Иногда ответ бывает в JSON, проверим
        my $data = eval { decode_json($content) };
        if ($data) {
             $host = $data->{host};
             $path = $data->{path};
             $ts = $data->{ts};
             $s = $data->{s};
        }
    }

    return undef unless ($host && $path && $ts && $s);

    # 5. Генерируем подпись
    # Соль жестко зашита в приложениях Яндекса
    my $salt = 'XGRlBW9FXlekgbPrRHuSiA';
    my $sign = md5_hex($salt . substr($path, 1) . $s);

    # 6. Формируем финальную ссылку
    my $final_url = "https://$host/get-mp3/$sign/$ts$path";
    
    return $final_url;
}
sub get_direct_url {
    my ($self, $cb) = @_;

    $self->get_download_info(sub {
        my ($info, $error) = @_;

        if ($error || !$info || !$info->{downloadInfoUrl}) {
            $cb->(undef, "No download info: " . ($error || 'unknown'));
            return;
        }

        my $url = $info->{downloadInfoUrl} . '&format=json';

        Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                my $response = shift;
                my $xml = $response->content;

                if ($xml =~ /host="([^"]+)"\s+path="([^"]+)"\s+ts="([^"]+)"\s+s="([^"]+)"/) {
                    my ($host, $path, $ts, $s) = ($1, $2, $3, $4);

                    my $sign = Digest::MD5::md5_hex("XGRlBW9FXlekgbPrRHuSiA" . substr($path, 1) . $s);
                    my $direct_url = "https://$host/get-mp3/$sign/$ts$path";

                    $cb->($direct_url);
                } else {
                    $cb->(undef, "Failed to parse XML: no host/path/ts/s");
                }
            },
            sub {
                my $http = shift;
                $cb->(undef, "XML request failed: " . $http->error);
            },
            {
                timeout => 15,
                cache   => 0,
            }
        )->get($url);
    });
}

sub download {
    my ($self, $client, $filename) = @_;

    unless ($self->{download_info}) {
        $self->get_download_info($client);
    }

    foreach my $info (@{$self->{download_info}}) {
        if ($info->{directLink}) {
            my $url = $info->{host} . "/get-mp3/" . $info->{path} . "?track-id=$self->{id}&play=false";
            #print "Скачиваем $url\n";
            my $res = $client->{request}->{ua}->get($url, ':content_file' => $filename);
            if ($res->is_success) {
                print "Сохранено как $filename\n";
                return 1;
            } else {
                die "Ошибка загрузки: " . $res->status_line;
            }
        }
    }

    die "Невозможно скачать трек — нет доступных ссылок";
}

1;