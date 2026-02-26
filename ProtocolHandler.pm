package Plugins::yandex::ProtocolHandler;

use strict;
use warnings;
use Slim::Utils::Log;
use Slim::Utils::Cache;
use base qw(Slim::Player::Protocols::HTTPS);
use JSON::XS::VersionOneAndTwo;
use URI::Escape;

require Slim::Player::Playlist;
require Slim::Player::Source;
require Slim::Control::Request;
require Plugins::yandex::Track;

my $log = logger('plugin.yandex');

# 1. КОНСТРУКТОР 
sub new {
    my $class  = shift;
    my $args   = shift;

    my $client    = $args->{client};
    my $song      = $args->{song};
    
    # Берем URL, который должен быть уже установлен в getNextTrack
    my $streamUrl = $song->streamUrl() || return;

    $log->error("YANDEX: Handler new() called for REAL streamUrl: $streamUrl");

    my $sock = $class->SUPER::new( {
        url     => $streamUrl,
        song    => $song,
        client  => $client,
    } ) || return;

    # Устанавливаем тип контента
    ${*$sock}{contentType} = 'audio/mpeg';

    # Пробуем установить параметры потока явно, чтобы LMS знал, что это не бесконечный поток
    # и отображал прогресс бар.

    if ($client) {
         my $duration = $song->duration || 0;
         my $artist = 'Unknown';
         my $title = 'Unknown';

         # Используем оригинальный URL трека (yandexmusic://...) для поиска в кеше
         my $original_url = $song->currentTrack ? $song->currentTrack->url : $streamUrl;
         
         if (!$duration && $original_url =~ /yandexmusic:\/\/(\d+)/) {
             my $track_id = $1;
             my $cache = Slim::Utils::Cache->new();
             my $meta = $cache->get('yandex_meta_' . $track_id);
             
             if ($meta && $meta->{duration}) {
                 $duration = $meta->{duration};
                 $artist = $meta->{artist} if $meta->{artist};
                 $title = $meta->{title} if $meta->{title};
                 $log->info("YANDEX: Found cached metadata for $track_id: Duration=$duration");
             } else {
                 $log->warn("YANDEX: Metadata cache miss for $track_id");
             }
         }

         # -----------------------------------------------------------------------------------------
         # РОТОР: Бесконечное радио и отправка фидбека при старте трека
         # -----------------------------------------------------------------------------------------
         if ($original_url =~ /rotor_station=([^&]+)&batch_id=([^&]+)/) {
             my $station = URI::Escape::uri_unescape($1);
             my $batch_id = URI::Escape::uri_unescape($2);
             my $track_id = ($original_url =~ /yandexmusic:\/\/(\d+)/)[0];
             
             my $yandex_client = Plugins::yandex::Plugin->getClient();
             if ($yandex_client) {
                 $log->info("YANDEX ROTOR: Sending trackStarted for $station, batch $batch_id, track $track_id");
                 $yandex_client->rotor_station_feedback($station, 'trackStarted', $batch_id, $track_id, 0, sub {}, sub {});
                 
                 # Проверяем длину очереди: если до конца осталось 2 или меньше треков, докидываем 5 новых
                 my $playlist_size = Slim::Player::Playlist::count($client);
                 my $current_index = Slim::Player::Source::playingSongIndex($client);
                 
                 if (defined $playlist_size && defined $current_index && ($playlist_size - $current_index) <= 2) {
                     $log->info("YANDEX ROTOR: Queue running low ($current_index/$playlist_size). Fetching next batch...");
                     $yandex_client->rotor_station_tracks($station, $track_id, sub {
                         my $result = shift;
                         if ($result->{tracks}) {
                             foreach my $track_obj (@{$result->{tracks}}) {
                                 Plugins::yandex::Plugin::cache_track_metadata($track_obj);
                                 my $new_url = 'yandexmusic://' . $track_obj->{id} . 
                                               '?rotor_station=' . URI::Escape::uri_escape_utf8($station) . 
                                               '&batch_id=' . URI::Escape::uri_escape_utf8($result->{batch_id});
                                 Slim::Control::Request::executeRequest($client, ['playlist', 'add', $new_url]);
                             }
                         }
                     }, sub {
                         my $err = shift;
                         $log->error("YANDEX ROTOR: Failed to fetch next batch: $err");
                     });
                 }
             }
         }
         # -----------------------------------------------------------------------------------------

         $log->warn("YANDEX: Setting duration $duration and isLive=0 for song " . ($song->currentTrack ? $song->currentTrack->url : 'unknown'));

         # Устанавливаем на переданном объекте $song (это объект Slim::Player::Song)
         $song->isLive(0);
         $song->duration($duration);
         
         # Также обновляем мету через Slim::Music::Info, чтобы UI подхватил
         if ($song->currentTrack) {
             Slim::Music::Info::setDuration($song->currentTrack, $duration);
         }
    }

    return $sock;
}

