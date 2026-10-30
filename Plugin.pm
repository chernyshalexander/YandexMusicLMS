package Plugins::yandex::Plugin;

=encoding utf8

=head1 NAME

Plugins::yandex::Plugin - Yandex Music integration plugin for LMS

=head1 DESCRIPTION

This module implements the Yandex Music plugin for the Lyrion Music Server
(LMS). It manages account storage, creates and caches Yandex API clients,
handles player event callbacks, and integrates with the LMS browsing and
playback system.

=cut

use strict;
use warnings;
use utf8;
use base qw(Slim::Plugin::OPMLBased);

use Plugins::yandex::ProtocolHandler;
use Plugins::yandex::API::Async;
use Plugins::yandex::Browse;
use Plugins::yandex::Browse::InfoMenu;
use Slim::Player::ProtocolHandlers;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Versions;

use constant CAN_IMPORTER => (Slim::Utils::Versions->compareVersions($::VERSION, '8.0.0') >= 0);

my $log;
$log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.yandex',
    'defaultLevel' => 'ERROR',
    'description'  => string('PLUGIN_YANDEX'),
});

my $prefs = preferences('plugin.yandex');

# Cache of API client objects keyed by Yandex user ID.
my %api_clients;
# In-memory snapshot of rendered Vibe Wheel menus keyed by client id
our %wheel_snapshots;
# Last menu list actually DELIVERED to a client as the Vibe Wheel level.
# LMS XMLBrowser re-resolves clicked item indexes against a freshly fetched
# wheel level on every click; that fresh list can have a different wave order
# (rebuild-on-play, snapshot TTL refetch) than what the client still displays.
# Intermediate resolutions must therefore be served from this delivered copy.
our %wheel_delivered_snapshots;

# Main LMS plugin lifecycle hook. Sets up preferences, compatibility handling,
# and integration with both the LMS menu system and Yandex API clients.
sub initPlugin {
    my $class = shift;

    $log->info("YANDEX: initPlugin START");

    $prefs->init({
        accounts => {},
        dontImportAccounts => {},
        max_bitrate => 320,
        remove_duplicates => 1,
        show_chart => 0,
        show_new_releases => 0,
        show_new_playlists => 0,
        show_audiobooks_in_collection => 1,
        yandex_wave_presets => [],
        show_wave_wizard     => 1,
        wizard_station_type  => 'activity',
        wizard_cat_diversity => 1,
        wizard_cat_mood      => 1,
        wizard_cat_language  => 1,
        yandex_wheel_id      => undef,
        yandex_wheel_seeds   => [],
        yandex_wheel_feedbacks => [],
        vibe_wheel_rebuild_on_play => 1,
        yandex_wheel_pending_seed  => undef,
        yandex_wheel_pending_time  => 0,
        show_history               => 1,
        show_resume_quick_item     => 1,
        progress_save_interval     => 30,
    });

    # Preserve compatibility with the old single-token preference by moving

    # Locate ffmpeg and expose its path to LMS so mp4-based media handling works.
    _register_ffmpeg_path();

    my $deps = Plugins::yandex::API::Async::check_dependencies();
    if (!$deps->{rijndael} || !$deps->{ffmpeg}) {
        $log->error("YANDEX: Missing critical dependencies! FLAC/AAC(MP4) playback may fail. Missing: " .
            (!$deps->{rijndael} ? 'Crypt::Rijndael ' : '') .
            (!$deps->{ffmpeg} ? 'ffmpeg' : ''));
    }

    # Register Importer for OnlineLibrary
    $log->info("YANDEX: Registering Importer... (CAN_IMPORTER=" . CAN_IMPORTER . ")");
    Slim::Music::Import->addImporter('Plugins::yandex::Importer', { use => 1, onlineLibraryOnly => 1 });

    # Register service icon for OnlineLibrary (shows Yandex logo on album covers)
    if (Slim::Utils::PluginManager->isEnabled('Slim::Plugin::OnlineLibrary::Plugin')) {
        my $icon_path = '/plugins/yandex/html/images/yandex.png';
        my $ret = eval {
            Slim::Plugin::OnlineLibrary::Plugin->addLibraryIconProvider(
                'yandex',
                $icon_path
            );
        };
        if ($@) {
            $log->warn("YANDEX: Failed to register library icon: $@");
        } else {
            $log->info("YANDEX: Registered library icon at $icon_path");
        }
    } else {
        $log->debug("YANDEX: OnlineLibrary plugin not enabled, skipping library icon registration");
    }

    # Protocol registration
    $log->info("YANDEX INIT: Registering ProtocolHandler...");
    Slim::Player::ProtocolHandlers->registerHandler('yandexmusic', 'Plugins::yandex::ProtocolHandler');

    # Subscription to player status changes
    Slim::Control::Request::subscribe(
        \&playerEventCallback,
        [['playlist', 'mixer', 'play', 'pause', 'time', 'power'], ['newsong', 'jump', 'stop', 'clear', 'volume', 'pause', 'client', 'power']]
    );

    $class->SUPER::initPlugin(
        feed   => \&handleFeed,
        tag    => 'yandex',
        menu   => 'apps',
        weight => 50,
    );

    # Initialize API clients for all accounts at startup
    my $accounts = $prefs->get('accounts') || {};
    foreach my $userId (keys %$accounts) {
        _init_api_client($userId);
    }

    Slim::Menu::TrackInfo->registerInfoProvider( yandex => (
        before => 'top',
        func   => \&Plugins::yandex::Browse::InfoMenu::trackInfoMenu,
    ) );

    Slim::Menu::AlbumInfo->registerInfoProvider( yandex => (
        after => 'top',
        func  => \&Plugins::yandex::Browse::InfoMenu::albumInfoMenu,
    ) );

    Slim::Menu::ArtistInfo->registerInfoProvider( yandex => (
        after => 'top',
        func  => \&Plugins::yandex::Browse::InfoMenu::artistInfoMenu,
    ) );

    if (Slim::Utils::PluginManager->isEnabled('Slim::Plugin::OnlineLibrary::Plugin')) {
        require Slim::Plugin::OnlineLibrary::BrowseArtist;
        Slim::Plugin::OnlineLibrary::BrowseArtist->registerBrowseArtistItem( yandex => sub {
            my ($client) = @_;
            return {
                name => cstring($client, 'PLUGIN_YANDEX_ON_YANDEX'),
                type => 'link',
                icon => $class->_pluginDataFor('icon'),
                url  => \&Plugins::yandex::Browse::InfoMenu::browseArtistMenu,
            };
        });
    }

    Slim::Menu::GlobalSearch->registerInfoProvider( yandex => (
        func => sub {
            my ($client, $tags) = @_;
            return {
                name  => 'Yandex Music',
                items => _globalSearchItems($client, $tags->{search}),
            };
        },
    ) );

    if (main::WEBUI) {
        require Plugins::yandex::Settings;
        Plugins::yandex::Settings->new();
    }
}

