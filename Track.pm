package Plugins::yandex::Track;

use strict;
use warnings;
use Data::Dumper;
use JSON;
use Digest::MD5 qw(md5_hex);
use Slim::Utils::Log;

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

# --- Единый, полностью асинхронный метод для получения инфы о загрузке ---
sub get_download_info {
    my $self = shift;
    my $cb = shift;
    my $url = "https://api.music.yandex.net/tracks/" . $self->{id} . "/download-info";

    $log->info("Yandex Track: calling get_download_info");

    # Защита от дурака: убедимся, что колбэк - это функция
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
            # ИСПРАВЛЕНО: $result - это уже готовый хэш с данными
            my $result = shift;
            $self->{download_info} = $result;
            $cb->($result);
        },
        sub {
            # ИСПРАВЛЕНИЕ: $error_msg - это уже готовая строка с ошибкой
            my $error_msg = shift;
            $cb->(undef, "HTTP request failed: $error_msg");
        }
    );
}





    # Slim::Networking::SimpleAsyncHTTP->new(
    #     sub {
    #         my $http = shift;
    #         my $content = $http->content;
    #         my $result;

    #         eval {
    #             $result = decode_json($content);
    #         };

    #         if ($@) {
    #             $cb->(undef, "Failed to decode JSON: $@");
    #             return;
    #         }

    #         $self->{download_info} = $result;
    #         $cb->($result);
    #     },
    #     sub {
    #         my $http = shift;
    #         my $error_msg = $http->error || 'Unknown HTTP error';
    #         $cb->(undef, "HTTP request failed: $error_msg");
    #     },
    #     {
    #         timeout => 15,
    #         cache   => 0,
    #     }
    # )->get($url);
#}


# --- ИЗМЕНЕНО: Асинхронный get_direct_url, также использующий централизованный запрос ---
sub get_direct_url {
    my $self = shift;
    my $cb = shift;

    $self->get_download_info( sub {
        my ($info, $error) = @_;

        if ($error || !$info || !$info->{result}) {
            $cb->(undef, "No download info: " . ($error || 'unknown'));
            return;
        }

        my $target_info;
        foreach my $info_item (@{$info->{result}}) {
            next unless $info_item->{codec} eq 'mp3';
            if (!$target_info || $info_item->{bitrateInKbps} > $target_info->{bitrateInKbps}) {
                $target_info = $info_item;
                last if $info_item->{bitrateInKbps} == 320;
            }
        }

        unless ($target_info && $target_info->{downloadInfoUrl}) {
            $cb->(undef, "No suitable MP3 stream found");
            return;
        }

        my $dw_url = $target_info->{downloadInfoUrl} . '&format=json';

        # --- ИСПРАВЛЕНИЕ: Используем get_raw, т.к. ответ может быть XML ---
        $self->{client}->{request}->get_raw(
            $dw_url,
            undef,
            sub {
                # ИСПРАВЛЕНИЕ: $content - это сырая строка с ответом
                my $content = shift;
                
                # Возвращаем вашу оригинальную логику парсинга
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
                my $direct_url = "https://$data->{host}/get-mp3/$sign/$data->{ts}$data->{path}";

                $cb->($direct_url);
            },
            sub {
                # ИСПРАВЛЕНИЕ: $error_msg - это строка
                my $error_msg = shift;
                $cb->(undef, "XML/JSON request failed: $error_msg");
            }
        );
    });
}


# sub get_direct_url {
#     my $self = shift;
#     #my $client = shift; не используется
#     my $cb = shift; # Это колбэк, который нужно будет вызвать в самом конце

#     # !!! ГЛАВНОЕ ИСПРАВЛЕНИЕ: Явно сохраняем колбэк !!!
#     #my $final_callback = $cb;

#     # Вызываем get_download_info и передаем ему НОВЫЙ колбэк,
#     # который будет использовать сохраненную ссылку на оригинальный колбэк
#     $self->get_download_info( sub {
#         my ($info, $error) = @_;

#         if ($error || !$info || !$info->{result}) {
#             # Используем явную ссылку на оригинальный колбэк
#             $cb->(undef, "No download info: " . ($error || 'unknown'));
#             return;
#         }

#         # ... (ваша логика поиска target_info остается без изменений) ...
#         my $target_info;
#         foreach my $info_item (@{$info->{result}}) {
#             next unless $info_item->{codec} eq 'mp3';
#             if (!$target_info || $info_item->{bitrateInKbps} > $target_info->{bitrateInKbps}) {
#                 $target_info = $info_item;
#                 last if $info_item->{bitrateInKbps} == 320;
#             }
#         }

#         unless ($target_info && $target_info->{downloadInfoUrl}) {
#             $cb->(undef, "No suitable MP3 stream found");
#             return;
#         }

#         my $dw_url = $target_info->{downloadInfoUrl} . '&format=json';

#         # Второй асинхронный запрос. Здесь все критично важно.
#         Slim::Networking::SimpleAsyncHTTP->new(
#             sub {
#                 my $http = shift;
#                 my $content = $http->content;
#                 # ... (ваша логика парсинга остается без изменений) ...
#                 my $data = eval { decode_json($content) };
#                 if ($@) {
#                     my ($host, $path, $ts, $s) = $content =~ /host="([^"]+)"\s+path="([^"]+)"\s+ts="([^"]+)"\s+s="([^"]+)"/;
#                     unless ($host && $path && $ts && $s) {
#                         $cb->(undef, "Failed to parse response as JSON or XML");
#                         return;
#                     }
#                     $data = {
#                         host => $host,
#                         path => $path,
#                         ts => $ts,
#                         s => $s,
#                     };
#                 }
#                 my $sign = md5_hex("XGRlBW9FXlekgbPrRHuSiA" . substr($data->{path}, 1) . $data->{s});
#                 my $direct_url = "https://$data->{host}/get-mp3/$sign/$data->{ts}$data->{path}";

#                 # !!! ВЫЗЫВАЕМ ЯВНО СОХРАНЕННЫЙ КОЛБЭК !!!
#                 $cb->($direct_url);
#             },
#             sub {
#                 my $http = shift;
#                 $cb->(undef, "XML/JSON request failed: " . $http->error);
#             },
#             {
#                 timeout => 15,
#                 cache   => 0,
#             }
#         )->get($dw_url);
#     });
# }


# Старые методы 




# sub download {
#     my ($self, $client, $filename) = @_;

#     unless ($self->{download_info}) {
#         $self->get_download_info($client);
#     }

#     foreach my $info (@{$self->{download_info}}) {
#         if ($info->{directLink}) {
#             my $url = $info->{host} . "/get-mp3/" . $info->{path} . "?track-id=$self->{id}&play=false";
#             #print "Скачиваем $url\n";
#             my $res = $client->{request}->{ua}->get($url, ':content_file' => $filename);
#             if ($res->is_success) {
#                 print "Сохранено как $filename\n";
#                 return 1;
#             } else {
#                 die "Ошибка загрузки: " . $res->status_line;
#             }
#         }
#     }

#     die "Невозможно скачать трек — нет доступных ссылок";
# }

1;