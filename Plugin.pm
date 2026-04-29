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

use Data::Dumper;             # TODO: unused (Dumper never called) — remove after testing
use Encode qw(encode decode); # TODO: unused (encode/decode never called) — remove after testing
use Plugins::yandex::ProtocolHandler;
use Plugins::yandex::API::Async;
use Plugins::yandex::Browse;
use Plugins::yandex::Browse::InfoMenu;
use Slim::Networking::SimpleAsyncHTTP; # TODO: unused (HTTP via API.pm) — remove after testing
use Slim::Player::ProtocolHandlers;
use Slim::Utils::Cache;       # TODO: unused (no cache ops here) — remove after testing
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Versions;
use URI::Escape qw(uri_escape_utf8); # TODO: unused (uri_escape_utf8 never called) — remove after testing

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
# Active Ynison session objects keyed by LMS player ID.
my %ynison_instances;

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
        enable_ynison => 0,
        yandex_wave_presets => [],
        show_wave_wizard     => 1,
        wizard_station_type  => 'activity',
        wizard_cat_diversity => 1,
        wizard_cat_mood      => 1,
        wizard_cat_language  => 1,
    });

    # Preserve compatibility with the old single-token preference by moving
    # that token into the new accounts structure.
    _migrate_legacy_token();

    # Keep Ynison creation/cleanup in step with the enable_ynison preference.
    $prefs->setChange(\&_on_enable_ynison_change, 'enable_ynison');

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
        my $icon_path = 'plugins/yandex/html/images/yandex.png';
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
    $log->error("YANDEX INIT: Registering ProtocolHandler...");
    Slim::Player::ProtocolHandlers->registerHandler('yandexmusic', 'Plugins::yandex::ProtocolHandler');

    # Subscription to player status changes
    Slim::Control::Request::subscribe(
        \&playerEventCallback,
        [['playlist', 'mixer', 'play', 'pause'], ['newsong', 'jump', 'stop', 'clear', 'volume', 'pause', 'client']]
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

                _maybe_init_ynison($realUserId);
            } else {
                my $accounts = $prefs->get('accounts') || {};
                if ($accounts->{$userId}) {
                    $accounts->{$userId}{uid} = $realUserId;  # Store uid for scanner access
                    $prefs->set('accounts', $accounts);
                }
                $api_clients{$userId} = $client_instance;
                $log->info("YANDEX: API client ready for userId=$userId (" . ($me->{login} || '') . ")");
                _maybe_init_ynison($userId);
            }
        },
        sub {
            my $error = shift;
            $log->error("YANDEX: API init failed for userId=$userId: $error");
        }
    );
}

# Start Ynison for all players assigned to a given userId (if enabled)
sub _maybe_init_ynison {
    my $userId = shift;
    return unless $prefs->get('enable_ynison');
    return unless exists $api_clients{$userId};

    my $accounts = $prefs->get('accounts') || {};
    my $token    = $accounts->{$userId}{token} || return;
    my $uid      = $api_clients{$userId}->get_me()->{uid} || return;

    require Plugins::yandex::Ynison;
    foreach my $player (Slim::Player::Client::clients()) {
        my $playerUserId = _getUserIdForClient($player);
        next unless defined $playerUserId && $playerUserId eq $userId;
        next if exists $ynison_instances{$player->id()};

        my $ynison = Plugins::yandex::Ynison->new($player, $token, $uid);
        $ynison_instances{$player->id()} = $ynison;

        # Register listener for incoming Yandex state updates
        $ynison->on_state(sub {
            _handle_yandex_state_update($player, @_);
        });

        # Start connection
        $ynison->connect();

        $log->info("YANDEX: Ynison started for player " . $player->name() . " (userId=$userId)");
    }
}

# Remove an account's cached API client and shut down any Ynison sessions
# that were attached to that account.
sub _remove_api_client {
    my $userId = shift;
    delete $api_clients{$userId};

    # Cleanup Ynison for all players using this account
    foreach my $player (Slim::Player::Client::clients()) {
        my $pUserId = $prefs->client($player)->get('userId') || '';
        if ($pUserId eq $userId) {
            if (exists $ynison_instances{$player->id()}) {
                $ynison_instances{$player->id()}->disconnect();
                delete $ynison_instances{$player->id()};
            }
            $prefs->client($player)->remove('userId');
        }
    }
}

sub shutdownPlugin {
    my $class = shift;

    # Unsubscribe from player events and clean up any active Ynison sessions
    # before the plugin is unloaded.
    Slim::Control::Request::unsubscribe(\&playerEventCallback);

    foreach my $id (keys %ynison_instances) {
        $ynison_instances{$id}->disconnect();
    }
    %ynison_instances = ();
}