# Migrate legacy single-token storage into the current multi-account format.
sub _migrate_legacy_token {
    my $token = $prefs->get('token');
    return unless $token;

    my $accounts = $prefs->get('accounts') || {};
    return if %$accounts;  # Already migrated

    $log->info("YANDEX: Migrating legacy token to accounts hash");
    $accounts->{'migrating'} = { token => $token, name => 'Account', login => '' };
    $prefs->set('accounts', $accounts);
}

# Initialize or refresh the Yandex API client for a specific account.
# The client object is cached in %api_clients and reused while the plugin
# remains loaded.
sub _init_api_client {
    my $userId = shift;

    my $accounts = $prefs->get('accounts') || {};
    my $account  = $accounts->{$userId} || return;
    my $token    = $account->{token}    || return;

    return if exists $api_clients{$userId};  # already initialized

    my $api = Plugins::yandex::API::Async->new($token);
    $api->init(
        sub {
            my $client_instance = shift;
            my $me = $client_instance->get_me();
            my $realUserId = $me->{uid};

            # Replace the temporary migration placeholder with the real
            # Yandex userId once the account metadata becomes available.
            if ($userId eq 'migrating' && $realUserId) {
                my $accounts = $prefs->get('accounts') || {};
                my $data = delete $accounts->{'migrating'};
                $data->{login} = $me->{login} || '';
                $data->{name}  = _format_account_name($me);
                $data->{uid}   = $realUserId;  # Store uid for scanner access
                $accounts->{$realUserId} = $data;
                $prefs->set('accounts', $accounts);
                $prefs->remove('token');  # Clean up legacy pref
                $api_clients{$realUserId} = $client_instance;
                delete $api_clients{'migrating'};
                $log->info("YANDEX: Migrated account to userId=$realUserId");

                # Update any players that had 'migrating' as userId
                foreach my $player (Slim::Player::Client::clients()) {
                    my $pUserId = $prefs->client($player)->get('userId') || '';
                    if ($pUserId eq 'migrating') {
                        $prefs->client($player)->set('userId', $realUserId);
                    }
                }

            } else {
                my $accounts = $prefs->get('accounts') || {};
                if ($accounts->{$userId}) {
                    $prefs->set('accounts', $accounts);
                }
                $api_clients{$userId} = $client_instance;
                $log->info("YANDEX: API client ready for userId=$userId (" . ($me->{login} || '') . ")");
            }
        },
        sub {
            my $error = shift;
            $log->error("YANDEX: API init failed for userId=$userId: $error");
        }
    );
}


# Remove an account's cached API client.
sub _remove_api_client {
    my $userId = shift;
    delete $api_clients{$userId};

    # Cleanup for all players using this account
    foreach my $player (Slim::Player::Client::clients()) {
        my $pUserId = $prefs->client($player)->get('userId') || '';
        if ($pUserId eq $userId) {
            $prefs->client($player)->remove('userId');
        }
    }
}

