package Plugins::yandex::ProtocolHandler;

=encoding utf8

=head1 NAME

Plugins::yandex::ProtocolHandler - LMS protocol handler for yandexmusic:// URLs

=head1 DESCRIPTION

Handles streaming of Yandex Music tracks to LMS players. The full pipeline:

  getNextTrack()          — resolves yandexmusic://{id} → CDN URL + AES key + codec
       ↓
  canEnhanceHTTP → 2      — forces buffered mode: LMS downloads the full encrypted
                            file to a .buf temp file at max speed, avoiding Yandex CDN
                            connection resets that happen with slow per-bitrate reads
       ↓
  new() / _sysread()      — intercepts every read to decrypt bytes via AES-CTR on the fly
       ↓
  [if codec is *-mp4]
  MP4Demux->process()     — strips the MP4 container, outputs raw FLAC or ADTS-AAC
       ↓
  formatOverride()        — tells LMS what audio format the stream really is
                            (flc/ymf for FLAC, aac/yma for AAC)

AES-CTR keystream: 128-bit big-endian counter = 12 zero bytes + block_number (uint32 BE).
Block number = byte_offset / 16. The same counter scheme is used by Yandex for all
encraw streams regardless of codec.

=cut

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

    # DEAD CODE: file:// branch was for Tier-2 openssl fallback (_decrypt_flac_via_openssl in API.pm).
    # That function was removed; no code in the plugin generates file:// URLs anymore.
    # TODO: remove this entire block.
    # if ($streamUrl =~ m{^file://(.+)}) {
    #     my $path = $1;
    #     $path =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
    #
    #     require Symbol;
    #     my $sock = Symbol::gensym();
    #     open($sock, '<', $path) or do {
    #         $log->error("YANDEX: Cannot open local file $path: $!");
    #         return;
    #     };
    #     binmode($sock);
    #     bless $sock, $class;
    #     ${*$sock}{contentType}     = 'audio/flac';
    #     ${*$sock}{yandex_temp_file} = $path;
    #
    #     if ($client) {
    #         my $duration = $song->duration || 0;
    #         $song->isLive(0);
    #         $song->duration($duration) if $duration;
    #         Slim::Music::Info::setDuration($song->currentTrack, $duration)
    #             if $duration && $song->currentTrack;
    #     }
    #     $log->info("YANDEX: file handle ready, size=" . (-s $path) . " fileno=" . (fileno($sock) // 'undef'));
    #     return $sock;
    # }

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
                    require Plugins::yandex::API;
                    my $key_bytes = pack('H*', $meta->{aes_key});
                    ${*$sock}{yandex_cipher} = Plugins::yandex::API::make_aes_cipher($key_bytes);
                    ${*$sock}{yandex_offset} = 0;
                    $log->info("YANDEX: AES-CTR cipher ready for track $track_id");
                };
                $log->error("YANDEX: AES cipher init failed: $@") if $@;
            }
            # Set up MP4Demux for flac-mp4 and aac-mp4 with internal demux backend
            if ($meta->{codec} && ($meta->{codec} eq 'flac-mp4' || $meta->{codec} =~ /-mp4$/) && ${*$sock}{yandex_cipher}) {
                my $demux_backend = $prefs->get('demux_backend') || 'ffmpeg';
                if ($demux_backend eq 'internal') {
                    eval {
                        require Plugins::yandex::Decode::MP4Demux;
                        my $demux_codec = ($meta->{codec} =~ /aac/) ? 'aac' : 'flac';
                        ${*$sock}{yandex_demux} = Plugins::yandex::Decode::MP4Demux->new(codec => $demux_codec);
                        if ($demux_codec eq 'aac') {
                            $content_type = 'audio/aac';
                        }
                        $log->info("YANDEX: MP4Demux (internal) enabled for $meta->{codec} track $track_id");
                    };
                    $log->error("YANDEX: MP4Demux init failed: $@") if $@;
                }
            }
            # Store song ref for FLAC header parsing in _sysread (plain flac only)
            ${*$sock}{yandex_song} = $song if $meta->{codec} && $meta->{codec} eq 'flac';
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
         if ($original_url =~ /rotor_session=([^&]+)/) {
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
                             my $remove_duplicates = $prefs->get('remove_duplicates');
                             my $seen_tracks = $prefs->client($client)->get('yandex_seen_tracks') || [];
                             my %seen_map = map { (split /:/, $_)[0] => 1 } @$seen_tracks;
                             my $added_count = 0;

                             foreach my $track_obj (@{$result->{tracks}}) {
                                 my $tid = $track_obj->{id};

                                 # Skip if filtering duplicates is enabled and track was seen
                                 next if $remove_duplicates && $seen_map{$tid};

                                 if (!$seen_map{$tid}) {
                                     $seen_map{$tid} = 1;
                                     my $album_id = ($track_obj->{albums} && @{$track_obj->{albums}})
                                         ? $track_obj->{albums}[0]{id} : undef;
                                     push @$seen_tracks, $album_id ? "${tid}:${album_id}" : "$tid";
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
# BUFFERED mode (2): LMS downloads the full encrypted file to a .buf temp file at max speed.
# _sysread() decrypts via AES-CTR during buffered download (saveStream calls _sysread).
# After download, readChunk reads decrypted data from .buf for ffmpeg transcoding.
# Without buffering (0), LMS reads at player speed (~32KB/s) and Yandex CDN drops
# slow connections after ~2 minutes.
sub canEnhanceHTTP { return 2 }

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
            # Use existing entry if available (preserves title/artist/duration), otherwise create one.
            my $cache = Slim::Utils::Cache->new();
            my $cached_meta = $cache->get('yandex_meta_' . $track_id) || {};
            # For FLAC codecs the API always returns bitrate=0 — store the estimate
            if ($codec && $codec =~ /^flac/) {
                $cached_meta->{bitrate} = $bitrate || 900000;
            } elsif ($bitrate) {
                $cached_meta->{bitrate} = $bitrate;
            }
            $cached_meta->{codec}   = $codec   if $codec;
            $cached_meta->{aes_key} = $aes_key if $aes_key;
            # Using 3600 for stream-specific metadata (AES keys etc)
            $cache->set('yandex_meta_' . $track_id, $cached_meta, 3600);

            # Explicitly set metadata in LMS DB for proper UI display
            my $track_url = $song->track()->url();
            eval {
                # Determine correct content_type and bitrate based on actual codec
                my ($ct, $est_bitrate, $is_vbr);
                if ($codec eq 'flac') {
                    $ct          = 'flc';
                    $est_bitrate = $bitrate || 900000;
                    $is_vbr      = 1;
                } elsif ($codec eq 'flac-mp4') {
                    $ct          = 'flac-MP4';  # stored directly: not 'unk' → no typeFromPath fallback → shown as-is
                    $est_bitrate = $bitrate || 900000;
                    $is_vbr      = 1;
                } elsif ($codec =~ /-mp4$/) {
                    $ct          = 'aac-MP4';  # shown as-is, like flac-MP4
                    $est_bitrate = $bitrate || 192000;  # already in bps
                    $is_vbr      = undef;
                } else {
                    $ct          = 'mp3';
                    $est_bitrate = $bitrate || 128000;
                    $is_vbr      = undef;
                }

                if ($ct) {
                    Slim::Schema->updateOrCreate({
                        url        => $track_url,
                        readTags   => 0,
                        commit     => 1,
                        attributes => { CONTENT_TYPE => $ct },
                    });
                    # RemoteTrack::updateOrCreate does NOT update Slim::Schema::contentTypeCache,
                    # so we must clear the stale entry manually (e.g. 'mp3' from a previous play).
                    # After clearing, the next contentType() call re-reads from the RemoteTrack
                    # object (which now has $ct), and infoContentType() falls back to
                    # getMetadataFor() when $ct eq 'unk' — returning our 'flac-MP4' string.
                    Slim::Schema->clearContentTypeCache($track_url);
                    Slim::Music::Info::setBitrate($track_url, $est_bitrate, $is_vbr);
                    $log->info("YANDEX: Set content_type=$ct bitrate=$est_bitrate vbr=" . ($is_vbr ? 1 : 0) . " for $codec track");
                }
            };
            $log->warn("YANDEX: metadata update failed: $@") if $@;

            $song->streamUrl($final_url);

            # Notify controllers to refresh track info display now that content_type/bitrate are set
            if (my $client = $song->master()) {
                $client->currentPlaylistUpdateTime(Time::HiRes::time());
                Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
            }

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

            # FLAC in MP4: internal pure-Perl demux or ffmpeg via custom-convert.conf ymf → flc
            if ($codec eq 'flac-mp4') {
                if (($prefs->get('demux_backend') || 'ffmpeg') eq 'internal') {
                    $log->info("YANDEX: formatOverride -> flc for $url (flac-mp4, internal demux)");
                    return 'flc';
                }
                $log->info("YANDEX: formatOverride -> ymf for $url (flac-mp4, ffmpeg demux)");
                return 'ymf';
            }
            # aac-mp4, he-aac-mp4: pure-Perl demux -> aac, ffmpeg transcoding -> yma
            if ($codec =~ /-mp4$/) {
                if (($prefs->get('demux_backend') || 'ffmpeg') eq 'internal') {
                    $log->info("YANDEX: formatOverride -> aac for $url ($codec, internal demux)");
                    return 'aac';
                }
                $log->info("YANDEX: formatOverride -> yma for $url (codec=$codec)");
                return 'yma';
            }
            # Plain FLAC: no conversion needed, decrypted via _sysread()
            if ($codec eq 'flac') {
                $log->info("YANDEX: formatOverride -> flc for $url (plain flac)");
                return 'flc';
            }
        }
    }
    return undef;
}

