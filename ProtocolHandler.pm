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

    $log->info("YANDEX: Handler new() called for streamUrl: $streamUrl");

    # Local pre-decoded FLAC file (result of flac-mp4 decrypt+demux)
    if ($streamUrl =~ m{^file://(.+)}) {
        my $path = $1;
        $path =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;

        require Symbol;
        my $sock = Symbol::gensym();
        open($sock, '<', $path) or do {
            $log->error("YANDEX: Cannot open local file $path: $!");
            return;
        };
        binmode($sock);
        bless $sock, $class;
        ${*$sock}{contentType}     = 'audio/flac';
        ${*$sock}{yandex_temp_file} = $path;

        if ($client) {
            my $duration = $song->duration || 0;
            $song->isLive(0);
            $song->duration($duration) if $duration;
            Slim::Music::Info::setDuration($song->currentTrack, $duration)
                if $duration && $song->currentTrack;
        }
        $log->info("YANDEX: file handle ready, size=" . (-s $path) . " fileno=" . (fileno($sock) // 'undef'));
        return $sock;
    }

    my $sock = $class->SUPER::new( {
        url     => $streamUrl,
        song    => $song,
        client  => $client,
    } ) || return;

    # Set content type based on codec stored in cache; setup AES-CTR cipher if stream is encrypted
    my $content_type = 'audio/mpeg';
    my $orig_url = $song->currentTrack ? $song->currentTrack->url : $streamUrl;
    if ($orig_url =~ /yandexmusic:\/\/(?:track\/)?(\d+)/) {
        my $track_id = $1;
        my $cache    = Slim::Utils::Cache->new();
        my $meta     = $cache->get('yandex_meta_' . $track_id);
        if ($meta && $meta->{codec}) {
            # Any -mp4 codec (flac-mp4, aac-mp4, he-aac-mp4) is MP4 container format
            if ($meta->{codec} =~ /-mp4$/) {
                $content_type = 'audio/mp4';
            } elsif ($meta->{codec} eq 'flac') {
                $content_type = 'audio/flac';
            } elsif ($meta->{codec} =~ /^(?:aac|he-aac|mp3)$/) {
                $content_type = 'audio/mpeg';  # AAC, HE-AAC, MP3 default
            }

            if ($meta->{aes_key}) {
                eval {
                    require Crypt::Rijndael;
                    my $key_bytes = pack('H*', $meta->{aes_key});
                    ${*$sock}{yandex_cipher} = Crypt::Rijndael->new($key_bytes, Crypt::Rijndael::MODE_ECB());
                    ${*$sock}{yandex_offset} = 0;
                    $log->info("YANDEX: AES-CTR cipher ready for track $track_id");
                };
                $log->error("YANDEX: Rijndael init failed: $@") if $@;
            }
        }
    } elsif ($streamUrl =~ /get-flac/) {
        $content_type = 'audio/flac';
    }
    ${*$sock}{contentType} = $content_type;

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
sub canEnhanceHTTP { return 0 }

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
        my ($final_url, $error, $bitrate, $codec, $aes_key) = @_;

        if ($final_url) {
            $log->info("YANDEX: URL resolved codec=" . ($codec||'mp3') . " bitrate=" . ($bitrate||0) . " encrypted=" . ($aes_key ? 'yes' : 'no'));

            # Save bitrate, codec and AES key to cache for use in new() / _sysread()
            my $cache = Slim::Utils::Cache->new();
            if (my $cached_meta = $cache->get('yandex_meta_' . $track_id)) {
                $cached_meta->{bitrate}  = $bitrate  if $bitrate;
                $cached_meta->{codec}    = $codec    if $codec;
                $cached_meta->{aes_key}  = $aes_key  if $aes_key;
                # Using 3600 for stream-specific metadata (AES keys etc)
                $cache->set('yandex_meta_' . $track_id, $cached_meta, 3600);
            }

            # Explicitly set metadata in LMS DB for proper UI display
            my $track_url = $song->track()->url();
            eval {
                if ($codec && ($codec eq 'flac' || $codec eq 'flac-mp4')) {
                    # Set bitrate (FLAC is lossless, but estimate bitrate for seekbar)
                    my $est_bitrate = $bitrate || 900000;  # 900kbps estimate for FLAC
                    Slim::Music::Info::setBitrate($track_url, $est_bitrate);
                    $log->info("YANDEX: Set bitrate=$est_bitrate for FLAC track");
                }
            };

            $song->streamUrl($final_url);

            # Report success
            $successCb->();
        } else {
            $log->error("YANDEX: URL resolution failed: $error");
            $errorCb->($error);
        }
    });
}