sub shutdownPlugin {
    my $class = shift;

    # Unsubscribe from player events
    # before the plugin is unloaded.
    Slim::Control::Request::unsubscribe(\&playerEventCallback);

    foreach my $client (Slim::Player::Client::clients()) {
        _stop_progress_timer($client);
    }
    %wheel_snapshots = ();
    %wheel_delivered_snapshots = ();
}

# Player event handler
sub playerEventCallback {
    my $request = shift;
    my $client  = $request->client() || return;

    # Respond to LMS player events relevant to Yandex Music.
    # This includes radio feedback and volume
    # synchronization between the local player and Yandex.
    my $cmd0    = $request->getRequest(0) || '';
    my $command = $request->getRequest(1) || '';

    # Handle power events directly
    if ($cmd0 eq 'power' || $command eq 'power') {
        if (!$client->power() || (defined $request->getRequest(1) && $request->getRequest(1) eq '0')) {
            _handle_pause_or_stop($client);
            $client->pluginData('yandex_curr_track_id', undef);
            _stop_progress_timer($client);
        }
    }

    if ($command eq 'client') {
        my $sub_command = $request->getRequest(2);
        if ($sub_command eq 'disconnect' || $sub_command eq 'forget') {
            _handle_pause_or_stop($client);
            $client->pluginData('yandex_curr_track_id', undef);
            _stop_progress_timer($client);
        }
    }

    if ($client->isSynced()) {
        return unless Slim::Player::Sync::isMaster($client);
    }

    if ($command eq 'newsong') {
        _handleRotorFeedback($client, 'natural_finish');
        _handleTrackSwitch($client);

        my $song = $client->playingSong();
        if ($song && $song->track() && $song->track()->url() =~ /rotor_(station|session)=/) {
            $client->pluginData('yandex_radio_url', $song->track()->url());
            $client->pluginData('yandex_track_duration', $song->duration() || 0);
            $client->pluginData('yandex_track_start_time', time());
            $client->pluginData('yandex_track_active', 1);
            _handleRotorFeedback($client, 'trackStarted');
        } else {
            $client->pluginData('yandex_track_active', 0);
        }
    }
    elsif ($command eq 'jump' || $command eq 'stop' || $cmd0 eq 'stop' || $command eq 'clear' || $cmd0 eq 'clear') {
        _handleRotorFeedback($client, 'manual_skip_or_stop');
        _handle_pause_or_stop($client);
        $client->pluginData('yandex_curr_track_id', undef);
        _stop_progress_timer($client);
    }
    elsif ($command eq 'pause' || $cmd0 eq 'pause' || $command eq 'play' || $cmd0 eq 'play') {
        if ($client->isPaused()) {
            _handle_pause_or_stop($client);
        } elsif ($client->isPlaying() && $client->pluginData('yandex_curr_track_id')) {
            _start_progress_timer($client);
        }
    }

}

sub _handleRotorFeedback {
    my ($client, $action) = @_;

    # Translate LMS playback events into Yandex rotor session feedback.
    # This helps Yandex improve personalization and keeps radio sessions aligned
    # with the actual user behavior.
    my $yandex_client = getAPIForClient($client);
    return unless $yandex_client;

    if ($action eq 'trackStarted') {
        my $song = $client->playingSong();
        return unless $song;
        my $url = $song->track()->url;

        if ($url && $url =~ /rotor_session=([^&]+)/) {
            my $radio_session_id = URI::Escape::uri_unescape($1);
            my $batch_id = ($url =~ /batch_id=([^&]+)/) ? URI::Escape::uri_unescape($1) : undef;
            my $track_id = ($url =~ /yandexmusic:\/\/(?:track\/)?(\d+)/)[0];

            return unless $track_id;

            require Plugins::yandex::ProtocolHandler;
            my $timestamp = Plugins::yandex::ProtocolHandler::_get_current_timestamp();

            $log->info("YANDEX NEW ROTOR SESSION: Track started. batch: " . ($batch_id||'none') . ", track: $track_id");
            $yandex_client->rotor_session_feedback($radio_session_id, $batch_id, 'trackStarted', $track_id, 0, $timestamp, sub {}, sub {});
        }
    }
    elsif ($action eq 'natural_finish' || $action eq 'manual_skip_or_stop') {
        my $active = $client->pluginData('yandex_track_active');
        return unless $active;

        my $url      = $client->pluginData('yandex_radio_url');
        my $duration = $client->pluginData('yandex_track_duration') || 0;

        if ($url && $url =~ /rotor_session=([^&]+)/) {
            my $station_or_session_id = URI::Escape::uri_unescape($1);
            my $batch_id = ($url =~ /batch_id=([^&]+)/) ? URI::Escape::uri_unescape($1) : undef;
            my $track_id = ($url =~ /yandexmusic:\/\/(?:track\/)?(\d+)/)[0];
            return unless $track_id;

            my $type;
            my $played_seconds = 0;

            if ($action eq 'natural_finish') {
                $type = 'trackFinished';
                $played_seconds = $duration;
            } else {
                $played_seconds = Slim::Player::Source::songTime($client) || 0;

                if (!$played_seconds) {
                    my $start_time = $client->pluginData('yandex_track_start_time');
                    if ($start_time) {
                        $played_seconds = time() - $start_time;
                    }
                }

                my $threshold = $duration > 0 ? $duration * 0.9 : 0;

                if (($duration > 0 && $played_seconds < $threshold) || ($duration == 0 && $played_seconds > 2)) {
                    $type = 'skip';
                } else {
                    $type = 'trackFinished';
                }
            }

            if ($type eq 'skip' && $played_seconds < 2) {
                $client->pluginData('yandex_track_active', 0);
                return;
            }

            require Plugins::yandex::ProtocolHandler;
            my $timestamp = Plugins::yandex::ProtocolHandler::_get_current_timestamp();
            $log->info("YANDEX ROTOR SESSION: Sending '$type' feedback. Played: $played_seconds s. batch: " . ($batch_id||'none') . ", track: $track_id");
            $yandex_client->rotor_session_feedback($station_or_session_id, $batch_id, $type, $track_id, $played_seconds, $timestamp, sub {}, sub {});

            $client->pluginData('yandex_track_active', 0);
        }
    }
}