# --- 2. canDirectStreamSong
# ПОЧЕМУ 0 (PROXY): Яндекс обрывает длительные соединения (Connection reset by peer).
# Железные плееры и софтовые (SqueezeLite, SqueezePlay) и даже  качают поток со скоростью битрейта (~40kbps).
# Через пару минут Яндекс разрывает соединение из-за "медленного" клиента.
# Proxy-режим (0) заставляет сервер LMS быстро выкачать весь трек целиком (как браузер) 
# во временный локальный файл (Buffered), а плееры уже тянут его по локальной сети без обрывов.

sub canDirectStreamSong {
    my ($class, $client, $song) = @_;
    $log->info("YANDEX: Forcing proxy for streamUrl: " . $song->streamUrl());
    return 0;
}

# --- 3. canEnhanceHTTP
# ПРИНУДИТЕЛЬНО ВКЛЮЧАЕМ БУФЕРИЗАЦИЮ (Buffered Mode = 2).
# Без этого LMS может работать в режиме прямого прокси, скачивая данные со скоростью плеера.
# Режим 2 заставляет LMS максимально быстро выкачать весь файл целиком в локальный .buf файл.
sub canEnhanceHTTP {
    return 2; # 2 = BUFFERED constant in Slim::Player::Protocols::HTTP
}

# 3. scanUrl 
sub scanUrl {
    my ($class, $url, $args) = @_;
    $args->{cb}->( $args->{song}->currentTrack() );
}

# 4. getNextTrack (АСИНХРОННЫЙ ВЫЗОВ) 
sub getNextTrack {
    my ($class, $song, $successCb, $errorCb) = @_;

    my $url = $song->currentTrack()->url;
    $log->error("YANDEX: getNextTrack called for: $url");

    my $track_id = $url;
    unless ($url =~ /yandexmusic:\/\/(?:track\/)?(\d+)/) {
        $log->error("YANDEX: Can't parse ID from URL: $url");
        $errorCb->('Invalid URL format');
        return;
    }
    $track_id = $1;

    # Получаем экземпляр клиента из Plugin
    my $yandex_client = Plugins::yandex::Plugin->getClient();

    unless ($yandex_client) {
        $log->error("YANDEX: Could not get Yandex client instance. Plugin might not be initialized.");
        $errorCb->('Plugin not initialized');
        return;
    }

    # Создаем объект трека. 
    my $track = Plugins::yandex::Track->new({ id => $track_id },$yandex_client);

    #  Вызываем АСИНХРОННЫЙ метод из Track.pm 
    $track->get_direct_url(sub {
        my ($final_url, $error, $bitrate) = @_;

        if ($final_url) {
            $log->info("YANDEX: ASYNC URL resolved: $final_url, Bitrate: " . ($bitrate || "unknown"));
            
            # Сохраняем битрейт в кеш, если он есть
            if ($bitrate) {
                my $cache = Slim::Utils::Cache->new();
                if (my $cached_meta = $cache->get('yandex_meta_' . $track_id)) {
                    $cached_meta->{bitrate} = $bitrate;
                    $cache->set('yandex_meta_' . $track_id, $cached_meta, 3600);
                }
            }

            # Устанавливаем реальную ссылку в объект песни
            $song->streamUrl($final_url);
            
            # Сообщаем об успехе
            $successCb->();
        } else {
            $log->error("YANDEX: ASYNC URL resolution failed: $error");
            # Сообщаем об ошибке
            $errorCb->($error);
        }
    });
}


sub getFormatForURL { 'mp3' }
sub isRemote { 1 }
sub isAudio { 1 }

sub getMetadataFor {
    my ($class, $client, $url) = @_;
    
    # Пытаемся найти в кеше
    if ($url =~ /yandexmusic:\/\/(\d+)/) {
        my $track_id = $1;
        my $cache = Slim::Utils::Cache->new();
        if (my $cached_meta = $cache->get('yandex_meta_' . $track_id)) {
            $log->debug("YANDEX: Returning cached metadata for $url");
            
            my $bitrate = $cached_meta->{bitrate} || 192000;
            
            # Сохраняем значения в БД LMS для корректной работы перемотки (canSeek)
            eval {
                Slim::Music::Info::setBitrate($url, $bitrate);
                Slim::Music::Info::setDuration($url, $cached_meta->{duration}) if $cached_meta->{duration};
                
                # Обновляем также объекты трека, если сейчас что-то играет
                if ($client && $client->playingSong() && $client->playingSong()->track() && $client->playingSong()->track()->url() eq $url) {
                    $client->playingSong()->bitrate($bitrate);
                    $client->playingSong()->duration($cached_meta->{duration}) if $cached_meta->{duration};
                }
            };

            return {
                title    => $cached_meta->{title},
                artist   => $cached_meta->{artist},
                duration => $cached_meta->{duration},
                cover    => $cached_meta->{cover},
                icon     => $cached_meta->{cover},
                bitrate  => sprintf("%.0fkbps", $bitrate/1000), # UI format
                type     => 'mp3',
            };
        }
    }

    return {};
}