# Handle incoming state updates from Yandex Ynison
sub _handle_yandex_state_update {
    my ($client, $state) = @_;

    return unless $client && $state;
    return if $state->{ping};

    my $ynison = $ynison_instances{$client->id()};
    return unless $ynison;

    # Volume sync is independent of everything else
    _ynison_sync_volume($client, $ynison, $state->{devices}) if $state->{devices};

    my $active_device_id = $state->{active_device_id_optional} // '';
    return unless $active_device_id eq $ynison->device_id;

    my $player_state = $state->{player_state};
    return unless $player_state;

    # Echo filter: skip our own state updates echoed back by server.
    # Only filter if paused status also matches what we last sent — otherwise
    # it's a real play/pause command from another device (e.g. phone).
    my $q_author = ($player_state->{player_queue}{version} // {})->{device_id} // '';
    if ($q_author eq $ynison->device_id) {
        my $remote_paused = (($player_state->{status} // {})->{paused} ? 1 : 0);
        my $sent_paused   = $ynison->{sent_paused};
        if (defined($sent_paused) && $sent_paused == $remote_paused) {
            $log->debug('YANDEX: Skipping own echo');
            return;
        }
        $log->info(sprintf('YANDEX: Version ours but status changed (sent=%s remote=%d) — processing',
            defined($sent_paused) ? $sent_paused : 'undef', $remote_paused));
    }

    $ynison->{syncing_from_yandex} = 1;
    eval { _apply_yandex_state($client, $ynison, $player_state) };
    $log->error("YANDEX: Error applying state: $@") if $@;
    $ynison->{syncing_from_yandex} = 0;
}

sub _apply_yandex_state {
    my ($client, $ynison, $player_state) = @_;

    my $queue  = $player_state->{player_queue} // {};
    my $status = $player_state->{status}       // {};

    my $remote_paused = $status->{paused} ? 1 : 0;
    my $remote_list   = $queue->{playable_list} // [];

    # Status-only update (play/pause with no track list)
    if (!@$remote_list) {
        _ynison_sync_play_pause($client, $remote_paused);
        $ynison->update_cached_queue($player_state);
        return;
    }

    my $remote_idx    = $queue->{current_playable_index} // 0;
    my $remote_entity = $queue->{entity_id} // '';

    return unless $remote_idx >= 0 && $remote_idx < @$remote_list;

    my $remote_track = $remote_list->[$remote_idx]{playable_id} // '';
    return unless $remote_track;

    my $lms_track = '';
    if (my $song = $client->playingSong()) {
        if (my $track = $song->track()) {
            ($lms_track) = $track->url() =~ /yandexmusic:\/\/(\d+)/;
            $lms_track //= '';
        }
    }

    my $same_queue = _ynison_is_same_queue($ynison, $remote_list, $remote_entity);

    $log->info(sprintf('YANDEX: state: same_queue=%d remote_track=%s lms_track=%s paused=%d',
        $same_queue, $remote_track, $lms_track, $remote_paused));

    if ($same_queue && $remote_track eq $lms_track) {
        _ynison_sync_play_pause($client, $remote_paused);
    } elsif ($same_queue) {
        $log->info("YANDEX: NEXT/PREV to index $remote_idx (track=$remote_track)");
        $client->execute(['playlist', 'index', $remote_idx]);
        _ynison_sync_play_pause($client, $remote_paused);
    } else {
        $log->info(sprintf('YANDEX: Cast: entity=%s tracks=%d idx=%d track=%s',
            $remote_entity || '(none)', scalar(@$remote_list), $remote_idx, $remote_track));
        _rebuild_lms_queue_from_yandex($client, $ynison, $queue, $remote_paused);
    }

    $ynison->update_cached_queue($player_state);
}

sub _ynison_sync_play_pause {
    my ($client, $remote_paused) = @_;
    my $is_playing = $client->isPlaying() ? 1 : 0;
    my $is_paused  = $client->isPaused()  ? 1 : 0;
    $log->info(sprintf('YANDEX: sync_play_pause: remote=%d lms_playing=%d lms_paused=%d',
        $remote_paused, $is_playing, $is_paused));
    if ($remote_paused && $is_playing) {
        $client->execute(['pause', 1]);
    } elsif (!$remote_paused && $is_paused) {
        $client->execute(['pause', 0]);
    } elsif (!$remote_paused && !$is_playing) {
        $client->execute(['play']);
    }
}

sub _ynison_is_same_queue {
    my ($ynison, $remote_list, $remote_entity) = @_;
    my $cached = $ynison->{yandex_queue};
    return 0 unless $cached;
    return 0 unless ($cached->{entity_id} // '') eq $remote_entity;
    my $cached_list = $cached->{playable_list} // [];
    return 0 unless @$cached_list == @$remote_list;
    for my $i (0..$#$remote_list) {
        return 0 unless ($remote_list->[$i]{playable_id} // '') eq
                        ($cached_list->[$i]{playable_id}  // '');
    }
    return 1;
}

sub _ynison_sync_volume {
    my ($client, $ynison, $devices) = @_;
    return unless ref $devices eq 'ARRAY';
    my $our_id = $ynison->device_id;
    for my $dev (@$devices) {
        next unless ($dev->{info}{device_id} // '') eq $our_id;
        my $v = ($dev->{volume_info} // {})->{volume};
        next unless defined $v;
        my $new_vol = int($v * 100 + 0.5);
        my $cur_vol = int($client->volume() || 0);
        if (abs($new_vol - $cur_vol) >= 2) {
            $ynison->{syncing_from_yandex} = 1;
            $client->execute(['mixer', 'volume', $new_vol]);
            $ynison->{syncing_from_yandex} = 0;
        }
        last;
    }
}

sub _rebuild_lms_queue_from_yandex {
    my ($client, $ynison, $queue, $start_paused) = @_;

    my @playable_list = @{$queue->{playable_list} // []};
    my $current_index = $queue->{current_playable_index} // 0;
    return unless @playable_list;

    $log->info(sprintf('YANDEX: Rebuilding queue: %d tracks idx=%d paused=%d',
        scalar(@playable_list), $current_index, $start_paused ? 1 : 0));

    $client->execute(['playlist', 'clear']);

    for my $yandex_track (@playable_list) {
        my $track_id = $yandex_track->{playable_id} or next;
        next unless ($yandex_track->{playable_type} // '') eq 'TRACK';
        $client->execute(['playlist', 'add', 'yandexmusic://' . $track_id]);
    }

    if ($current_index >= 0 && $current_index < @playable_list) {
        $client->execute(['playlist', 'index', $current_index, 'noplay', 1]) if $start_paused;
        $client->execute(['playlist', 'index', $current_index]) unless $start_paused;
    }
}

sub _on_enable_ynison_change {
    my ($pref, $new_value, $obj, $old_value) = @_;

    # React to changes in the Ynison preference, either starting Ynison
    # for existing players or tearing down active Ynison sessions.
    if ($new_value && !$old_value) {
        # Ynison enabled - initialize for all players
        require Plugins::yandex::Ynison;
        foreach my $player (Slim::Player::Client::clients()) {
            next if exists $ynison_instances{$player->id()};
            my $userId = _getUserIdForClient($player);
            next unless $userId && exists $api_clients{$userId};
            my $accounts = $prefs->get('accounts') || {};
            my $token    = $accounts->{$userId}{token} || next;
            my $uid      = $api_clients{$userId}->get_me()->{uid} || next;

            my $ynison = Plugins::yandex::Ynison->new($player, $token, $uid);
            $ynison->on_state(sub {
                _handle_yandex_state_update($player, @_);
            });
            $ynison->connect();
            $ynison_instances{$player->id()} = $ynison;

            $log->info("YANDEX: Ynison enabled for " . $player->name());
        }
    } elsif (!$new_value && $old_value) {
        # Ynison disabled - cleanup all instances
        foreach my $id (keys %ynison_instances) {
            $ynison_instances{$id}->disconnect();
            delete $ynison_instances{$id};
        }
        $log->info("YANDEX: Ynison disabled");
    }
}

# Player event handler
sub playerEventCallback {
    my $request = shift;
    my $client  = $request->client() || return;

    # Respond to LMS player events relevant to Yandex Music.
    # This includes radio feedback, Ynison lifecycle management, and volume
    # synchronization between the local player and Yandex.
    my $command = $request->getRequest(1);

    # Handle client connection/disconnection for Ynison
    if ($command eq 'client') {
        my $sub_command = $request->getRequest(2);
        if ($sub_command eq 'new' || $sub_command eq 'reconnect') {
            if ($prefs->get('enable_ynison')) {
                my $userId = _getUserIdForClient($client);
                if ($userId && exists $api_clients{$userId}) {
                    require Plugins::yandex::Ynison;
                    if (!exists $ynison_instances{$client->id()}) {
                        my $accounts = $prefs->get('accounts') || {};
                        my $token    = $accounts->{$userId}{token} || return;
                        my $uid      = $api_clients{$userId}->get_me()->{uid} || return;

                        my $ynison = Plugins::yandex::Ynison->new($client, $token, $uid);
                        $ynison->on_state(sub {
                            _handle_yandex_state_update($client, @_);
                        });
                        $ynison->connect();
                        $ynison_instances{$client->id()} = $ynison;
                    }
                }
            }
        }
        elsif ($sub_command eq 'disconnect' || $sub_command eq 'forget') {
            if (exists $ynison_instances{$client->id()}) {
                $ynison_instances{$client->id()}->disconnect();
                delete $ynison_instances{$client->id()};
            }
        }
    }

    if ($client->isSynced()) {
        return unless Slim::Player::Sync::isMaster($client);
    }

    if ($command eq 'newsong') {
        _handleRotorFeedback($client, 'natural_finish');

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
    elsif ($command eq 'jump' || $command eq 'stop' || $command eq 'clear') {
        _handleRotorFeedback($client, 'manual_skip_or_stop');
    }

    # Ynison state sync
    if ($prefs->get('enable_ynison')) {
        my $ynison = $ynison_instances{$client->id()};

        if (!$ynison) {
            # Try to initialize if not yet done
            my $userId = _getUserIdForClient($client);
            if ($userId && exists $api_clients{$userId}) {
                require Plugins::yandex::Ynison;
                my $accounts = $prefs->get('accounts') || {};
                my $token    = $accounts->{$userId}{token};
                my $uid      = $api_clients{$userId}->get_me()->{uid};
                if ($token && $uid) {
                    $ynison = Plugins::yandex::Ynison->new($client, $token, $uid);
                    $ynison->on_state(sub {
                        _handle_yandex_state_update($client, @_);
                    });
                    $ynison->connect();
                    $ynison_instances{$client->id()} = $ynison;
                }
            }
        }

        if ($ynison && !$ynison->{syncing_from_yandex}) {
            # Check if current content is Yandex Music
            my $song = $client->playingSong();
            my $is_yandex = 0;
            if ($song && $song->track()) {
                $is_yandex = 1 if $song->track()->url() =~ /^yandexmusic:\/\//;
            }

            if ($is_yandex) {
                # Scenario 4: Local Control (LMS -> Yandex)
                # We are playing Yandex Music, so we reflect local playback events to the Yandex app.
                if ($command eq 'pause' || $command eq 'play' || $command eq 'newsong') {
                    $ynison->{sent_paused} = $client->isPaused() ? 1 : 0;
                    $ynison->update_state();
                }
                elsif ($command eq 'jump') {
                    my $cmd = $ynison->build_next_cmd();
                    $ynison->send_command($cmd) if $cmd;
                }
                # Remember that we have an active Yandex session
                $client->pluginData('ynison_had_yandex_session', 1);
            } else {
                # Scenario 1 & 5: Local Content Isolation & Local Override
                # If the user switched to local content (FLAC, Spotify, etc.) and we previously 
                # had an active Yandex session, we must send an "empty" state to disconnect the app.
                if ($client->pluginData('ynison_had_yandex_session')) {
                    $log->info("YANDEX: Local override detected. Sending empty state to clear Ynison session.");
                    $ynison->{yandex_queue} = undef;  # Clear local queue cache
                    $ynison->update_state();          # Sends the empty queue to disconnect the phone
                    $client->pluginData('ynison_had_yandex_session', 0);
                }
                # If we are just playing local content normally, we do NOT send any updates to Yandex.
            }
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

    # Compose the top-level plugin menu based on enabled features and
    # user preferences for the current account.
    my @items;

    if ($prefs->get('show_chart')) {
        push @items, {
            name => cstring($client, 'PLUGIN_YANDEX_CHART'),
            type => 'link',
            url  => \&Plugins::yandex::Browse::_handleChart,
            passthrough => [$client_instance],
            image => 'plugins/yandex/html/images/focus.png',
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
            image => 'plugins/yandex/html/images/personal.png',
        },
        {
            name => cstring($client, 'PLUGIN_YANDEX_MY_COLLECTION'),
            type => 'link',
            url  => \&Plugins::yandex::Browse::_handleFavorites,
            passthrough => [$client_instance],
            image => 'plugins/yandex/html/images/favorites.png',
        },
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
            image => 'plugins/yandex/html/images/accnts.png',
        };
    }

    $cb->(\@items);
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
            passthrough => [$userId],
        };
    }

    $cb->(\@items);
}

# Action: switch current player to a different account
sub _switchAccount {
    my ($client, $cb, $args, $userId) = @_;

    my $accounts = $prefs->get('accounts') || {};
    unless (exists $accounts->{$userId}) {
        $cb->([{ name => 'Error: account not found', type => 'text' }]);
        return;
    }

    $prefs->client($client)->set('userId', $userId);
    $log->info("YANDEX: Player " . $client->name() . " switched to userId=$userId");

    # Restart Ynison for this player with new account
    if (exists $ynison_instances{$client->id()}) {
        $ynison_instances{$client->id()}->_cleanup();
        delete $ynison_instances{$client->id()};
    }

    if ($prefs->get('enable_ynison') && exists $api_clients{$userId}) {
        my $token = $accounts->{$userId}{token};
        my $uid   = $api_clients{$userId}->get_me()->{uid};
        if ($token && $uid) {
            require Plugins::yandex::Ynison;
            $ynison_instances{$client->id()} = Plugins::yandex::Ynison->new($client, $token, $uid);
        }
    }

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