# --- Audiobooks/Podcasts Progress & Music Play Reporting ---

sub _handleTrackSwitch {
    my $client = shift;

    # 1. Process previous track finish
    my $prev_track_id   = $client->pluginData('yandex_curr_track_id');
    my $prev_album_id   = $client->pluginData('yandex_curr_album_id');
    my $prev_is_chapter = $client->pluginData('yandex_curr_is_chapter');
    my $prev_dur        = $client->pluginData('yandex_curr_duration') || 0;
    my $prev_start_time = $client->pluginData('yandex_curr_start_time') || 0;
    my $prev_play_sent  = $client->pluginData('yandex_curr_play_sent') || 0;

    if ($prev_track_id) {
        if ($prev_is_chapter) {
            # Chapter completed naturally
            _mark_chapter_finished($client, $prev_track_id);
            _save_current_progress($client, $prev_track_id, $prev_dur, $prev_dur, 1);
        } else {
            # Music track
            my $played_seconds = $prev_dur > 0 ? $prev_dur : (time() - $prev_start_time);
            if ($played_seconds >= 30 && !$prev_play_sent) {
                _send_music_play($client, $prev_track_id, $prev_album_id, $played_seconds, $prev_dur);
            }
        }
    }

    # 2. Inspect new playing song
    my $song = $client->playingSong();
    if ($song && $song->track() && $song->track()->url() =~ /^yandexmusic:\/\/(?:track\/)?(\d+)/) {
        my $new_track_id = $1;
        my $url = $song->track()->url();
        my $new_album_id;
        if ($url =~ /[?&]album_id=(\d+)/) {
            $new_album_id = $1;
        }
        my $cache = Slim::Utils::Cache->new();
        my $meta = $cache->get('yandex_meta_' . $new_track_id);
        if ($meta) {
            $new_album_id ||= $meta->{album_id};
        }
        my $is_chapter = 0;
        if (($meta && $meta->{is_podcast}) || ($meta && $meta->{album_type} && $meta->{album_type} =~ /podcast|audiobook/i) || ($url =~ /podcast|audiobook/i)) {
            $is_chapter = 1;
        }
        my $duration = ($meta && $meta->{duration}) || $song->duration() || 0;

        $client->pluginData('yandex_curr_track_id', $new_track_id);
        $client->pluginData('yandex_curr_album_id', $new_album_id);
        $client->pluginData('yandex_curr_is_chapter', $is_chapter);
        $client->pluginData('yandex_curr_duration', $duration);
        $client->pluginData('yandex_curr_start_time', time());
        $client->pluginData('yandex_curr_play_sent', 0);

        _start_progress_timer($client);
    } else {
        $client->pluginData('yandex_curr_track_id', undef);
        _stop_progress_timer($client);
    }
}

sub _handle_pause_or_stop {
    my $client = shift;
    my $track_id   = $client->pluginData('yandex_curr_track_id') or return;
    my $album_id   = $client->pluginData('yandex_curr_album_id');
    my $is_chapter = $client->pluginData('yandex_curr_is_chapter');
    my $dur        = $client->pluginData('yandex_curr_duration') || 0;
    my $pos        = Slim::Player::Source::songTime($client) || 0;

    if ($is_chapter) {
        _save_current_progress($client, $track_id, $pos, $dur, 0);
    } else {
        if ($pos >= 30 && !$client->pluginData('yandex_curr_play_sent')) {
            $client->pluginData('yandex_curr_play_sent', 1);
            _send_music_play($client, $track_id, $album_id, $pos, $dur);
        }
    }
    _stop_progress_timer($client);
}

