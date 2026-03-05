package Plugins::yandex::ProtocolHandler;

use strict;
use warnings;
use Slim::Utils::Log;
use Slim::Utils::Cache;
use base qw(Slim::Player::Protocols::HTTPS);
use JSON::XS;
use URI::Escape;
use Slim::Utils::Prefs;

require Slim::Player::Playlist;
require Slim::Player::Source;
require Slim::Control::Request;
require Plugins::yandex::Track;

my $log = logger('plugin.yandex');
my $prefs = preferences('plugin.yandex');

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
         if ($original_url =~ /rotor_station=([^&]+)/) {
             my $station = URI::Escape::uri_unescape($1);
             my $batch_id = ($original_url =~ /batch_id=([^&]+)/) ? URI::Escape::uri_unescape($1) : undef;
             my $track_id = ($original_url =~ /yandexmusic:\/\/(?:track\/)?(\d+)/)[0];
             
             # Extract extra params (moodEnergy, diversity, etc)
             my %extra_params;
             if ($original_url =~ /\?(.*)$/) {
                 my $query = $1;
                 foreach my $pair (split /&/, $query) {
                     my ($k, $v) = split /=/, $pair;
                     next if !$k || !$v || $k =~ /^(rotor_station|batch_id)$/;
                     $extra_params{$k} = $v;
                 }
             }

             my $yandex_client = Plugins::yandex::Plugin->getClient();
             if ($yandex_client) {
                 # Фидбек trackStarted уже отправляется из Plugin.pm (playerEventCallback), 
                 # поэтому здесь мы его не отправляем повторно.
                 
                 # Проверяем длину очереди: если до конца осталось 2 или меньше треков, докидываем порцию новых
                 my $playlist_size = Slim::Player::Playlist::count($client);
                 my $current_index = Slim::Player::Source::playingSongIndex($client);
                 
                 if (defined $playlist_size && defined $current_index && ($playlist_size - $current_index) <= 2) {
                     $log->info("YANDEX ROTOR SESSION: Queue running low ($current_index/$playlist_size). Fetching next batch...");
                     $yandex_client->rotor_station_tracks($station, $track_id, sub {
                         my $result = shift;
                         if ($result->{tracks}) {
                             my $remove_duplicates = $prefs->client($client)->get('remove_duplicates');
                             my $seen_tracks = $prefs->client($client)->get('yandex_seen_tracks') || [];
                             my %seen_map = map { $_ => 1 } @$seen_tracks;
                             my $added_count = 0;
                             
                             foreach my $track_obj (@{$result->{tracks}}) {
                                 my $tid = $track_obj->{id};
                                 
                                 # Skip if filtering duplicates is enabled and track was seen
                                 next if $remove_duplicates && $seen_map{$tid};
                                 
                                 if (!$seen_map{$tid}) {
                                     $seen_map{$tid} = 1;
                                     push @$seen_tracks, $tid;
                                 }
                                 $added_count++;
                                     
                                     Plugins::yandex::Plugin::cache_track_metadata($track_obj);
                                     
                                     # Construct NEW url including extra params
                                     my $new_url = 'yandexmusic://' . $track_obj->{id} . 
                                                   '?rotor_station=' . URI::Escape::uri_escape_utf8($station) . 
                                                   '&batch_id=' . URI::Escape::uri_escape_utf8($result->{batch_id});
                                     foreach my $k (keys %extra_params) {
                                         $new_url .= '&' . $k . '=' . $extra_params{$k};
                                     }

                                     Slim::Control::Request::executeRequest($client, ['playlist', 'add', $new_url]);
                                 }
                                 $prefs->client($client)->set('yandex_seen_tracks', $seen_tracks);
                                 $log->info("YANDEX ROTOR SESSION: Added $added_count new tracks (filtered duplicates)");
                             }
                     }, sub {
                         my $err = shift;
                         $log->error("YANDEX ROTOR: Failed to fetch next batch: $err");
                     }, \%extra_params);
                 }
             }
         }
         elsif ($original_url =~ /rotor_session=([^&]+)/) {
             my $radio_session_id = URI::Escape::uri_unescape($1);
             my $batch_id = ($original_url =~ /batch_id=([^&]+)/) ? URI::Escape::uri_unescape($1) : undef;
             my $track_id = ($original_url =~ /yandexmusic:\/\/(?:track\/)?(\d+)/)[0];
             
             my $yandex_client = Plugins::yandex::Plugin->getClient();
             if ($yandex_client) {
                 my $playlist_size = Slim::Player::Playlist::count($client);
                 my $current_index = Slim::Player::Source::playingSongIndex($client);
                 
                 if (defined $playlist_size && defined $current_index && ($playlist_size - $current_index) <= 2) {
                     $log->info("YANDEX NEW ROTOR SESSION: Queue running low ($current_index/$playlist_size). Fetching next sequence...");
                     $yandex_client->rotor_session_tracks($radio_session_id, $track_id, sub {
                         my $result = shift;
                         if ($result->{tracks}) {
                             my $remove_duplicates = $prefs->client($client)->get('remove_duplicates');
                             my $seen_tracks = $prefs->client($client)->get('yandex_seen_tracks') || [];
                             my %seen_map = map { $_ => 1 } @$seen_tracks;
                             my $added_count = 0;
                             
                             foreach my $track_obj (@{$result->{tracks}}) {
                                 my $tid = $track_obj->{id};
                                 
                                 # Skip if filtering duplicates is enabled and track was seen
                                 next if $remove_duplicates && $seen_map{$tid};
                                 
                                 if (!$seen_map{$tid}) {
                                     $seen_map{$tid} = 1;
                                     push @$seen_tracks, $tid;
                                 }
                                 $added_count++;
                                     
                                     Plugins::yandex::Plugin::cache_track_metadata($track_obj);
                                     
                                     my $new_url = 'yandexmusic://' . $track_obj->{id} . 
                                                   '?rotor_session=' . URI::Escape::uri_escape_utf8($radio_session_id) . 
                                                   '&batch_id=' . URI::Escape::uri_escape_utf8($result->{batch_id});
                                     
                                     Slim::Control::Request::executeRequest($client, ['playlist', 'add', $new_url]);
                                 }
                                 $prefs->client($client)->set('yandex_seen_tracks', $seen_tracks);
                                 $log->info("YANDEX NEW ROTOR SESSION: Added $added_count new tracks");
                             }
                     }, sub {
                         my $err = shift;
                         $log->error("YANDEX NEW ROTOR: Failed to fetch next sequence: $err");
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
                album    => $cached_meta->{album},
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

	if ($url =~ /^yandexmusic:\/\/rotor\/([^\?]+)(?:\?(.*))?/) {
		my $station_id = $1;
        my $query_str = $2;
        my %extra_params;
        if ($query_str) {
            foreach my $pair (split /&/, $query_str) {
                my ($k, $v) = split /=/, $pair;
                $extra_params{$k} = $v if $k && $v;
            }
        }
		
		# Шлем сигнал начала радио (radioStarted)
		$yandex_client->rotor_station_feedback($station_id, 'radioStarted', undef, undef, 0, sub {}, sub {});
		
		# Очищаем историю прослушанных треков при новом запуске радиостанции
		$prefs->client($client)->set('yandex_seen_tracks', []) if $client;
		
		# Получаем первые треки
		$yandex_client->rotor_station_tracks($station_id, undef, sub {
			my $result = shift;
			my @tracks;
			if ($result->{tracks}) {
				my $remove_duplicates = $prefs->client($client)->get('remove_duplicates');
				my $seen_tracks = [];
                my %seen_map = ();
				foreach my $track_obj (@{$result->{tracks}}) {
                    my $tid = $track_obj->{id};
                    next if $remove_duplicates && $seen_map{$tid};
                    
                    if (!$seen_map{$tid}) {
                        $seen_map{$tid} = 1;
                        push @$seen_tracks, $tid;
                    }
					Plugins::yandex::Plugin::cache_track_metadata($track_obj);
                    
					my $new_url = 'yandexmusic://' . $track_obj->{id} . 
                                  '?rotor_station=' . URI::Escape::uri_escape_utf8($station_id) . 
                                  '&batch_id=' . URI::Escape::uri_escape_utf8($result->{batch_id});
                    if ($query_str) {
                        $new_url .= '&' . $query_str;
                    }
                    push @tracks, $new_url;
				}
				$prefs->client($client)->set('yandex_seen_tracks', $seen_tracks) if $client;
			}
			$cb->(\@tracks);
		}, sub { $cb->([]) }, \%extra_params);
	}
	elsif ($url =~ /^yandexmusic:\/\/rotor_session\/([^\?]+)(?:\?(.*))?/) {
		my $station_id = $1;
        my $query_str = $2;
        
		$log->info("YANDEX NEW ROTOR: Exploding session for station $station_id...");

		# 1. Create session
		$yandex_client->rotor_session_new($station_id, sub {
			my $session_result = shift;
			my $radio_session_id = $session_result->{radioSessionId};
			my $batch_id = $session_result->{batchId};
			my $sequence = $session_result->{sequence}; # This is an array of items with { track => { ... } }

			# 2. Send radioStarted feedback
			require Plugins::yandex::ProtocolHandler; # for timestamp
			my $timestamp = Plugins::yandex::ProtocolHandler::_get_current_timestamp();
			$yandex_client->rotor_session_feedback($radio_session_id, $batch_id, 'radioStarted', $station_id, 0, $timestamp, sub {}, sub {});

			# 3. Process tracks
			my @tracks;
			my $seen_tracks = [];
            my %seen_map = ();
			my $remove_duplicates = $prefs->client($client)->get('remove_duplicates');

			if ($sequence && ref $sequence eq 'ARRAY') {
				foreach my $item (@$sequence) {
					my $track_obj = $item->{track};
					next unless $track_obj;
					my $tid = $track_obj->{id};

					next if $remove_duplicates && $seen_map{$tid};
					
					if (!$seen_map{$tid}) {
                        $seen_map{$tid} = 1;
                        push @$seen_tracks, $tid;
                    }
					
					Plugins::yandex::Plugin::cache_track_metadata($track_obj);
					
					my $new_url = 'yandexmusic://' . $track_obj->{id} . 
                                  '?rotor_session=' . URI::Escape::uri_escape_utf8($radio_session_id) . 
                                  '&batch_id=' . URI::Escape::uri_escape_utf8($batch_id);
					# We don't append query_str here because rotor_session API usually doesn't need moodEnergy passed back 
					# (it's baked into the session), but if it was passed in URL, we could.
					push @tracks, $new_url;
				}
			}
			
			$prefs->client($client)->set('yandex_seen_tracks', $seen_tracks) if $client;
			$cb->(\@tracks);

		}, sub {
			my $err = shift;
			$log->error("YANDEX NEW ROTOR: Failed to start session: $err");
			$cb->([]);
		});
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

sub _get_current_timestamp {
    my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = gmtime(time);
    $year += 1900;
    $mon += 1;
    return sprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", $year, $mon, $mday, $hour, $min, $sec);
}

1;