sub getFormatForURL {
    my ($class, $url) = @_;
    # Pre-demuxed FLAC temp file
    return 'flc' if $url =~ /^file:\/\//;
    if ($url =~ /yandexmusic:\/\/(?:track\/)?(\d+)/) {
        my $cache = Slim::Utils::Cache->new();
        my $meta  = $cache->get('yandex_meta_' . $1);
        if ($meta && $meta->{codec}) {
            # flac-mp4: internal demux → flc, ffmpeg demux → ymf
            if ($meta->{codec} eq 'flac-mp4') {
                return 'flc' if ($prefs->get('demux_backend') || 'ffmpeg') eq 'internal';
                return 'ymf';
            }
            # aac-mp4, he-aac-mp4: pure-Perl demux -> aac, ffmpeg transcoding -> yma
            if ($meta->{codec} =~ /-mp4$/) {
                return 'aac' if ($prefs->get('demux_backend') || 'ffmpeg') eq 'internal';
                return 'yma';
            }
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
            
            my $bitrate    = $cached_meta->{bitrate} || 0;
            my $codec      = $cached_meta->{codec} || '';
            my $max_bitrate = $prefs->get('max_bitrate') || 320;

            # Determine type: use actual codec if known, otherwise infer from quality setting
            my ($type, $display_type);
            if ($codec eq 'flac-mp4') {
                $type = $display_type = 'flac-MP4';
            } elsif ($codec eq 'flac') {
                $type = $display_type = 'flc';
            } elsif (!$codec && $max_bitrate eq 'flac') {
                $type = $display_type = 'flc';  # not yet resolved, but will be FLAC
            } elsif ($codec =~ /-mp4$/) {
                $type = $display_type = 'aac-MP4';
            } else {
                $type = $display_type = 'mp3';
            }

            # Bitrate display: FLAC is variable/lossless — show estimated bitrate or "FLAC"
            my $bitrate_str;
            if ($type =~ /flac|flc/) {
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
                    type     => $display_type,
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
            my $display_type = ($codec eq 'flac-mp4') ? 'flac-MP4'
                             : ($codec eq 'flac')     ? 'flc'
                             : ($codec =~ /-mp4$/)    ? 'aac-MP4'
                             :                          'mp3';

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
                bitrate  => ($display_type =~ /flac|flc/) ? 'FLAC' : sprintf("%.0fkbps", $bitrate/1000),
                type     => $display_type,
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

	if ($url =~ /^yandexmusic:\/\/rotor_session\/([^\?]+)(?:\?(.*))?/) {
		my $station_id = $1;
        my $query_str = $2;
        
		# Parse query string into settings hash
		my %settings;
		if ($query_str) {
			foreach my $pair (split /&/, $query_str) {
				my ($k, $v) = split /=/, $pair, 2;
				next unless $k && defined $v;
				$settings{URI::Escape::uri_unescape($k)} = URI::Escape::uri_unescape($v);
			}
		}

		# Build queue from previously seen tracks (format: "trackId:albumId")
		my $seen_tracks_prev = $prefs->client($client)->get('yandex_seen_tracks') || [];
		$prefs->client($client)->set('yandex_seen_tracks', []) if $client;

		$log->info("YANDEX NEW ROTOR: Exploding session for station $station_id, settings: " .
			join(', ', map { "$_=$settings{$_}" } keys %settings) . ", queue: " . scalar(@$seen_tracks_prev) . " tracks");

		# 1. Create session
		$yandex_client->rotor_session_new($station_id, \%settings, $seen_tracks_prev, sub {
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
			my $remove_duplicates = $prefs->get('remove_duplicates');

			if ($sequence && ref $sequence eq 'ARRAY') {
				foreach my $item (@$sequence) {
					my $track_obj = $item->{track};
					next unless $track_obj;
					my $tid = $track_obj->{id};

					next if $remove_duplicates && $seen_map{$tid};

					if (!$seen_map{$tid}) {
                        $seen_map{$tid} = 1;
                        my $album_id = ($track_obj->{albums} && @{$track_obj->{albums}})
                            ? $track_obj->{albums}[0]{id} : undef;
                        push @$seen_tracks, $album_id ? "${tid}:${album_id}" : "$tid";
                    }

					Plugins::yandex::Browse::cache_track_metadata($track_obj);

					my $new_url = 'yandexmusic://' . $track_obj->{id} .
                                  '?rotor_session=' . URI::Escape::uri_escape_utf8($radio_session_id) .
                                  '&batch_id=' . URI::Escape::uri_escape_utf8($batch_id);
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
        # DEAD CODE: yandex_temp_file branch was for the file:// Tier-2 fallback (removed).
        # yandex_temp_file is never set now, so the ternary always takes SUPER::_sysread.
        # TODO: simplify to: my $bytes = $self->SUPER::_sysread($_[1], $length, $offset);
        my $bytes = ${*$self}{yandex_temp_file}
            ? sysread($self, $_[1], $length, $offset)
            : $self->SUPER::_sysread($_[1], $length, $offset);
        # DEAD CODE: block below never executes (yandex_temp_file always undef)
        # if (${*$self}{yandex_temp_file}) {
        #     my $cnt = ++${*$self}{_sysread_logged};
        #     if ($cnt == 1 && defined $bytes && $bytes >= 4) {
        #         my $magic = unpack('H8', substr($_[1], $offset, 4));
        #         $log->info("YANDEX: _sysread file #1 got=$bytes magic=$magic (expect 664c6143=fLaC)");
        #     }
        # }
        if (${*$self}{yandex_temp_file}) {
            my $cnt = ++${*$self}{_sysread_logged};
            if ($cnt == 1 && defined $bytes && $bytes >= 4) {
                my $magic = unpack('H8', substr($_[1], $offset, 4));
                $log->info("YANDEX: _sysread file #1 got=$bytes magic=$magic (expect 664c6143=fLaC)");
            }
        }
        # DEAD CODE: temp file cleanup — yandex_temp_file is never set, unlink never runs
        # TODO: remove the entire yandex_temp_file ternary and both dead blocks above
        if (defined $bytes && $bytes == 0 && ${*$self}{yandex_temp_file}) {
            unlink(delete ${*$self}{yandex_temp_file});
        }
        return $bytes;
    }

    # --- AES cipher active ---

    my $demux = ${*$self}{yandex_demux};
    if ($demux) {
        # --- Internal streaming demux path (flac-mp4 → raw FLAC) ---

        # Ensure buffer is defined before using as lvalue substr target
        $_[1] //= '';

        # Return leftover FLAC bytes from a previous oversized demux output
        my $pending = ${*$self}{yandex_demux_pending} // '';
        if (length($pending) > 0) {
            my $take = $length < length($pending) ? $length : length($pending);
            substr($_[1], $offset, $take) = substr($pending, 0, $take);
            ${*$self}{yandex_demux_pending} = substr($pending, $take);
            return $take;
        }

        # Read encrypted MP4 bytes from network, decrypt, demux → FLAC.
        # Loop until StreamingDemux produces output or we hit true EOF.
        # (The loop runs at most a handful of times: moov is only ~13KB.)
        my $flac_out = '';
        while (length($flac_out) == 0) {
            my $raw = '';
            my $n = $self->SUPER::_sysread($raw, $length, 0);
            return undef unless defined $n;
            last if $n == 0;  # true EOF — FLAC frames need no flush

            my $sp    = ${*$self}{yandex_offset} // 0;
            my $plain = _aes_ctr_xor($cipher, $raw, $sp);
            ${*$self}{yandex_offset} = $sp + $n;

            my $demuxed = $demux->process($plain);
            if (length($demuxed) > 0) {
                if (!${*$self}{_first_chunk_logged}++) {
                    my $sizes = '';
                    if ($demux->{aac_sizes} && ref $demux->{aac_sizes} eq 'ARRAY') {
                        my $count = scalar(@{$demux->{aac_sizes}});
                        my $last = $count > 5 ? 4 : $count - 1;
                        $sizes = " (Table sizes: " . join(", ", @{$demux->{aac_sizes}}[0..$last]) . ")";
                    }
                    $log->warn("YANDEX: First demuxed chunk (" . length($demuxed) . " bytes). Start HEX: " . unpack("H14", $demuxed) . $sizes);
                }
                $flac_out .= $demuxed;
            }
        }

        return 0 unless length($flac_out);  # EOF with no pending output

        # Store excess if demux produced more than one read's worth
        if (length($flac_out) > $length) {
            ${*$self}{yandex_demux_pending} = substr($flac_out, $length);
            $flac_out = substr($flac_out, 0, $length);
        }

        substr($_[1], $offset, length($flac_out)) = $flac_out;
        return length($flac_out);
    }

    # --- Normal AES-CTR path (plain flac, aac-mp4, etc.) ---
    my $bytes_read = $self->SUPER::_sysread($_[1], $length, $offset);
    return $bytes_read unless defined $bytes_read && $bytes_read > 0;

    my $stream_pos = ${*$self}{yandex_offset} // 0;
    my $plain      = _aes_ctr_xor($cipher, substr($_[1], $offset, $bytes_read), $stream_pos);
    substr($_[1], $offset, $bytes_read) = $plain;
    ${*$self}{yandex_offset} = $stream_pos + $bytes_read;

    # On first read of a plain FLAC stream, parse STREAMINFO for accurate metadata
    if ($stream_pos == 0 && !${*$self}{yandex_flac_parsed} && ${*$self}{yandex_song}) {
        _parse_flac_streaminfo($self, \$_[1], $offset, $bytes_read);
        ${*$self}{yandex_flac_parsed} = 1;
    }

    return $bytes_read;
}

# Parse FLAC STREAMINFO block from the beginning of a decrypted stream.
# Sets samplerate, samplesize, channels, bitrate and duration on the LMS track object.
# FLAC stream layout:
#   Bytes  0- 3: "fLaC" marker
#   Byte   4:    last_block(1) | block_type(7)  — 0 = STREAMINFO
#   Bytes  5- 7: block_length (big-endian, 3 bytes) — 34 for STREAMINFO
#   Bytes  8- 9: min_blocksize
#   Bytes 10-11: max_blocksize
#   Bytes 12-14: min_framesize
#   Bytes 15-17: max_framesize
#   Bytes 18-25: packed 64 bits: samplerate(20) | (ch-1)(3) | (bps-1)(5) | total_samples(36)
sub _parse_flac_streaminfo {
    use bytes;
    my ($sock, $dataref, $offset, $bytes_read) = @_;

    return unless $bytes_read >= 26;  # need at least 26 bytes to reach packed bits

    my $data = substr($$dataref, $offset, $bytes_read);

    # Verify fLaC marker
    return unless substr($data, 0, 4) eq 'fLaC';

    # First metadata block must be STREAMINFO (type 0)
    my $block_type = unpack('C', substr($data, 4, 1)) & 0x7F;
    return unless $block_type == 0;

    # Parse packed 64-bit field at bytes 18-25
    my ($hi, $lo) = unpack('NN', substr($data, 18, 8));

    my $sample_rate     = ($hi >> 12) & 0xFFFFF;
    my $channels        = (($hi >> 9) & 0x7) + 1;
    my $bits_per_sample = (($hi >> 4) & 0x1F) + 1;
    my $total_samples   = ($hi & 0xF) * 4294967296 + $lo;

    return unless $sample_rate > 0;

    my $duration    = $total_samples > 0 ? $total_samples / $sample_rate : 0;
    # Estimate compressed bitrate (~60% of uncompressed, typical for FLAC)
    my $avg_bitrate = int($sample_rate * $bits_per_sample * $channels * 0.6);

    $log->info("YANDEX FLAC: samplerate=$sample_rate bps=$bits_per_sample ch=$channels"
        . " samples=$total_samples duration=${duration}s bitrate=$avg_bitrate");

    my $song  = ${*$sock}{yandex_song};
    my $track = $song ? $song->track() : undef;
    return unless $track;

    $track->samplerate($sample_rate);
    $track->samplesize($bits_per_sample);
    $track->channels($channels);
    $track->content_type('flc');
    Slim::Music::Info::setBitrate($track, $avg_bitrate, 1);  # 1 = VBR (FLAC is variable bitrate)
    Slim::Music::Info::setDuration($track, $duration) if $duration;

    # Register FLAC frame alignment processor — enables seeking support
    eval {
        require Slim::Formats::FLAC;
        require Slim::Schema::RemoteTrack;
        $track->processors('flc',
            Slim::Schema::RemoteTrack::INITIAL_BLOCK_ONSEEK(),
            \&Slim::Formats::FLAC::initiateFrameAlign);
    };
    $log->warn("YANDEX FLAC: processor registration failed: $@") if $@;
}

# XOR $data (starting at $stream_pos) with AES-CTR keystream generated by $cipher (ECB mode).
#
# Fast path: if $cipher implements keystream_xor() (our AES128 pure-Perl backend),
# delegate to it — it processes all blocks in one call with local T-table copies,
# pre-computed Round-1 constants, and a single C-level string ^ at the end.
#
# Fallback: block-by-block loop used for Crypt::Rijndael (which lacks keystream_xor).
sub _aes_ctr_xor {
    use bytes;
    my ($cipher, $data, $stream_pos) = @_;

    return $cipher->keystream_xor($data, $stream_pos)
        if $cipher->can('keystream_xor');

    # Fallback: Crypt::Rijndael or any other ECB cipher without keystream_xor.
    # Reuse a single 16-byte counter buffer; update only the last 4 bytes per block.
    # >> 4 and & 15 replace int()/% — bit-ops are ~3× faster on ARM.
    my $len     = length($data);
    my $out     = '';
    my $i       = 0;
    my $blk_num = $stream_pos >> 4;
    my $counter = "\x00" x 12 . pack('N', $blk_num);

    while ($i < $len) {
        my $abs     = $stream_pos + $i;
        my $new_blk = $abs >> 4;
        my $blk_off = $abs & 15;

        if ($new_blk != $blk_num) {
            $blk_num = $new_blk;
            substr($counter, 12, 4) = pack('N', $blk_num);
        }

        my $keystream = $cipher->encrypt($counter);
        my $take      = 16 - $blk_off;
        $take = $len - $i if $len - $i < $take;
        $out .= substr($data, $i, $take) ^ substr($keystream, $blk_off, $take);
        $i   += $take;
    }
    return $out;
}

1;