sub _progress_timer_tick {
    my $client = shift;
    return unless $client && $client->isPlaying();

    my $track_id   = $client->pluginData('yandex_curr_track_id');
    return unless $track_id;

    my $album_id   = $client->pluginData('yandex_curr_album_id');
    my $is_chapter = $client->pluginData('yandex_curr_is_chapter');
    my $dur        = $client->pluginData('yandex_curr_duration') || 0;
    my $pos        = Slim::Player::Source::songTime($client) || 0;

    if ($is_chapter) {
        _save_current_progress($client, $track_id, $pos, $dur, 0);
    } else {
        if ($pos >= 30 && !$client->pluginData('yandex_curr_play_sent')) {
            $client->pluginData('yandex_curr_play_sent', 1);
            _send_music_play($client, $track_id, $album_id, $pos, $dur);
        }
    }

    my $interval = $prefs->get('progress_save_interval') || 30;
    Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + $interval, \&_progress_timer_tick);
}

sub _start_progress_timer {
    my $client = shift;
    _stop_progress_timer($client);
    my $interval = $prefs->get('progress_save_interval') || 30;
    Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + $interval, \&_progress_timer_tick);
}

sub _stop_progress_timer {
    my $client = shift;
    Slim::Utils::Timers::killTimers($client, \&_progress_timer_tick);
}

sub _save_current_progress {
    my ($client, $track_id, $pos, $dur, $finished) = @_;
    return unless $track_id;

    my $api = getAPIForClient($client);
    return unless $api;

    $api->save_stream_progress(
        $track_id,
        $pos,
        $dur,
        $finished,
        sub {
            $log->debug("YANDEX: Saved progress for track $track_id: pos=$pos, dur=$dur, finished=$finished");
        },
        sub {
            my $err = shift;
            $log->warn("YANDEX: Failed to save progress for track $track_id: $err");
        }
    );
}

sub _mark_chapter_finished {
    my ($client, $track_id) = @_;
    return unless $track_id;

    my $api = getAPIForClient($client);
    return unless $api;

    $api->mark_stream_finished(
        $track_id,
        sub {
            $log->info("YANDEX: Marked track $track_id finished");
        },
        sub {
            my $err = shift;
            $log->warn("YANDEX: Failed to mark track $track_id finished: $err");
        }
    );
}

sub _send_music_play {
    my ($client, $track_id, $album_id, $played_sec, $dur) = @_;
    return unless $track_id;

    my $api = getAPIForClient($client);
    return unless $api;

    my $tid = $track_id;
    if ($album_id && $tid !~ /:/) {
        $tid = "$track_id:$album_id";
    }

    my $play_obj = {
        trackId            => $tid,
        totalPlayedSeconds => int($played_sec || 0),
        trackLengthSeconds => int($dur || 0),
        endPositionSeconds => int($played_sec || 0),
        timestamp          => Plugins::yandex::API::Common::get_iso_timestamp(),
    };
    $play_obj->{albumId} = int($album_id) if $album_id;

    $log->info("YANDEX: Reporting music play >= 30s for track $tid (played " . int($played_sec) . "s)");
    $api->send_play(
        $play_obj,
        sub {
            $log->info("YANDEX: Music play reported successfully for track $tid");
        },
        sub {
            my $err = shift;
            $log->warn("YANDEX: Failed to report music play for track $tid: $err");
        }
    );
}

sub getDisplayName { 'Yandex Music' }

sub handleFeed {
    my ($client, $cb, $args) = @_;

    # Build the root Yandex menu for the player, ensuring that an API client
    # exists for the current account before delegating to the browse renderer.
    my $userId = _getUserIdForClient($client);
    unless ($userId) {
        $cb->([{
            name => cstring($client, 'PLUGIN_YANDEX_NO_ACCOUNTS'),
            type => 'text',
        }]);
        return;
    }

    # Use cached API client if available
    if (my $cached = $api_clients{$userId}) {
        _renderRootMenu($client, $cb, $cached);
        return;
    }

    # Try to init
    my $accounts = $prefs->get('accounts') || {};
    my $account  = $accounts->{$userId};
    unless ($account && $account->{token}) {
        $cb->([{ name => 'Error: no token for account', type => 'text' }]);
        return;
    }

    my $api = Plugins::yandex::API::Async->new($account->{token});
    $api->init(
        sub {
            $api_clients{$userId} = shift;
            _renderRootMenu($client, $cb, $api_clients{$userId});
        },
        sub {
            my $error = shift;
            $log->error("YANDEX: handleFeed init error: $error");
            $cb->([{ name => "Error: $error", type => 'text' }]);
        },
    );
}