# Called by LMS AFTER getNextTrack resolves — codec is in cache by this point.
# This overrides any stale 'mp3' format that contentType() may have returned earlier.
sub formatOverride {
    my ($class, $song) = @_;
    my $url = $song->currentTrack()->url;
    if ($url =~ /yandexmusic:\/\/(?:track\/)?(\d+)/) {
        my $cache = Slim::Utils::Cache->new();
        my $meta  = $cache->get('yandex_meta_' . $1);
        if ($meta && $meta->{codec}) {
            my $codec = $meta->{codec};

            # FLAC in MP4: needs ffmpeg demuxing (custom-convert.conf ymf → flc rule)
            if ($codec eq 'flac-mp4') {
                $log->info("YANDEX: formatOverride → ymf for $url (flac-mp4 with ffmpeg demux)");
                return 'ymf';
            }
            # Other MP4 containers (aac-mp4, he-aac-mp4): play as native MP4
            if ($codec =~ /-mp4$/) {
                $log->info("YANDEX: formatOverride → mp4 for $url (codec=$codec, no demux needed)");
                return 'mp4';
            }
            # Plain FLAC: no conversion needed, decrypted via _sysread()
            if ($codec eq 'flac') {
                $log->info("YANDEX: formatOverride → flc for $url (plain flac)");
                return 'flc';
            }
        }
    }
    return undef;
}

sub getFormatForURL {
    my ($class, $url) = @_;
    $log->info("YANDEX: getFormatForURL called with: $url");
    # Pre-demuxed FLAC temp file
    return 'flc' if $url =~ /^file:\/\//;
    if ($url =~ /yandexmusic:\/\/(?:track\/)?(\d+)/) {
        my $cache = Slim::Utils::Cache->new();
        my $meta  = $cache->get('yandex_meta_' . $1);
        if ($meta && $meta->{codec}) {
            # flac-mp4: custom format ymf for ffmpeg demux via stdin
            return 'ymf' if $meta->{codec} eq 'flac-mp4';
            # Other MP4 containers: play as native MP4
            return 'mp4' if $meta->{codec} =~ /-mp4$/;
            # plain FLAC: decrypted via _sysread()
            return 'flc' if $meta->{codec} eq 'flac';
        }
    }
    return 'mp3';
}
sub isRemote { 1 }
sub isAudio { 1 }