sub getIcon {
    my ($class, $url) = @_;
    
    if ($url =~ /yandexmusic:\/\/(\d+)/) {
        my $track_id = $1;
        my $cache = Slim::Utils::Cache->new();
        if (my $cached_meta = $cache->get('yandex_meta_' . $track_id)) {
            return $cached_meta->{cover} if $cached_meta->{cover};
        }
    }
    
    return 'plugins/yandex/html/images/yandex.png';
}

sub explodePlaylist {
	my ($class, $client, $url, $cb) = @_;

	my $yandex_client = Plugins::yandex::Plugin->getClient();
	unless ($yandex_client) {
		$cb->([]);
		return;
	}

	if ($url =~ /yandexmusic:\/\/rotor\/(.+)/) {
		my $station_id = $1;
		
		# Шлем сигнал начала радио (radioStarted)
		$yandex_client->rotor_station_feedback($station_id, 'radioStarted', undef, undef, 0, sub {}, sub {});
		
		# Получаем первые 5 треков
		$yandex_client->rotor_station_tracks($station_id, undef, sub {
			my $result = shift;
			my @tracks;
			if ($result->{tracks}) {
				foreach my $track_obj (@{$result->{tracks}}) {
					Plugins::yandex::Plugin::cache_track_metadata($track_obj);
					push @tracks, 'yandexmusic://' . $track_obj->{id} . 
                                  '?rotor_station=' . URI::Escape::uri_escape_utf8($station_id) . 
                                  '&batch_id=' . URI::Escape::uri_escape_utf8($result->{batch_id});
				}
			}
			$cb->(\@tracks);
		}, sub { $cb->([]) });
	}
	# yandexmusic://album/123
	elsif ($url =~ /yandexmusic:\/\/album\/(\d+)/) {
		my $album_id = $1;
		$yandex_client->get_album_with_tracks($album_id, sub {
			my $album = shift;
			my @tracks;
			if ($album->{volumes}) {
				foreach my $disks (@{$album->{volumes}}) {
					push @tracks, map { 
                        Plugins::yandex::Plugin::cache_track_metadata($_);
                        'yandexmusic://' . $_->{id} 
                    } @$disks;
				}
			}
			$cb->(\@tracks);
		}, sub { $cb->([]) });
	}
	# yandexmusic://playlist/USER_ID/KIND
	elsif ($url =~ /yandexmusic:\/\/playlist\/([^\/]+)\/(\d+)/) {
		my ($user_id, $kind) = ($1, $2);
		$yandex_client->get_playlist($user_id, $kind, sub {
			my $playlist = shift;
			my @tracks;
			if ($playlist->{tracks}) {
				foreach my $item (@{$playlist->{tracks}}) {
                    my $track_obj = $item->{track} ? $item->{track} : $item;
                    Plugins::yandex::Plugin::cache_track_metadata($track_obj);
					push @tracks, 'yandexmusic://' . ($track_obj->{id});
				}
			}
			$cb->(\@tracks);
		}, sub { $cb->([]) });
	}
	# yandexmusic://artist/123
	elsif ($url =~ /yandexmusic:\/\/artist\/(\d+)/) {
		my $artist_id = $1;
		$yandex_client->get_artist_tracks($artist_id, sub {
			my $tracks = shift;
			my @items = map { 
                Plugins::yandex::Plugin::cache_track_metadata($_);
                'yandexmusic://' . $_->{id} 
            } @$tracks;
			$cb->(\@items);
		}, sub { $cb->([]) });
	}
	# yandexmusic://favorites/tracks
	elsif ($url =~ /yandexmusic:\/\/favorites\/tracks/) {
		$yandex_client->users_likes_tracks(sub {
			my $tracks_short = shift;
            my @track_ids = map { $_->{id} } @$tracks_short;
            
            if (!@track_ids) {
                $cb->([]);
                return;
            }

            my @all_tracks_detailed;
            my $chunk_size = 50; 
            my @chunks;
            while (@track_ids) {
                push @chunks, [ splice(@track_ids, 0, $chunk_size) ];
            }
            my $pending_chunks = scalar @chunks;

            foreach my $chunk_ids (@chunks) {
                $yandex_client->tracks(
                    $chunk_ids,
                    sub {
                        my $tracks_chunk = shift;
                        push @all_tracks_detailed, @$tracks_chunk;
                        $pending_chunks--;
                        if ($pending_chunks == 0) {
                            my @items = map { 
                                Plugins::yandex::Plugin::cache_track_metadata($_);
                                'yandexmusic://' . $_->{id} 
                            } @all_tracks_detailed;
                            $cb->(\@items);
                        }
                    },
                    sub {
                        $pending_chunks--;
                        if ($pending_chunks == 0) {
                            my @items = map { 
                                Plugins::yandex::Plugin::cache_track_metadata($_);
                                'yandexmusic://' . $_->{id} 
                            } @all_tracks_detailed;
                            $cb->(\@items);
                        }
                    }
                );
            }
		}, sub { $cb->([]) });
	}
	else {
		$cb->([$url]);
	}
}

sub canDoAction {
    my ($class, $client, $url, $action) = @_;
    return 1 if $action =~ /^(pause|stop|seek|rew|fwd)$/;
    return 0;
}

1;