sub _renderRootMenu {
    my ($client, $cb, $client_instance) = @_;

    my $render = sub {
        my $quick_item = shift;
        my @items;

        push @items, $quick_item if $quick_item;

        if ($prefs->get('show_chart')) {
            push @items, {
                name => cstring($client, 'PLUGIN_YANDEX_CHART'),
                type => 'link',
                url  => \&Plugins::yandex::Browse::_handleChart,
                passthrough => [$client_instance],
                image => 'plugins/yandex/html/images/focus_svg.png',
            };
        }

        if ($prefs->get('show_new_releases')) {
            push @items, {
                name => cstring($client, 'PLUGIN_YANDEX_NEW_RELEASES'),
                type => 'link',
                url  => \&Plugins::yandex::Browse::_handleNewReleases,
                passthrough => [$client_instance],
                image => 'html/images/albums.png',
            };
        }

        if ($prefs->get('show_new_playlists')) {
            push @items, {
                name => cstring($client, 'PLUGIN_YANDEX_NEW_PLAYLISTS'),
                type => 'link',
                url  => \&Plugins::yandex::Browse::_handleNewPlaylists,
                passthrough => [$client_instance],
                image => 'html/images/playlists.png',
            };
        }

        push @items, (
            {
                name => cstring($client, 'PLUGIN_YANDEX_FOR_YOU'),
                type => 'link',
                url  => \&Plugins::yandex::Browse::_handleForYou,
                passthrough => [$client_instance],
                image => 'plugins/yandex/html/images/personal_svg.png',
            },
            {
                name => cstring($client, 'PLUGIN_YANDEX_MY_COLLECTION'),
                type => 'link',
                url  => \&Plugins::yandex::Browse::_handleFavorites,
                passthrough => [$client_instance],
                image => 'plugins/yandex/html/images/favorites.png',
            },
        );

        if ($prefs->get('show_history')) {
            push @items, {
                name => cstring($client, 'PLUGIN_YANDEX_HISTORY'),
                type => 'link',
                url  => \&Plugins::yandex::Browse::_handleHistory,
                passthrough => [$client_instance],
                image => 'plugins/yandex/html/images/history_svg.png',
            };
        }

        push @items, (
            {
                name => cstring($client, 'PLUGIN_YANDEX_RADIOSTATIONS'),
                type => 'link',
                url  => \&Plugins::yandex::Browse::_handleRadioCategories,
                passthrough => [$client_instance],
                image => 'plugins/yandex/html/images/radio.png',
            },
            {
                name => cstring($client, 'PLUGIN_YANDEX_SEARCH'),
                type => 'link',
                url  => \&Plugins::yandex::Browse::_handleRecentSearches,
                passthrough => [$client_instance],
                image => 'html/images/search.png',
            },
        );

        # Account switcher — show if more than one account exists
        my $accounts = $prefs->get('accounts') || {};
        my @userIds  = grep { $_ ne 'migrating' } keys %$accounts;
        if (scalar(@userIds) > 1) {
            my $currentUserId = _getUserIdForClient($client);
            my $currentAccount = $accounts->{$currentUserId} || {};
            my $currentName = $currentAccount->{name} || $currentAccount->{login} || 'Account';

            push @items, {
                name  => cstring($client, 'PLUGIN_YANDEX_SWITCH_ACCOUNT') . ': ' . $currentName,
                type  => 'link',
                url   => \&selectAccount,
                image => 'plugins/yandex/html/images/accnts_svg.png',
            };
        }

        $cb->(\@items);
    };

    if ($prefs->get('show_resume_quick_item')) {
        $client_instance->get_bookshelf_recently_played(
            0,
            1,
            sub {
                my $res = shift;
                my @raw;
                if (ref $res eq 'ARRAY') {
                    @raw = @$res;
                } elsif (ref $res eq 'HASH') {
                    for my $k (qw(entities items books albums history)) {
                        if ($res->{$k} && ref $res->{$k} eq 'ARRAY') {
                            @raw = @{$res->{$k}};
                            last;
                        }
                    }
                }
                my $quick_item;
                if (@raw && $raw[0]) {
                    my $item = $raw[0];
                    my $album = $item->{album} // (exists $item->{volumes} || exists $item->{trackCount} ? $item : {});
                    my $album_id = $album->{id} // $item->{id} // $item->{albumId};
                    my $title = $album->{title} // $item->{title} // $item->{name};
                    if ($album_id && $title) {
                        my $cover_uri = $album->{coverUri} // $item->{coverUri} // $album->{ogImage} // $item->{ogImage};
                        my $icon = Plugins::yandex::Browse::Common::format_cover_url($cover_uri, '200x200');
                        my $is_basic = Plugins::yandex::Browse::Common::is_basic_display_client($client);
                        my $resume_token = $is_basic ? 'PLUGIN_YANDEX_QUICK_RESUME_BASIC' : 'PLUGIN_YANDEX_QUICK_RESUME';
                        my $resume_fmt = cstring($client, $resume_token);
                        if ($resume_token eq 'PLUGIN_YANDEX_QUICK_RESUME_BASIC' && $resume_fmt eq 'PLUGIN_YANDEX_QUICK_RESUME_BASIC') {
                            $resume_fmt = cstring($client, 'PLUGIN_YANDEX_QUICK_RESUME');
                        }
                        if ($is_basic) {
                            $resume_fmt =~ s/▶/>/g;
                            $title = Plugins::yandex::Browse::Common::sanitize_for_client($client, $title);
                        }
                        my $quick_label = sprintf($resume_fmt, $title);
                        $quick_item = {
                            name        => $quick_label,
                            line1       => $quick_label,
                            type        => 'action',
                            url         => \&Plugins::yandex::Browse::_handleQuickResumeBook,
                            passthrough => [$client_instance, $album_id],
                            image       => $icon,
                            nextWindow  => 'nowPlaying',
                        };
                    }
                }
                $render->($quick_item);
            },
            sub {
                $render->(undef);
            }
        );
    } else {
        $render->(undef);
    }
}

