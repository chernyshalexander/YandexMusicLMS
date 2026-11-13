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
  new() / _sysread()      — raw transport: passes bytes through (or feeds MP4Demux);
                            encraw: decrypts bytes via AES-CTR on the fly
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
use Plugins::yandex::API::Common;
use Slim::Utils::Cache;
use Plugins::yandex::Browse;

use base qw(Slim::Player::Protocols::HTTPS);
use URI::Escape;
use Slim::Utils::Prefs;
use Time::HiRes;

require Slim::Player::Playlist;
require Slim::Player::Source;
require Slim::Control::Request;
require Plugins::yandex::Decode::AES128;


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
            } elsif ($meta->{codec} =~ /^(?:aac|he-aac)$/) {
                $content_type = 'audio/aac';
            } elsif ($meta->{codec} eq 'mp3') {
                $content_type = 'audio/mpeg';
            }

            # Determine the byte offset for resume/seek BEFORE the stream is
            # opened. Core issues the HTTP Range request itself (restartOffset
            # after reconnect, sourceStreamOffset after seek), see
            # Slim::Player::Protocols::HTTP request(). At constructor time the
            # response does not exist yet, so Content-Range cannot be read here
            # — the old $sock->contentRange approach never fired, leaving
            # yandex_offset=0 → wrong AES-CTR counter on Range resume → whistle.
            # AES-CTR keystream position equals the absolute byte position in
            # the file, so initializing the offset from seekdata is exact
            # (same approach as the Deezer plugin, which rebuilds its Blowfish
            # chunk state from $seekdata->{sourceStreamOffset}).
            my $initial_offset = 0;
            if (delete ${*$sock}{yandex_restart_from_zero}) {
                # ip3k resume: requestString() turned this into a full restart -
                # ordinary from-byte-0 fetch, keystream from 0, no demux skip.
                $log->warn("YANDEX: ip3k resume: track restarted from the beginning (position reset to 0:00)");
            }
            else {
                my $seekdata = $song->can('seekdata') ? $song->seekdata : $song->{'seekdata'};
                if ($seekdata) {
                    if ($seekdata->{timeOffset}) {
                        my $calc = $class->getSeekData($client, $song, $seekdata->{timeOffset});
                        if ($calc && $calc->{sourceStreamOffset}) {
                            $seekdata->{sourceStreamOffset} = $calc->{sourceStreamOffset};
                        }
                    }
                    $initial_offset = int($seekdata->{restartOffset} || $seekdata->{sourceStreamOffset} || 0);
                }
            }
            # For MP4-container codecs requestString() has already turned this resume
            # into a from-byte-0 fetch (a mid-file MP4 stream cannot be demuxed) and
            # stashed the resume offset in yandex_demux_skip. The keystream then starts
            # at 0 and the demuxer discards decoded audio up to the resume offset.
            my $demux_skip = ${*$sock}{yandex_demux_skip} || 0;
            if ($demux_skip) {
                $log->warn("YANDEX: MP4 resume: fetching from byte 0, demuxer will skip decoded audio up to byte $demux_skip");
                $initial_offset = 0;
            }
            elsif ($initial_offset > 0) {
                $log->warn("YANDEX: Range resume/seek at byte $initial_offset, initializing AES-CTR offset from seekdata");
            }

            if ($meta->{aes_key}) {
                eval {
                    require Plugins::yandex::API::Async;
                    my $key_bytes = pack('H*', $meta->{aes_key});
                    ${*$sock}{yandex_cipher} = Plugins::yandex::API::Async::make_aes_cipher($key_bytes);
                    ${*$sock}{yandex_offset} = $initial_offset;
                    $log->info("YANDEX: AES-CTR cipher ready for track $track_id, initial_offset=$initial_offset");
                };
                $log->error("YANDEX: AES cipher init failed: $@") if $@;
            }
            # Set up MP4Demux for flac-mp4 and aac-mp4. With the ffmpeg backend it is
            # used only on resume: ffmpeg cannot start decoding mid-container (it needs
            # ftyp/moov from byte 0), while requestString() has already switched this
            # connection to a from-byte-0 fetch, so the internal demuxer is the only
            # way to reach the resume position.
            #
            # Raw (unencrypted) streams have no cipher, but the internal demuxer is
            # still required when demux_backend=internal or on resume. Do NOT gate
            # this on yandex_cipher: raw+internal would otherwise send MP4 bytes to
            # a player that formatOverride() told to expect raw FLAC/AAC.
            if ($meta->{codec} && $meta->{codec} =~ /-mp4$/) {
                my $demux_backend = $prefs->get('demux_backend') || 'ffmpeg';
                if ($demux_skip || $demux_backend eq 'internal') {
                    if (!$demux_skip && $initial_offset > 0) {
                        # Defensive: Range resume without the requestString hook.
                        # MP4Demux expects the complete file from start (moov → moof/mdat),
                        # partial data would break the parser. Fallback to ffmpeg.
                        $log->warn("YANDEX: Range request detected for $meta->{codec} track $track_id at offset $initial_offset. Disabling internal demux (would fail mid-stream). Fallback to ffmpeg.");
                    } else {
                        eval {
                            require Plugins::yandex::Decode::MP4Demux;
                            my $demux_codec = ($meta->{codec} =~ /aac/) ? 'aac' : 'flac';
                            ${*$sock}{yandex_demux} = Plugins::yandex::Decode::MP4Demux->new(codec => $demux_codec);
                            if ($demux_codec eq 'aac') {
                                $content_type = 'audio/aac';
                            }
                            $log->info("YANDEX: MP4Demux (internal) enabled for $meta->{codec} track $track_id"
                                . ($demux_skip ? " (resume: skipping decoded audio up to byte $demux_skip)" : ""));
                        };
                        $log->error("YANDEX: MP4Demux init failed: $@") if $@;
                    }
                }
            }
            # Store song ref for FLAC header parsing in _sysread (plain flac only - kept commented for reference)
            # ${*$sock}{yandex_song} = $song if $meta->{codec} && $meta->{codec} eq 'flac';
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
         
         if (!$duration && $original_url =~ /yandexmusic:\/\/(?:track\/)?(\d+)/) {
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

             my $yandex_client = Plugins::yandex::Plugin::getAPIForClient($client);
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

# Intercept open / request to ensure initialAudioBlock is defined on seeking remote streams.
# Without this, Slim::Player::Protocols::HTTP::request passes $track->initial_block_fn
# (which is undef for remote streams) into Slim::Formats::MP3::getInitialAudioBlock,
# crashing with: "Can't use an undefined value as filehandle reference at Slim/Formats/MP3.pm line 191".
# Defining initialAudioBlock as '' tells HTTP::request that no initial audio header block
# is needed and avoids attempting to read frame boundaries from an undef filehandle.
sub open {
    my ($self, $args) = @_;
    my $song = ($args && $args->{'song'}) || (ref $self ? ${*$self}{'song'} : undef);
    if ($song && $song->can('initialAudioBlock') && !defined $song->initialAudioBlock) {
        $song->initialAudioBlock('');
    }
    return $self->SUPER::open($args);
}

sub request {
    my ($self, $args) = @_;
    my $song = ($args && $args->{'song'}) || (ref $self ? ${*$self}{'song'} : undef);
    if ($song && $song->can('initialAudioBlock') && !defined $song->initialAudioBlock) {
        $song->initialAudioBlock('');
    }
    return $self->SUPER::request($args);
}

# Intercept the HTTP request the core builds for our stream connection
# (Slim::Formats::RemoteStream::request calls $sock->requestString with the song's
# seekdata). On resume — power-on reconnect, unpause, seek — the core requests
# "Range: bytes=N-" with N estimated mid-file. For MP4-container codecs (flac-mp4,
# aac-mp4) the container header (ftyp/moov) sits at the start of the file, so a
# mid-file stream cannot be demuxed at all: ffmpeg exits with "invalid data" and
# the internal MP4Demux has no moov either. That was the "file open error" and the
# jump to the next track on unpause/power-on resume. For those codecs force a fetch
# from byte 0 (no Range offset) and let the internal demuxer skip decoded audio up
# to the resume offset — see yandex_demux_skip consumed in _sysread().
sub requestString {
    my $self = shift;
    my ($client, $url, $post, $seekdata) = @_;

    if ($seekdata && $seekdata->{timeOffset}) {
        my $song = ${*$self}{'song'};
        if ($song) {
            my $calc = $self->getSeekData($client, $song, $seekdata->{timeOffset});
            if ($calc && $calc->{sourceStreamOffset}) {
                $seekdata->{sourceStreamOffset} = $calc->{sourceStreamOffset};
            }
        }
    }

    my $skip = ($seekdata && $self->_mp4_resume_offset($seekdata)) || 0;
    if ($skip > 0) {
        # ip3k players (Boom and other non-SqueezePlay devices) have strict FLAC
        # decoders that stall even on a correctly frame-aligned resume stream, so
        # for them restart the whole track from byte 0 on the ordinary fresh-start
        # path (ffmpeg backend, no demux skip) instead of the skip-resume below.
        if ($client && !$client->isa('Slim::Player::SqueezePlay')) {
            ${*$self}{yandex_restart_from_zero} = 1;
            $log->warn("YANDEX: MP4 resume on ip3k player: restarting the track from the beginning instead of skip-resume");
            # Zero byte offsets AND timeOffset: fetch from byte 0 and make the core
            # show the track position from 0:00 so display and feedback match audio.
            my $modified = { %$seekdata, restartOffset => 0, sourceStreamOffset => 0, timeOffset => 0 };
            return $self->SUPER::requestString($client, $url, $post, $modified);
        }
        ${*$self}{yandex_demux_skip} = $skip;
        $log->warn("YANDEX: MP4 resume at byte $skip: requesting the stream from byte 0, suppressing Range (demuxer will skip ahead)");
        # Rebuild the request with zeroed byte offsets so the core sends "Range: bytes=0-"
        my $modified = { %$seekdata, restartOffset => 0, sourceStreamOffset => 0 };
        my $request = $self->SUPER::requestString($client, $url, $post, $modified);
        # SUPER::requestString fixes the progress bar only for non-zero offsets — redo it here
        if (defined $seekdata->{timeOffset} && $client) {
            $client->playingSong()->startOffset($seekdata->{timeOffset});
            $client->master()->remoteStreamStartTime(Time::HiRes::time() - $seekdata->{timeOffset}) if $client->master();
        }
        return $request;
    }

    return $self->SUPER::requestString($client, $url, $post, $seekdata);
}

# Returns the resume byte offset if this connection opens an MP4-container codec
# mid-file, else 0. Object context only: ${*$self}{'song'} is set by the base
# HTTPS::new before the request is sent.
sub _mp4_resume_offset {
    my ($self, $seekdata) = @_;
    return 0 unless ref($self) && $seekdata;
    my $offset = int($seekdata->{restartOffset} || $seekdata->{sourceStreamOffset} || 0);
    return 0 unless $offset > 0;

    my $song = ${*$self}{'song'} || return 0;
    my $orig_url = $song->currentTrack ? $song->currentTrack->url : '';
    return 0 unless $orig_url =~ /yandexmusic:\/\/(?:track\/)?(\d+)/;
    my $meta = Slim::Utils::Cache->new()->get('yandex_meta_' . $1);
    return ($meta && $meta->{codec} && $meta->{codec} =~ /-mp4$/) ? $offset : 0;
}

sub canSeek {
    my ($class, $client, $song) = @_;
    return 0 unless $song;
    my $seconds = $song->duration();
    if (!$seconds && $song->can('currentTrack') && $song->currentTrack) {
        $seconds = $song->currentTrack->duration();
    }
    if (!$seconds) {
        my $url = ($song->can('currentTrack') && $song->currentTrack) ? $song->currentTrack->url : '';
        if ($url =~ /yandexmusic:\/\/(?:track\/)?(\d+)/) {
            my $meta = Slim::Utils::Cache->new()->get('yandex_meta_' . $1);
            $seconds = $meta->{duration} if $meta;
        }
    }
    return 0 unless $seconds;
    return 1;
}

sub getSeekData {
    my ($class, $client, $song, $newtime) = @_;
    return unless defined $newtime && $newtime >= 0;

    # Prefer the plugin cache for Yandex tracks: it holds the codec-specific
    # estimate or the measured stream bitrate. Song::bitrate() falls back to
    # the LMS DB, which may still contain a stale bitrate from a previous
    # MP3/AAC resolution of the same track and would corrupt seek offsets.
    my $bitrate = 0;
    if ($song) {
        my $url = ($song->can('currentTrack') && $song->currentTrack) ? $song->currentTrack->url : '';
        if ($url =~ /yandexmusic:\/\/(?:track\/)?(\d+)/) {
            my $meta = Slim::Utils::Cache->new()->get('yandex_meta_' . $1);
            $bitrate = $meta->{bitrate} if $meta && $meta->{bitrate};
        }
    }
    $bitrate ||= ($song && $song->can('bitrate')) ? $song->bitrate() : 0;
    $bitrate ||= 900000;

    my $offset = int((($bitrate) / 8) * $newtime);
    $offset -= $offset % 16;

    return {
        sourceStreamOffset => $offset,
        timeOffset         => $newtime,
    };
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
    $log->info("YANDEX: getNextTrack called for: $url");

    my $initial_offset = 0;
    if ($url =~ /[?&]offset=(\d+(?:\.\d+)?)/) {
        $initial_offset = $1;
        if ($initial_offset > 0) {
            my $sd = ($song->can('seekdata') ? $song->seekdata : $song->{'seekdata'}) || {};
            $sd->{timeOffset} = $initial_offset;
            my $calc = $class->getSeekData($song->master(), $song, $initial_offset);
            if ($calc && $calc->{sourceStreamOffset}) {
                $sd->{sourceStreamOffset} = $calc->{sourceStreamOffset};
            }
            $song->seekdata($sd);
            $song->startOffset($initial_offset);
            $song->initialAudioBlock('') if $song->can('initialAudioBlock');
            $log->info("YANDEX: getNextTrack initialized offset $initial_offset s (preliminary sourceStreamOffset: " . ($sd->{sourceStreamOffset} || 0) . ")");
        }
    }

    $class->_resolveStreamUrl($song, sub {
        # Re-calculate byte offset now that exact codec & bitrate are resolved and cached
        if ($initial_offset > 0) {
            my $sd = ($song->can('seekdata') ? $song->seekdata : $song->{'seekdata'}) || {};
            $sd->{timeOffset} = $initial_offset;
            my $calc = $class->getSeekData($song->master(), $song, $initial_offset);
            if ($calc && $calc->{sourceStreamOffset}) {
                $sd->{sourceStreamOffset} = $calc->{sourceStreamOffset};
                $song->seekdata($sd);
                $log->info("YANDEX: getNextTrack refreshed offset $initial_offset s with resolved bitrate (sourceStreamOffset: " . $sd->{sourceStreamOffset} . ")");
            }
            $song->initialAudioBlock('') if $song->can('initialAudioBlock');
        }
        # Stamp the resolve time so updateOnStream() (called by the core right
        # before opening the stream) does not hit the API a second time.
        $song->pluginData('yandex_url_resolved_at' => time());
        $successCb->();
    }, $errorCb);
}

# Core hook (StreamingController::_Stream): called before EVERY (re)open of the
# song's stream, including the resume paths that bypass getNextTrack() entirely —
# reconnect after a dropped connection (_Continue) and seek/power-on resume
# (_JumpToTime). Those paths would re-open a long-stale CDN URL (expired after
# ~1h) and re-read an expired AES key cache, producing garbage audio or a track
# error. Re-resolving here gives every (re)open a fresh URL and fresh key.
# See docs/resume-bug-investigation.md.
sub updateOnStream {
    my ($class, $song, $successCb, $errorCb) = @_;

    $song->initialAudioBlock('') if $song && $song->can('initialAudioBlock') && !defined $song->initialAudioBlock;

    my $resolved_at = $song->pluginData('yandex_url_resolved_at') || 0;
    my $age = $resolved_at ? time() - $resolved_at : -1;

    if ($age >= 0 && $age < 300) {
        # URL was just resolved by getNextTrack() - no need to hit the API again
        $successCb->();
        return;
    }

    $log->info("YANDEX: updateOnStream: stream URL is " . ($age < 0 ? "unresolved" : "${age}s old") . ", re-resolving");

    $class->_resolveStreamUrl($song, sub {
        $song->pluginData('yandex_url_resolved_at' => time());
        $successCb->();
    }, $errorCb);
}

sub _resolveStreamUrl {
    my ($class, $song, $successCb, $errorCb) = @_;

    my $url = $song->currentTrack()->url;

    my $track_id = $url;
    unless ($url =~ /yandexmusic:\/\/(?:track\/)?(\d+)/) {
        $log->error("YANDEX: Can't parse ID from URL: $url");
        $errorCb->('Invalid URL format');
        return;
    }
    $track_id = $1;

    # Get client instance from Plugin
    my $client = $song->master();
    my $yandex_client = Plugins::yandex::Plugin::getAPIForClient($client);

    unless ($yandex_client) {
        $log->error("YANDEX: Could not get Yandex client instance. Plugin might not be initialized.");
        $errorCb->('Plugin not initialized');
        return;
    }

    # Request track stream URL directly using API.pm
    $yandex_client->get_track_direct_url($track_id, sub {
        my ($final_url, $error, $bitrate, $codec, $aes_key, $info) = @_;
        $info ||= {};

        if ($final_url) {
            $log->info("YANDEX: URL resolved codec=" . ($codec||'mp3')
                . " bitrate=" . ($bitrate||0)
                . " quality=" . ($info->{quality} || 'unknown')
                . " transport=" . ($info->{transport} || 'unknown')
                . " realId=" . ($info->{real_id} || $track_id)
                . " gain=" . ($info->{gain} ? 1 : 0)
                . " encrypted=" . ($aes_key ? 'yes' : 'no'));

            # Save bitrate, codec, transport metadata and AES key to cache for
            # new() / _sysread() / getMetadataFor(). Preserve existing title,
            # artist, album, duration and cover fields.
            my $cache = Slim::Utils::Cache->new();
            my $cached_meta = $cache->get('yandex_meta_' . $track_id) || {};
            my $prev_codec  = $cached_meta->{codec};

            $cached_meta->{codec} = $codec if $codec;
            if (defined $prev_codec && defined $codec && $prev_codec ne $codec) {
                # A different codec means a different container/file size.
                delete $cached_meta->{content_length};
            }

            # MP3/AAC: the API returns the real nominal bitrate. FLAC: the API
            # always returns 0, so keep an estimate for seek math until
            # parseDirectHeaders() computes the real average bitrate.
            if ($codec && $codec =~ /^flac/) {
                if ($bitrate && $bitrate > 0) {
                    $cached_meta->{bitrate} = $bitrate;
                    $cached_meta->{bitrate_source} = $info->{bitrate_source} || 'api';
                } else {
                    $cached_meta->{bitrate} = 900000;
                    $cached_meta->{bitrate_source} = 'estimate';
                }
            } elsif ($bitrate) {
                $cached_meta->{bitrate} = $bitrate;
                $cached_meta->{bitrate_source} = $info->{bitrate_source} || 'api';
            } else {
                delete $cached_meta->{bitrate};
                delete $cached_meta->{bitrate_source};
            }

            $cached_meta->{quality} = $info->{quality} if $info->{quality};
            $cached_meta->{requested_quality} = $info->{requested_quality} if $info->{requested_quality};
            $cached_meta->{real_id} = $info->{real_id} if $info->{real_id};
            $cached_meta->{gain} = $info->{gain} ? 1 : 0 if exists $info->{gain};
            $cached_meta->{transport} = $info->{transport} if $info->{transport};
            $cached_meta->{requested_transport} = $info->{requested_transport} if $info->{requested_transport};

            if (ref $info->{urls} eq 'ARRAY' && @{$info->{urls}}) {
                my $last = $#{$info->{urls}} < 2 ? $#{$info->{urls}} : 2;
                $cached_meta->{urls} = [ @{$info->{urls}}[0 .. $last] ];
            } else {
                delete $cached_meta->{urls};
            }

            if ($aes_key) {
                $cached_meta->{aes_key} = $aes_key;
            } else {
                # Raw/direct streams have no key. Remove a stale key left by a
                # previous encraw playback of the same track.
                delete $cached_meta->{aes_key};
            }

            # Codec and AES key are constants of the track (Deezer derives its
            # key from the track id forever, Tidal/Qobuz cache track meta for
            # 30-90 days) - keep them for a day instead of an hour. The CDN URL
            # itself is the only short-lived part; updateOnStream() re-resolves
            # it before every stream (re)open.
            $cache->set('yandex_meta_' . $track_id, $cached_meta, 86400);

            # Explicitly set metadata in LMS DB for proper UI display
            my $track_url = $song->track()->url();
            eval {
                my $ct          = _content_type_for_codec($codec);
                my $is_lossless = ($codec && $codec =~ /^flac/) ? 1 : 0;
                my $is_vbr      = $is_lossless ? 1 : undef;

                if ($ct) {
                    Slim::Schema->updateOrCreate({
                        url        => $track_url,
                        readTags   => 0,
                        commit     => 1,
                        attributes => {
                            CONTENT_TYPE => $ct,
                            LOSSLESS     => $is_lossless,
                        },
                    });
                    my $track_obj = $song->track();
                    if ($track_obj && $track_obj->can('content_type') && ($track_obj->content_type || '') ne $ct) {
                        $track_obj->content_type($ct);
                        $track_obj->update() if $track_obj->can('update');
                    }
                    Slim::Schema->clearContentTypeCache($track_url);

                    # Never publish the 900000 FLAC estimate: it would show up
                    # as a fake "900 kbps" in LMS. Real FLAC bitrate is filled
                    # in later by _update_real_bitrate().
                    my $publish_bitrate = 0;
                    if ($is_lossless) {
                        $publish_bitrate = $bitrate || 0
                            if ($cached_meta->{bitrate_source} || '') ne 'estimate';
                    } else {
                        $publish_bitrate = $bitrate || 0;
                    }

                    if ($publish_bitrate > 0) {
                        Slim::Music::Info::setBitrate($track_url, $publish_bitrate, $is_vbr);
                        $log->info("YANDEX: Set content_type=$ct bitrate=$publish_bitrate vbr=" . ($is_vbr ? 1 : 0) . " for $codec track");
                    } else {
                        $log->info("YANDEX: Set content_type=$ct (bitrate pending real measurement) for $codec track");
                    }
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

            # MP4-container codecs: the internal pure-Perl demuxer is mandatory on
            # resume (requestString() fetches from byte 0 and skips decoded audio up
            # to the resume offset; ffmpeg cannot start mid-container), regardless
            # of the demux_backend pref. ip3k players (Boom family) restart the
            # track instead of skip-resume - they use the plain pref-based format.
            my $seekdata = $song->can('seekdata') ? $song->seekdata : $song->{'seekdata'};
            my $resume = ($seekdata ? int($seekdata->{restartOffset} || $seekdata->{sourceStreamOffset} || 0) : 0) > 0;
            my $client = $song->master();
            $resume = 0 if $resume && $client && !$client->isa('Slim::Player::SqueezePlay');
            my $internal = ($prefs->get('demux_backend') || 'ffmpeg') eq 'internal' || $resume;

            # FLAC in MP4: internal pure-Perl demux or ffmpeg via custom-convert.conf ymf → flc
            if ($codec eq 'flac-mp4') {
                if ($internal) {
                    $log->info("YANDEX: formatOverride -> flc for $url (flac-mp4, internal demux)");
                    return 'flc';
                }
                $log->info("YANDEX: formatOverride -> ymf for $url (flac-mp4, ffmpeg demux)");
                return 'ymf';
            }
            # aac-mp4, he-aac-mp4: pure-Perl demux -> aac, ffmpeg transcoding -> yma
            if ($codec =~ /-mp4$/) {
                if ($internal) {
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
            # Raw AAC / HE-AAC (ADTS): no container demux needed
            if ($codec =~ /^(?:aac|he-aac)$/) {
                $log->info("YANDEX: formatOverride -> aac for $url ($codec)");
                return 'aac';
            }
        }
    }
    return undef;
}

sub getFormatForURL {
    my ($class, $url) = @_;
    # Pre-demuxed FLAC temp file
    return 'flc' if $url =~ /^file:\/\//;
    if ($url && $url =~ /yandexmusic:\/\/(?:track\/)?(\d+)/) {
        my $cache = Slim::Utils::Cache->new();
        my $meta  = $cache->get('yandex_meta_' . $1);
        if ($meta && $meta->{codec}) {
            # flac-mp4: internal demux → flc, ffmpeg demux → flac-MP4 (formatOverride selects ymf)
            if ($meta->{codec} eq 'flac-mp4') {
                return 'flc' if ($prefs->get('demux_backend') || 'ffmpeg') eq 'internal';
                return 'flac-MP4';
            }
            # aac-mp4, he-aac-mp4: pure-Perl demux -> aac, ffmpeg transcoding -> aac-MP4 (formatOverride selects yma)
            if ($meta->{codec} =~ /-mp4$/) {
                return 'aac' if ($prefs->get('demux_backend') || 'ffmpeg') eq 'internal';
                return 'aac-MP4';
            }
            # plain FLAC: decrypted via _sysread()
            return 'flc' if $meta->{codec} eq 'flac';
            # raw AAC / HE-AAC (ADTS)
            return 'aac' if $meta->{codec} =~ /^(?:aac|he-aac)$/;
        }
    }
    my $quality = Plugins::yandex::API::Common::normalize_quality($prefs->get('max_bitrate'));
    return 'flc' if $quality eq 'superb';
    return 'aac' if $quality eq 'balanced' || $quality eq 'efficient';
    return 'mp3';
}

sub _content_type_for_codec {
    my ($codec) = @_;
    return 'mp3' unless $codec;
    return 'flc'      if $codec eq 'flac';
    return 'flac-MP4' if $codec eq 'flac-mp4';
    return 'aac-MP4'  if $codec =~ /-mp4$/;
    return 'aac'      if $codec =~ /^(?:aac|he-aac)$/;
    return 'mp3';
}

# HTTP::parseHeaders calls parseDirectHeaders and then Slim::Music::Info::setContentType($url, $contentType).
# Yandex CDN often returns Content-Type: application/octet-stream for encraw streams, which causes
# HTTP::parseDirectHeaders to default $contentType to 'mp3' and overwrite aac-MP4 / flac-MP4 / flc / aac.
sub parseDirectHeaders {
    my ($class, $client, $url, @headers) = @_;
    my ($title, $bitrate, $metaint, $redir, $contentType, $length, $body)
        = $class->SUPER::parseDirectHeaders($client, $url, @headers);

    my $track_url = (ref($url) && eval { $url->can('url') }) ? $url->url : $url;
    if (!$track_url || $track_url !~ /yandexmusic:\/\/(?:track\/)?(\d+)/) {
        my $s = ref($class) ? eval { ${*$class}{'song'} } : undef;
        if (!$s && $client && $client->can('playingSong')) {
            $s = $client->playingSong;
        }
        $track_url = $s->currentTrack->url if $s && $s->can('currentTrack') && $s->currentTrack;
    }
    if ($track_url && $track_url =~ /yandexmusic:\/\/(?:track\/)?(\d+)/) {
        my $meta = Slim::Utils::Cache->new()->get('yandex_meta_' . $1);
        if ($meta && $meta->{codec}) {
            $contentType = _content_type_for_codec($meta->{codec});
        }

        # Content-Length/Content-Range lets us replace the FLAC bitrate
        # estimate with the real average stream bitrate. Skip redirect
        # responses: their small HTML body is not the media stream.
        unless ($redir) {
            my ($has_content_range) = grep { /^Content-Range:/i } @headers;
            my ($range_total) = map {
                /^Content-Range:\s*bytes\s+\d+-\d+\/(\d+)/i ? $1 : ()
            } @headers;
            _update_real_bitrate($class, $client, $track_url, $length, $has_content_range, $range_total);
        }
    }

    return ($title, $bitrate, $metaint, $redir, $contentType, $length, $body);
}

# Compute average stream bitrate in bps from the total byte length and
# duration. Returns undef for invalid or implausible inputs.
sub _compute_bitrate_bps {
    my ($length, $duration) = @_;
    return undef unless defined $length && defined $duration;

    $length   =~ s/\s+//g if !ref $length;
    $duration =~ s/\s+//g if !ref $duration;
    return undef unless $length =~ /^\d+$/ && $duration =~ /^\d+(?:\.\d+)?$/;
    return undef unless $length > 0 && $duration > 0;

    my $bps = int($length * 8 / $duration);
    return undef if $bps < 64000 || $bps > 5000000;
    return $bps;
}

# Fill in the real average bitrate once the stream response has supplied the
# total length. MP3/AAC already have a real nominal bitrate from the API;
# FLAC always reports 0, so this is where its display value comes from.
sub _update_real_bitrate {
    my ($sock, $client, $track_url, $length, $has_content_range, $range_total) = @_;
    return unless $track_url && $track_url =~ /yandexmusic:\/\/(?:track\/)?(\d+)/;
    my $track_id = $1;

    my $cache = Slim::Utils::Cache->new();
    my $meta  = $cache->get('yandex_meta_' . $track_id);
    return unless $meta && $meta->{codec};

    # API bitrate for MP3/AAC is already the real nominal bitrate.
    return if ($meta->{bitrate_source} || '') eq 'api' && $meta->{codec} !~ /^flac/;

    if ($has_content_range) {
        # 206: only the numeric total from Content-Range is the whole file.
        # "Content-Range: bytes N-M/*" (unknown total) must not be used.
        $range_total =~ s/\s+//g if defined $range_total && !ref $range_total;
        return unless defined $range_total && $range_total =~ /^\d+$/ && $range_total > 0;
        $length = $range_total;
    } else {
        # 200: Content-Length is the whole file, even when the request asked
        # for Range: bytes=0- and seekdata still carries a nonzero offset.
        $length =~ s/\s+//g if defined $length && !ref $length;
        return unless defined $length && $length =~ /^\d+$/ && $length > 0;
    }

    my $song = ref($sock) ? eval { ${*$sock}{'song'} } : undef;
    if (!$song && $client && $client->can('playingSong')) {
        $song = $client->playingSong;
    }

    if (($meta->{content_length} || 0) != $length) {
        $meta->{content_length} = $length;
        $cache->set('yandex_meta_' . $track_id, $meta, 86400);
    }

    my $duration = $meta->{duration}
        || ($song && $song->can('duration') ? $song->duration : 0)
        || 0;
    return unless $duration > 0;

    my $bps = _compute_bitrate_bps($length, $duration);
    return unless $bps;

    return if ($meta->{bitrate_source} || '') eq 'content-length'
           && ($meta->{bitrate} || 0) == $bps;

    $meta->{bitrate}           = $bps;
    $meta->{bitrate_source}    = 'content-length';
    $meta->{bitrate_estimated} = 0;
    $cache->set('yandex_meta_' . $track_id, $meta, 86400);

    my $is_lossless = ($meta->{codec} || '') =~ /^flac/ ? 1 : 0;
    eval { Slim::Music::Info::setBitrate($track_url, $bps, $is_lossless ? 1 : undef) };

    if ($song && $song->can('bitrate')) {
        eval { $song->bitrate($bps) };
    }

    $log->info("YANDEX: real stream bitrate for $track_id codec=$meta->{codec}: "
        . int($bps / 1000) . " kbps (length=$length duration=${duration}s)");

    if ($client && $client->can('currentPlaylistUpdateTime')) {
        eval {
            $client->currentPlaylistUpdateTime(Time::HiRes::time());
            Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
        };
    }
}

sub isRemote { 1 }
sub isAudio { 1 }

# If the stream length was captured before the track duration was known,
# promote the FLAC estimate to the real average bitrate on the next metadata
# poll. No notification here: the caller is already building the metadata.
sub _promote_stored_bitrate {
    my ($track_id, $url, $meta) = @_;
    return unless $meta && $meta->{codec};
    return if ($meta->{bitrate_source} || '') eq 'api';
    return if ($meta->{bitrate_source} || '') eq 'content-length';
    return unless $meta->{content_length} && $meta->{duration};

    my $bps = _compute_bitrate_bps($meta->{content_length}, $meta->{duration});
    return unless $bps;

    my $is_lossless = $meta->{codec} =~ /^flac/ ? 1 : 0;
    $meta->{bitrate}           = $bps;
    $meta->{bitrate_source}    = 'content-length';
    $meta->{bitrate_estimated} = 0;
    Slim::Utils::Cache->new()->set('yandex_meta_' . $track_id, $meta, 86400);
    eval { Slim::Music::Info::setBitrate($url, $bps, $is_lossless ? 1 : undef) };
    return $bps;
}

# Return the display type and bitrate string from the actual codec and the
# best available bitrate. No invented 900/192/320 kbps values: FLAC shows a
# real measured bitrate when known, otherwise "Lossless".
sub _display_quality {
    my ($codec, $meta) = @_;
    $codec ||= '';
    $meta  ||= {};

    my $bitrate = $meta->{bitrate} || 0;
    my $source  = $meta->{bitrate_source} || '';

    my $type;
    if ($codec eq 'flac' || $codec eq 'flac-mp4') {
        $type = 'FLAC';
    } elsif ($codec =~ /^(?:aac|he-aac)/ || $codec =~ /-mp4$/) {
        $type = 'AAC';
    } elsif ($codec eq 'mp3') {
        $type = 'MP3';
    } else {
        $type = '';
    }

    my $bitrate_str = '';
    if ($type eq 'FLAC') {
        # Only trust explicitly measured/API bitrates. Missing source means an
        # old cache entry or the 900000 seek estimate — show "Lossless".
        $bitrate_str = ($bitrate > 0 && $source =~ /^(?:api|content-length)$/)
            ? sprintf('%d kbps', int($bitrate / 1000))
            : 'Lossless';
    } elsif ($bitrate > 0) {
        $bitrate_str = sprintf('%d kbps', int($bitrate / 1000));
    }

    return ($type, $bitrate_str);
}

sub getMetadataFor {
    my ($class, $client, $url) = @_;

    # Try to find in cache
    if ($url =~ /yandexmusic:\/\/(?:track\/)?(\d+)/) {
        my $track_id = $1;
        my $cache = Slim::Utils::Cache->new();
        my $cached_meta = $cache->get('yandex_meta_' . $track_id);
        if ($cached_meta) {
            _promote_stored_bitrate($track_id, $url, $cached_meta);
            my $codec = $cached_meta->{codec} || '';
            my ($display_type, $bitrate_str) = _display_quality($codec, $cached_meta);

            # Helper to check if currently playing this track
            my $is_playing_this = $client && $client->playingSong() && $client->playingSong()->track() && $client->playingSong()->track()->url() eq $url;
            
            # If we have complete metadata (or not currently playing), return immediately without API request
            if ($cached_meta->{_complete} || !$is_playing_this) {
                # Save duration to LMS DB if not yet set or changed (for seeking / UI)
                eval {
                    if ($cached_meta->{duration}) {
                        my $cur_dur = Slim::Music::Info->can('getDuration')
                            ? Slim::Music::Info::getDuration($url)
                            : undef;
                        if (!$cur_dur || $cur_dur != $cached_meta->{duration}) {
                            Slim::Music::Info::setDuration($url, $cached_meta->{duration});
                        }
                    }

                    # Also update playing song duration if missing or changed
                    if ($is_playing_this && $cached_meta->{duration}) {
                        my $song = $client->playingSong();
                        if ($song && $song->can('duration') && (!$song->duration() || $song->duration() != $cached_meta->{duration})) {
                            $song->duration($cached_meta->{duration});
                        }
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
            # Do not claim a codec/bitrate before the stream is resolved.
            type   => '',
        };

        # If we have cached metadata (but not _complete), return it with default icon
        if ($cached_meta) {
            my $codec = $cached_meta->{codec} || '';
            my ($display_type, $bitrate_str) = _display_quality($codec, $cached_meta);

            eval {
                if ($cached_meta->{duration}) {
                    my $cur_dur = Slim::Music::Info->can('getDuration')
                        ? Slim::Music::Info::getDuration($url)
                        : undef;
                    if (!$cur_dur || $cur_dur != $cached_meta->{duration}) {
                        Slim::Music::Info::setDuration($url, $cached_meta->{duration});
                    }
                }
            };

            return {
                title    => $cached_meta->{title},
                artist   => $cached_meta->{artist},
                album    => $cached_meta->{album},
                duration => $cached_meta->{duration},
                cover    => $cached_meta->{cover} || $default_icon,
                icon     => $cached_meta->{cover} || $default_icon,
                bitrate  => $bitrate_str,
                type     => $display_type,
            };
        }

        # Fetch metadata asynchronously using pending queue (like Deezer)
        my $yandex_client = Plugins::yandex::Plugin::getAPIForClient($client);
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
    
    if ($url =~ /yandexmusic:\/\/(?:track\/)?(\d+)/) {
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

	my $yandex_client = Plugins::yandex::Plugin::getAPIForClient($client);
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

		# For Vibe Wheel: station_id is '_vibe_', seeds come from ?seeds= param
		my $station_or_seeds = ($station_id eq '_vibe_')
			? [split /,/, ($settings{seeds} // '')]
			: $station_id;

		my @wheel_seeds;
		if ($station_id eq '_vibe_') {
			@wheel_seeds = @$station_or_seeds;
			$log->info("YANDEX VIBE: Exploding session for seeds: " . join(', ', @$station_or_seeds));

			# Record CLICK feedback for the selected vibe wheel seeds
			foreach my $seed (@wheel_seeds) {
				Plugins::yandex::Plugin::add_wheel_feedback($client, 'CLICK', $seed);
			}
		} else {
			@wheel_seeds = ($station_id);
			$log->info("YANDEX NEW ROTOR: Exploding session for station $station_id, settings: " .
				join(', ', map { "$_=$settings{$_}" } keys %settings) . ", queue: " . scalar(@$seen_tracks_prev) . " tracks");
		}

		# 1. Create session
		$yandex_client->rotor_session_new($station_or_seeds, \%settings, $seen_tracks_prev, sub {
			my $session_result = shift;
			my $radio_session_id = $session_result->{radioSessionId};
			my $batch_id = $session_result->{batchId};
			my $sequence = $session_result->{sequence}; # This is an array of items with { track => { ... } }

			# 2. Send radioStarted feedback
			$yandex_client->rotor_session_feedback($radio_session_id, $batch_id, 'radioStarted', $station_id, 0, undef, sub {}, sub {});

			# 2b. Rebuild the wheel around the launched wave (reference: POST wheel/new with the same seeds + accumulated wheel feedbacks).
			# Fire-and-forget: playback must not wait for the wheel response.
			my $rebuild_on_play = $prefs->get('vibe_wheel_rebuild_on_play') // 1;
			if (@wheel_seeds && $rebuild_on_play) {
				my $pending_seed = $client ? $prefs->client($client)->get('yandex_wheel_pending_seed') : undef;
				my $pending_time = $client ? ($prefs->client($client)->get('yandex_wheel_pending_time') || 0) : 0;
				my $current_seeds_str = join(',', @wheel_seeds);

				if ($pending_seed && $pending_seed eq $current_seeds_str && (time() - $pending_time) < 10) {
					$log->debug("VIBE WHEEL: Wheel rebuild already initiated from UI for seeds [$current_seeds_str], skipping duplicate background call");
				} else {
					my $wheel_feedbacks = Plugins::yandex::Plugin::take_wheel_feedbacks($client);
					$yandex_client->wheel_new_with_seeds(
						$client,
						\@wheel_seeds,
						sub {
							my $wheel = shift;
							if ($wheel && $wheel->{wheelId}) {
								Plugins::yandex::Plugin::set_wheel_state($client, {
									wheel_id => $wheel->{wheelId},
									seeds    => \@wheel_seeds,
								});
								Plugins::yandex::Plugin::clear_wheel_snapshot($client);
							}
							$log->info("VIBE WHEEL: Rebuilt for seeds [" . join(',', @wheel_seeds) . "], wheelId=" . (($wheel && $wheel->{wheelId}) ? $wheel->{wheelId} : 'none'));
						},
						sub {
							my $err = shift;
							# Non-fatal: playback already started, the wheel is a separate feature.
							$log->warn("VIBE WHEEL: Rebuild failed for seeds [" . join(',', @wheel_seeds) . "]: $err");
						},
						$wheel_feedbacks,
					);
				}
			}

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

# AES-CTR streaming decryption for encrypted FLAC streams (encraw transport).
# Called by LMS for every chunk read from the remote URL.
sub _sysread {
    use bytes;
    my ($self, undef, $length, $offset) = @_;
    $offset //= 0;

    my $cipher = ${*$self}{yandex_cipher};
    my $demux  = ${*$self}{yandex_demux};

    # Plain pass-through: neither encrypted nor container-demuxed.
    unless ($cipher || $demux) {
        my $bytes = $self->SUPER::_sysread($_[1], $length, $offset);
        if (defined $bytes && $bytes >= 4) {
            my $magic = substr($_[1], $offset, 4);
            if ($magic =~ /^(?:<\?xm|<err|<!do|<htm)/i) {
                $log->error("YANDEX: Stream URL expired or denied. Received error page. Returning EOF.");
                substr($_[1], $offset, $bytes) = '';
                return 0;
            }
        }
        return $bytes;
    }

    if ($demux) {
        # --- Internal streaming demux path (flac-mp4/aac-mp4 → raw FLAC/AAC) ---

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

        # Read MP4 bytes from network (encrypted or raw), optionally decrypt,
        # then demux → FLAC/AAC. Loop until the demuxer produces output or EOF.
        # (The loop runs at most a handful of times: moov is only ~13KB.)
        my $flac_out = '';
        while (length($flac_out) == 0) {
            my $raw = '';
            my $n = $self->SUPER::_sysread($raw, $length, 0);
            return undef unless defined $n;
            last if $n == 0;  # true EOF — FLAC frames need no flush

            # Prevent decrypting Yandex HTML/XML error pages when stream URLs expire during long pauses
            if ($n >= 4) {
                my $magic = substr($raw, 0, 4);
                if ($magic =~ /^(?:<\?xm|<err|<!do|<htm)/i) {
                    $log->error("YANDEX: Stream URL expired or denied. Received error page. Returning EOF.");
                    return 0;
                }
            }

            my $plain;
            if ($cipher) {
                my $sp = ${*$self}{yandex_offset} // 0;
                $plain = Plugins::yandex::Decode::AES128::ctr_decrypt($cipher, $raw, $sp);
                ${*$self}{yandex_offset} = $sp + $n;
            } else {
                # raw transport: bytes are already plaintext
                $plain = $raw;
            }

            # Track how many file bytes have been fed to the demuxer while a resume
            # skip is pending (the skip is measured in input/file bytes, not output).
            my $skip = ${*$self}{yandex_demux_skip} || 0;
            my $fed_before = 0;
            if ($skip) {
                $fed_before = ${*$self}{yandex_demux_fed} || 0;
                ${*$self}{yandex_demux_fed} = $fed_before + $n;
            }

            my $demuxed = $demux->process($plain);

            # Resume-in-MP4: discard decoded audio until the feed position passes the
            # resume offset stashed by requestString(). The demuxer emits per
            # fragment, so at most the fragment straddling the offset (~1s) is lost.
            #
            # Keep the reconstructed FLAC header (fLaC + metadata blocks) even while
            # skipping. It can be emitted in the same process() call that parses moov,
            # and MP4Demux replaces flac_header with 'SENT' immediately afterwards,
            # so inspect the produced bytes and use the permanent header length.
            if ($skip && $fed_before < $skip) {
                if (length($demuxed)) {
                    my $keep = 0;
                    if (($demux->{codec} || '') eq 'flac' && substr($demuxed, 0, 4) eq 'fLaC') {
                        $keep = $demux->{flac_header_len} || 0;
                        $keep = length($demuxed) if $keep > length($demuxed);
                    }
                    $demuxed = $keep ? substr($demuxed, 0, $keep) : '';
                    if (!${*$self}{yandex_demux_skip_logged}++) {
                        $log->info("YANDEX: demux skip: discarding decoded audio before byte $skip"
                            . ($keep ? " (FLAC header kept)" : ""));
                    }
                }
            }

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

    # Prevent decrypting Yandex HTML/XML error pages when stream URLs expire during long pauses
    if ($bytes_read >= 4) {
        my $magic = substr($_[1], $offset, 4);
        if ($magic =~ /^(?:<\?xm|<err|<!do|<htm)/i) {
            $log->error("YANDEX: Stream URL expired or denied. Received plaintext error page. Returning EOF.");
            substr($_[1], $offset, $bytes_read) = '';
            return 0;
        }
    }

    my $plain      = Plugins::yandex::Decode::AES128::ctr_decrypt($cipher, substr($_[1], $offset, $bytes_read), $stream_pos);
    substr($_[1], $offset, $bytes_read) = $plain;
    ${*$self}{yandex_offset} = $stream_pos + $bytes_read;

    # On first read of a plain FLAC stream, parse STREAMINFO for accurate metadata
    # (Kept commented for reference - Yandex Music streams lossless in MP4 container)
    # if ($stream_pos == 0 && !${*$self}{yandex_flac_parsed} && ${*$self}{yandex_song}) {
    #     _parse_flac_streaminfo($self, \$_[1], $offset, $bytes_read);
    #     ${*$self}{yandex_flac_parsed} = 1;
    # }

    return $bytes_read;
}

# Parse FLAC STREAMINFO block from the beginning of a decrypted stream.
# Sets samplerate, samplesize, channels, bitrate and duration on the LMS track object.
# Kept commented for reference: Yandex Music currently delivers FLAC in MP4 container (flac-mp4),
# not raw plain FLAC streams.
# sub _parse_flac_streaminfo {
#     use bytes;
#     my ($sock, $dataref, $offset, $bytes_read) = @_;
# 
#     return unless $bytes_read >= 26;  # need at least 26 bytes to reach packed bits
# 
#     my $data = substr($$dataref, $offset, $bytes_read);
# 
#     # Verify fLaC marker
#     return unless substr($data, 0, 4) eq 'fLaC';
# 
#     # First metadata block must be STREAMINFO (type 0)
#     my $block_type = unpack('C', substr($data, 4, 1)) & 0x7F;
#     return unless $block_type == 0;
# 
#     # Parse packed 64-bit field at bytes 18-25
#     my ($hi, $lo) = unpack('NN', substr($data, 18, 8));
# 
#     my $sample_rate     = ($hi >> 12) & 0xFFFFF;
#     my $channels        = (($hi >> 9) & 0x7) + 1;
#     my $bits_per_sample = (($hi >> 4) & 0x1F) + 1;
#     my $total_samples   = ($hi & 0xF) * 4294967296 + $lo;
# 
#     return unless $sample_rate > 0;
# 
#     my $duration    = $total_samples > 0 ? $total_samples / $sample_rate : 0;
#     # Estimate compressed bitrate (~60% of uncompressed, typical for FLAC)
#     my $avg_bitrate = int($sample_rate * $bits_per_sample * $channels * 0.6);
# 
#     $log->info("YANDEX FLAC: samplerate=$sample_rate bps=$bits_per_sample ch=$channels"
#         . " samples=$total_samples duration=${duration}s bitrate=$avg_bitrate");
# 
#     my $song  = delete ${*$sock}{yandex_song};
#     my $track = $song ? $song->track() : undef;
#     return unless $track;
# 
#     $track->samplerate($sample_rate);
#     $track->samplesize($bits_per_sample);
#     $track->channels($channels);
#     $track->content_type('flc');
#     Slim::Music::Info::setBitrate($track, $avg_bitrate, 1);  # 1 = VBR (FLAC is variable bitrate)
#     Slim::Music::Info::setDuration($track, $duration) if $duration;
# 
#     # Register FLAC frame alignment processor — enables seeking support
#     eval {
#         require Slim::Formats::FLAC;
#         require Slim::Schema::RemoteTrack;
#         $track->processors('flc',
#             Slim::Schema::RemoteTrack::INITIAL_BLOCK_ONSEEK(),
#             \&Slim::Formats::FLAC::initiateFrameAlign);
#     };
#     $log->warn("YANDEX FLAC: processor registration failed: $@") if $@;
# }

1;