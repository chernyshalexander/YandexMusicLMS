package Plugins::yandex::ProtocolHandler;

use strict;
use warnings;
use Slim::Utils::Log;
use Slim::Utils::Cache;
use Plugins::yandex::Browse;

use base qw(Slim::Player::Protocols::HTTPS);
use URI::Escape;
use Slim::Utils::Prefs;
use Time::HiRes;

require Slim::Player::Playlist;
require Slim::Player::Source;
require Slim::Control::Request;


my $log = logger('plugin.yandex');
my $prefs = preferences('plugin.yandex');
my @pendingMeta = ();  # Global queue for pending metadata requests (prevent duplicates, limit to 10 parallel)

# 1. CONSTRUCTOR 
sub new {
    my $class  = shift;
    my $args   = shift;

    my $client    = $args->{client};
    my $song      = $args->{song};
    
    # Take URL that should already be set in getNextTrack
    my $streamUrl = $song->streamUrl() || return;

    $log->error("YANDEX: Handler new() called for REAL streamUrl: $streamUrl");

    my $sock = $class->SUPER::new( {
        url     => $streamUrl,
        song    => $song,
        client  => $client,
    } ) || return;

    # Set content type
    ${*$sock}{contentType} = 'audio/mpeg';

    # Try to set stream parameters explicitly so LMS knows it's not an infinite stream
    # and displays the progress bar.

    if ($client) {
         my $duration = $song->duration || 0;
         my $artist = 'Unknown';
         my $title = 'Unknown';

         # Use original track URL (yandexmusic://...) to search in cache
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
         # ROTOR: Infinite radio and sending feedback at track start
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
                 # trackStarted feedback is already sent from Plugin.pm (playerEventCallback), 
                 # so we don't send it again here.
                 
                 # Check queue length: if 2 or fewer tracks left until the end, add a new portion
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
                                     
                                     Plugins::yandex::Browse::cache_track_metadata($track_obj);
                                     
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
                                     
                                     Plugins::yandex::Browse::cache_track_metadata($track_obj);
                                     
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

         # Set on the passed $song object (which is a Slim::Player::Song object)
         $song->isLive(0);
         $song->duration($duration);
         
         # Also update meta via Slim::Music::Info so UI picks it up
         if ($song->currentTrack) {
             Slim::Music::Info::setDuration($song->currentTrack, $duration);
         }
    }

    return $sock;
}

# --- 2. canDirectStreamSong
# WHY 0 (PROXY): Yandex drops long connections (Connection reset by peer).
# Hardware and software players (SqueezeLite, SqueezePlay) also may download at bitrate speed (~40kbps).
# After a few minutes, Yandex drops the connection due to a "slow" client.
# Proxy mode (0) forces the LMS server to quickly download the entire track (like a browser) 
# into a temporary local file (Buffered), and players then pull it from the local network without drops.

sub canDirectStreamSong {
    my ($class, $client, $song) = @_;
    $log->info("YANDEX: Forcing proxy for streamUrl: " . $song->streamUrl());
    return 0;
}

# --- 3. canEnhanceHTTP
# FORCIBLY ENABLE BUFFERING (Buffered Mode = 2).
# Without this, LMS can work in direct proxy mode, downloading data at player speed.
# Mode 2 forces LMS to download the entire file as quickly as possible into a local .buf file.
sub canEnhanceHTTP {
    return 2; # 2 = BUFFERED constant in Slim::Player::Protocols::HTTP
}

# 3. scanUrl 
sub scanUrl {
    my ($class, $url, $args) = @_;
    $args->{cb}->( $args->{song}->currentTrack() );
}

# 4. getNextTrack (ASYNCHRONOUS CALL) 
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

    # Get client instance from Plugin
    my $yandex_client = Plugins::yandex::Plugin->getClient();

    unless ($yandex_client) {
        $log->error("YANDEX: Could not get Yandex client instance. Plugin might not be initialized.");
        $errorCb->('Plugin not initialized');
        return;
    }

    # Request track stream URL directly using API.pm
    $yandex_client->get_track_direct_url($track_id, sub {
        my ($final_url, $error, $bitrate) = @_;

        if ($final_url) {
            $log->info("YANDEX: ASYNC URL resolved: $final_url, Bitrate: " . ($bitrate || "unknown"));

            # Save bitrate to cache if it exists (90 days like Deezer)
            if ($bitrate) {
                my $cache = Slim::Utils::Cache->new();
                if (my $cached_meta = $cache->get('yandex_meta_' . $track_id)) {
                    $cached_meta->{bitrate} = $bitrate;
                    $cache->set('yandex_meta_' . $track_id, $cached_meta, '90d');
                }
            }

            # Set the real link in the song object
            $song->streamUrl($final_url);

            # Report success
            $successCb->();
        } else {
            $log->error("YANDEX: ASYNC URL resolution failed: $error");
            # Report error
            $errorCb->($error);
        }
    });
}


sub getFormatForURL { 'mp3' }
sub isRemote { 1 }
sub isAudio { 1 }