# Menu: list accounts for switching (per player)
# Shows a selectable list of configured Yandex accounts for the current
# LMS player.
sub selectAccount {
    my ($client, $cb, $args) = @_;

    my $accounts      = $prefs->get('accounts') || {};
    my $currentUserId = _getUserIdForClient($client);

    my @items;
    foreach my $userId (sort keys %$accounts) {
        next if $userId eq 'migrating';
        my $account   = $accounts->{$userId};
        my $name      = $account->{name} || $account->{login} || $userId;
        my $isCurrent = defined $currentUserId && $userId eq $currentUserId;

        push @items, {
            name        => ($isCurrent ? '> ' : '  ') . $name,
            type        => 'link',
            url         => \&_switchAccount,
            passthrough => [$client, $userId],
        };
    }

    $cb->(\@items);
}

# Action: switch current player to a different account
sub _switchAccount {
    my ($client, $cb, $args, $passed_client, $userId) = @_;

    $client = $passed_client if $passed_client;
    unless ($client) {
        $cb->([{ name => 'Error: No player context available', type => 'text' }]);
        return;
    }

    my $accounts = $prefs->get('accounts') || {};
    unless (exists $accounts->{$userId}) {
        $cb->([{ name => 'Error: account not found', type => 'text' }]);
        return;
    }

    $prefs->client($client)->set('userId', $userId);
    $log->info("YANDEX: Player " . $client->name() . " switched to userId=$userId");

    # Return to main menu
    handleFeed($client, $cb, $args);
}

# Get API client for a given LMS player
sub getAPIForClient {
    my $client = shift;
    my $userId = _getUserIdForClient($client);
    return $userId ? $api_clients{$userId} : undef;
}

# Get userId assigned to a player (fallback to first available)
sub _getUserIdForClient {
    my $client = shift;
    my $accounts = $prefs->get('accounts') || {};

    if ($client) {
        my $userId = $prefs->client($client)->get('userId');
        if ($userId && exists $accounts->{$userId}) {
            return $userId;
        }
    }

    # Fall back to first available account
    my @ids = grep { $_ ne 'migrating' } keys %$accounts;
    return $ids[0] if @ids;
    return undef;
}

# Return first available API client (backward compat for Browse/ProtocolHandler)
sub getClient {
    my $userId = _getUserIdForClient(undef);
    return $userId ? $api_clients{$userId} : undef;
}