sub getMetadataFor {
    my ($class, $client, $url) = @_;

    # Try to find in cache
    if ($url =~ /yandexmusic:\/\/(\d+)/) {
        my $track_id = $1;
        my $cache = Slim::Utils::Cache->new();
        my $cached_meta = $cache->get('yandex_meta_' . $track_id);
        if ($cached_meta) {
            $log->debug("YANDEX: Returning cached metadata for $url");
            
            my $bitrate    = $cached_meta->{bitrate} || 0;
            my $codec      = $cached_meta->{codec} || '';
            my $max_bitrate = $prefs->get('max_bitrate') || 320;

            # Determine type: use actual codec if known, otherwise infer from quality setting
            my $type;
            if ($codec && ($codec eq 'flac' || $codec eq 'flac-mp4')) {
                $type = 'flc';
            } elsif (!$codec && $max_bitrate eq 'flac') {
                $type = 'flc';  # not yet resolved, but will be FLAC
            } else {
                $type = 'mp3';
            }

            # Bitrate display: FLAC is variable/lossless — show estimated bitrate or "FLAC"
            my $bitrate_str;
            if ($type eq 'flc') {
                # For FLAC: show "FLAC" if bitrate unknown, otherwise estimated bitrate
                $bitrate_str = !$bitrate ? 'FLAC' : sprintf("~%.0fkbps FLAC", ($bitrate || 900000) / 1000);
            } else {
                $bitrate_str = sprintf("%.0fkbps", ($bitrate || 192000) / 1000);
            }

            # Helper to check if currently playing this track
            my $is_playing_this = $client && $client->playingSong() && $client->playingSong()->track() && $client->playingSong()->track()->url() eq $url;
            
            # If we have complete metadata (or not currently playing), return immediately without API request
            if ($cached_meta->{_complete} || !$is_playing_this) {
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
                    bitrate  => $bitrate_str,
                    type     => $type,
                };
            }
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
            my $codec   = $cached_meta->{codec} || '';
            my $bitrate = $cached_meta->{bitrate};
            
            # Use appropriate bitrate fallback based on codec
            if (!$bitrate) {
                $bitrate = ($codec eq 'flac' || $codec eq 'flac-mp4') ? 900000 : 192000;
            }
            
            # Determine type
            my $type = ($codec eq 'flac' || $codec eq 'flac-mp4') ? 'flc' : 'mp3';

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
                bitrate  => ($type eq 'flc') ? 'FLAC' : sprintf("%.0fkbps", $bitrate/1000),
                type     => $type,
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

# AES-CTR streaming decryption for encrypted FLAC streams (encraw transport).
# Called by LMS for every chunk read from the remote URL.
sub _sysread {
    use bytes;
    my ($self, undef, $length, $offset) = @_;
    $offset //= 0;

    my $cipher = ${*$self}{yandex_cipher};
    unless ($cipher) {
        my $bytes = ${*$self}{yandex_temp_file}
            ? sysread($self, $_[1], $length, $offset)
            : $self->SUPER::_sysread($_[1], $length, $offset);
        if (${*$self}{yandex_temp_file}) {
            my $cnt = ++${*$self}{_sysread_logged};
            if ($cnt == 1 && defined $bytes && $bytes >= 4) {
                my $magic = unpack('H8', substr($_[1], $offset, 4));
                $log->info("YANDEX: _sysread file #1 got=$bytes magic=$magic (expect 664c6143=fLaC)");
            }
        }
        # Clean up temp file on EOF
        if (defined $bytes && $bytes == 0 && ${*$self}{yandex_temp_file}) {
            unlink(delete ${*$self}{yandex_temp_file});
        }
        return $bytes;
    }

    my $bytes_read = $self->SUPER::_sysread($_[1], $length, $offset);
    return $bytes_read unless defined $bytes_read && $bytes_read > 0;

    my $stream_pos = ${*$self}{yandex_offset} // 0;
    my $plain      = _aes_ctr_xor($cipher, substr($_[1], $offset, $bytes_read), $stream_pos);
    substr($_[1], $offset, $bytes_read) = $plain;
    ${*$self}{yandex_offset} = $stream_pos + $bytes_read;

    return $bytes_read;
}

# XOR $data (starting at $stream_pos) with AES-CTR keystream generated by $cipher (ECB mode).
sub _aes_ctr_xor {
    use bytes;
    my ($cipher, $data, $stream_pos) = @_;
    my $len = length($data);
    my $out = '';
    my $i   = 0;
    while ($i < $len) {
        my $abs      = $stream_pos + $i;
        my $blk_num  = int($abs / 16);
        my $blk_off  = $abs % 16;
        # 128-bit big-endian counter (block_num fits in 32 bits for any practical track)
        my $counter  = "\x00" x 12 . pack('N', $blk_num);
        my $keystream = $cipher->encrypt($counter);
        my $take      = 16 - $blk_off;
        $take = $len - $i if $len - $i < $take;
        $out .= substr($data, $i, $take) ^ substr($keystream, $blk_off, $take);
        $i   += $take;
    }
    return $out;
}

1;