sub getMetadataFor {
    my ($class, $client, $url) = @_;

    # Try to find in cache
    if ($url =~ /yandexmusic:\/\/(\d+)/) {
        my $track_id = $1;
        my $cache = Slim::Utils::Cache->new();
        my $cached_meta = $cache->get('yandex_meta_' . $track_id);

        # Helper to check if currently playing this track
        my $is_playing_this = $client && $client->playingSong() && $client->playingSong()->track() && $client->playingSong()->track()->url() eq $url;

        # If we have complete metadata (or not currently playing), return immediately without API request
        if ($cached_meta && ($cached_meta->{_complete} || !$is_playing_this)) {
            my $bitrate = $cached_meta->{bitrate} || 192000;

            # Save values to LMS DB for correct seeking (canSeek) operation
            eval {
                Slim::Music::Info::setBitrate($url, $bitrate);
                Slim::Music::Info::setDuration($url, $cached_meta->{duration}) if $cached_meta->{duration};

                # Also update track objects if something is playing right now
                if ($is_playing_this) {
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

        # Prepare default metadata with proper icon
        my $default_icon = 'plugins/yandex/html/images/yandex.png';
        my $default_meta = {
            title  => "Yandex Track $track_id",
            artist => "Yandex Music",
            cover  => $default_icon,
            icon   => $default_icon,
            type   => 'mp3',
        };

        # If we have cached metadata (but not _complete), return it with default icon
        if ($cached_meta) {
            my $bitrate = $cached_meta->{bitrate} || 192000;
            eval {
                Slim::Music::Info::setBitrate($url, $bitrate);
                Slim::Music::Info::setDuration($url, $cached_meta->{duration}) if $cached_meta->{duration};
            };

            return {
                title    => $cached_meta->{title},
                artist   => $cached_meta->{artist},
                album    => $cached_meta->{album},
                duration => $cached_meta->{duration},
                cover    => $cached_meta->{cover} || $default_icon,
                icon     => $cached_meta->{cover} || $default_icon,
                bitrate  => sprintf("%.0fkbps", $bitrate/1000),
                type     => 'mp3',
            };
        }

        # Fetch metadata asynchronously using pending queue (like Deezer)
        my $yandex_client = Plugins::yandex::Plugin->getClient();
        if ($yandex_client) {
            my $now = time();
            # Cleanup old requests (lost after 60 seconds)
            @pendingMeta = grep { $_->{time} + 60 > $now } @pendingMeta;

            # Only proceed if not already pending and less than 10 parallel requests
            if ( !(grep { $_->{id} == $track_id } @pendingMeta) && scalar(@pendingMeta) < 10 ) {
                push @pendingMeta, { id => $track_id, time => $now };

                $yandex_client->tracks([$track_id], sub {
                    my $tracks = shift;
                    # Remove this track from pending queue
                    @pendingMeta = grep { $_->{id} != $track_id } @pendingMeta;

                    return unless $tracks && ref $tracks eq 'ARRAY' && @$tracks;

                    # Cache the metadata with _complete flag
                    Plugins::yandex::Browse::cache_track_metadata($tracks->[0]);

                    # Only notify if queue is empty (batch notifications like Deezer)
                    return if @pendingMeta;

                    # Notify LMS that metadata has changed
                    if ($client) {
                        $client->currentPlaylistUpdateTime(Time::HiRes::time()) if $client->can('currentPlaylistUpdateTime');
                        Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
                    }
                }, sub {
                    # Error callback: remove from pending queue
                    @pendingMeta = grep { $_->{id} != $track_id } @pendingMeta;
                });
            }
        }

        return $default_meta;
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
		
		# Send radio start signal (radioStarted)
		$yandex_client->rotor_station_feedback($station_id, 'radioStarted', undef, undef, 0, sub {}, sub {});
		
		# Clear listened tracks history when starting a new radio station
		$prefs->client($client)->set('yandex_seen_tracks', []) if $client;
		
		# Get first tracks
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
					Plugins::yandex::Browse::cache_track_metadata($track_obj);
                    
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
					
					Plugins::yandex::Browse::cache_track_metadata($track_obj);
					
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
                        Plugins::yandex::Browse::cache_track_metadata($_);
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
                    Plugins::yandex::Browse::cache_track_metadata($track_obj);
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
                Plugins::yandex::Browse::cache_track_metadata($_);
                'yandexmusic://' . $_->{id} 
            } @$tracks;
			$cb->(\@items);
		}, sub { $cb->([]) });
	}
	# yandexmusic://chart
	elsif ($url =~ /yandexmusic:\/\/chart/) {
		$yandex_client->get_chart(
			'',
			sub {
				my $tracks_short = shift;
				my @track_ids;

				foreach my $track_short (@$tracks_short) {
					my $track_data = $track_short->{track} // $track_short;
					if ($track_data->{id}) {
						push @track_ids, $track_data->{id};
					}
				}

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
									Plugins::yandex::Browse::cache_track_metadata($_);
									'yandexmusic://' . $_->{id}
								} @all_tracks_detailed;
								$cb->(\@items);
							}
						},
						sub {
							$pending_chunks--;
							if ($pending_chunks == 0) {
								my @items = map {
									Plugins::yandex::Browse::cache_track_metadata($_);
									'yandexmusic://' . $_->{id}
								} @all_tracks_detailed;
								$cb->(\@items);
							}
						}
					);
				}
			},
			sub { $cb->([]) }
		);
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
                                Plugins::yandex::Browse::cache_track_metadata($_);
                                'yandexmusic://' . $_->{id} 
                            } @all_tracks_detailed;
                            $cb->(\@items);
                        }
                    },
                    sub {
                        $pending_chunks--;
                        if ($pending_chunks == 0) {
                            my @items = map { 
                                Plugins::yandex::Browse::cache_track_metadata($_);
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