# Vibe Wheel state, feedback, and snapshot management (per-player)
sub get_wheel_snapshot {
    my ($client, $expected_seeds_str) = @_;
    return unless $client;

    my $id = ref $client ? $client->id : $client;
    my $snap = $wheel_snapshots{$id};
    return unless $snap;

    # Invalidate if older than 10 minutes (600s)
    if (time() - ($snap->{timestamp} || 0) > 600) {
        delete $wheel_snapshots{$id};
        return;
    }

    # Invalidate if seeds do not match
    if (defined $expected_seeds_str) {
        if (($snap->{seeds_str} // '') ne $expected_seeds_str) {
            return;
        }
    }

    return $snap;
}

sub set_wheel_snapshot {
    my ($client, $snapshot) = @_;
    return unless $client && ref $snapshot eq 'HASH';

    my $id = ref $client ? $client->id : $client;
    $snapshot->{timestamp} ||= time();
    $wheel_snapshots{$id} = $snapshot;
}

sub clear_wheel_snapshot {
    my $client = shift;
    return unless $client;

    my $id = ref $client ? $client->id : $client;
    delete $wheel_snapshots{$id};
}

# The list last delivered to this client as the wheel menu level. Used to
# resolve clicked item indexes: XMLBrowser resolves the click against a fresh
# fetch of the level, which may be reordered relative to what the client
# still displays. TTL 3600s matches XMLBrowser's browse session cache.
sub get_delivered_wheel_snapshot {
    my $client = shift;
    return unless $client;

    my $id = ref $client ? $client->id : $client;
    my $snap = $wheel_delivered_snapshots{$id};
    return unless $snap;

    if (time() - ($snap->{timestamp} || 0) > 3600) {
        delete $wheel_delivered_snapshots{$id};
        return;
    }

    return $snap;
}

sub set_delivered_wheel_snapshot {
    my ($client, $menu_result) = @_;
    return unless $client && $menu_result;

    my $id = ref $client ? $client->id : $client;
    $wheel_delivered_snapshots{$id} = {
        menu_result => $menu_result,
        timestamp   => time(),
    };
}

sub clear_delivered_wheel_snapshot {
    my $client = shift;
    return unless $client;

    my $id = ref $client ? $client->id : $client;
    delete $wheel_delivered_snapshots{$id};
}

sub get_wheel_state {
    my $client = shift;
    return unless $client;

    my $wheel_id = $prefs->client($client)->get('yandex_wheel_id');
    my $seeds    = $prefs->client($client)->get('yandex_wheel_seeds') || [];

    return {
        wheel_id => $wheel_id,
        seeds    => $seeds,
    };
}

sub set_wheel_state {
    my ($client, $state) = @_;
    return unless $client && ref $state eq 'HASH';

    my $wheel_id = $state->{wheel_id} // $state->{wheelId};
    $prefs->client($client)->set('yandex_wheel_id', $wheel_id);
    if (exists $state->{seeds}) {
        $prefs->client($client)->set('yandex_wheel_seeds', $state->{seeds} || []);
    }
}

sub add_wheel_feedback {
    my ($client, $event_type, $item_id, $position) = @_;
    return unless $client && $event_type && $item_id;

    my $wheel_id = $prefs->client($client)->get('yandex_wheel_id');
    return unless $wheel_id;

    require Time::HiRes;
    my $timestamp = int(Time::HiRes::time() * 1000);

    my $feedback = {
        wheelId   => $wheel_id,
        timestamp => $timestamp,
        eventType => $event_type,
        item      => {
            type => 'WAVE',
            id   => $item_id,
        },
        position  => defined $position ? int($position) : 0,
    };

    my $feedbacks = $prefs->client($client)->get('yandex_wheel_feedbacks') || [];
    push @$feedbacks, $feedback;

    if (scalar(@$feedbacks) > 50) {
        shift @$feedbacks while scalar(@$feedbacks) > 50;
    }

    $prefs->client($client)->set('yandex_wheel_feedbacks', $feedbacks);
}

sub take_wheel_feedbacks {
    my $client = shift;
    return [] unless $client;

    my $feedbacks = $prefs->client($client)->get('yandex_wheel_feedbacks') || [];
    if (@$feedbacks) {
        $prefs->client($client)->set('yandex_wheel_feedbacks', []);
    }
    return $feedbacks;
}

sub _format_account_name {
    # Generate a friendly account label from the Yandex profile data.
    my $me = shift;
    my $login   = $me->{login}       || '';
    my $display = $me->{displayName} || '';
    my $second  = $me->{secondName}  || '';
    my $name    = $login;
    if ($display || $second) {
        my $full = $display;
        if ($second && (!$display || index($display, $second) == -1)) {
            $full .= ($full ? ' ' : '') . $second;
        }
        $name .= ($name ? ' ' : '') . "($full)";
    }
    return $name || 'Account';
}

sub _register_ffmpeg_path {
    # Search common paths for ffmpeg and register the first valid location
    # with LMS so audio transcoding and demuxing work correctly.
    my @search_dirs;

    if (main::ISWINDOWS) {
        push @search_dirs, 'C:\\ffmpeg\\bin', 'C:\\Program Files\\ffmpeg\\bin',
                           'C:\\ffmpeg', 'C:\\tools\\ffmpeg\\bin';
        push @search_dirs, split /;/, ($ENV{PATH} || '');
    } else {
        push @search_dirs, '/usr/bin', '/usr/local/bin',
                           '/opt/homebrew/bin', '/opt/local/bin';
    }

    my $ffmpeg_name = main::ISWINDOWS ? 'ffmpeg.exe' : 'ffmpeg';
    for my $dir (@search_dirs) {
        next unless $dir && -d $dir;
        if (-e "$dir/$ffmpeg_name" || -e "$dir\\$ffmpeg_name") {
            $log->info("YANDEX: Registering ffmpeg path with LMS: $dir");
            Slim::Utils::Misc::addFindBinPaths($dir);
            return;
        }
    }

    $log->warn("YANDEX: ffmpeg not found - FLAC-in-MP4 (ymf) transcoding will not work");
}

sub _globalSearchItems {
    my ($client, $query) = @_;
    return [] unless $query;

    my $yandex_client = getAPIForClient($client);
    return [] unless $yandex_client;

    return [
        {
            name        => cstring($client, 'ARTISTS'),
            url         => \&Plugins::yandex::Browse::Search::handleSearchArtists,
            passthrough => [{ query => $query }],
        },
        {
            name        => cstring($client, 'ALBUMS'),
            url         => \&Plugins::yandex::Browse::Search::handleSearchAlbums,
            passthrough => [{ query => $query }],
        },
        {
            name        => cstring($client, 'SONGS'),
            url         => \&Plugins::yandex::Browse::Search::handleSearchTracks,
            passthrough => [{ query => $query }],
        },
    ];
}

sub onlineLibraryNeedsUpdate {
	if (CAN_IMPORTER) {
		my $class = shift;
		require Plugins::yandex::Importer;
		return Plugins::yandex::Importer->needsUpdate(@_);
	}
	else {
		$log->warn('YANDEX: The library importer feature requires at least Lyrion Music Server 8.0.0');
	}
}

1;
