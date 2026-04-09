package Plugins::yandex::Plugin;

use strict;
use warnings;
use utf8;
use base qw(Slim::Plugin::OPMLBased);

use Data::Dumper;
use Encode qw(encode decode);
use Plugins::yandex::ProtocolHandler;
use Plugins::yandex::API;
use Plugins::yandex::Browse;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Player::ProtocolHandlers;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);
use URI::Escape qw(uri_escape_utf8);

my $log;
$log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.yandex',
    'defaultLevel' => 'ERROR',
    'description'  => string('PLUGIN_YANDEX'),
});

my $prefs = preferences('plugin.yandex');

# Per-userId API client instances: { $userId => API object }
my %api_clients;
# Per-player Ynison instances: { $clientId => Ynison object }
my %ynison_instances;


sub initPlugin {
    my $class = shift;

    $prefs->init({
        accounts => {},
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

    # Migrate old single-token setup to accounts hash
    _migrate_legacy_token();

    # Handle enable_ynison preference changes
    $prefs->setChange(\&_on_enable_ynison_change, 'enable_ynison');

    # Register ffmpeg path with LMS so custom-convert.conf [ffmpeg] rule can be resolved.
    _register_ffmpeg_path();

    my $deps = Plugins::yandex::API::check_dependencies();
    if (!$deps->{rijndael} || !$deps->{ffmpeg}) {
        $log->error("YANDEX: Missing critical dependencies! FLAC/AAC(MP4) playback may fail. Missing: " .
            (!$deps->{rijndael} ? 'Crypt::Rijndael ' : '') .
            (!$deps->{ffmpeg} ? 'ffmpeg' : ''));
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

    if (main::WEBUI) {
        require Plugins::yandex::Settings;
        Plugins::yandex::Settings->new();
    }
}

# Migrate old single token pref to new accounts hash
sub _migrate_legacy_token {
    my $token = $prefs->get('token');
    return unless $token;

    my $accounts = $prefs->get('accounts') || {};
    return if %$accounts;  # Already migrated

    $log->info("YANDEX: Migrating legacy token to accounts hash");
    $accounts->{'migrating'} = { token => $token, name => 'Account', login => '' };
    $prefs->set('accounts', $accounts);
}

# Initialize (or re-initialize) API client for a userId
sub _init_api_client {
    my $userId = shift;

    my $accounts = $prefs->get('accounts') || {};
    my $account  = $accounts->{$userId} || return;
    my $token    = $account->{token}    || return;

    return if exists $api_clients{$userId};  # Already initialized

    my $api = Plugins::yandex::API->new($token);
    $api->init(
        sub {
            my $client_instance = shift;
            my $me = $client_instance->get_me();
            my $realUserId = $me->{uid};

            # Rename 'migrating' to real userId
            if ($userId eq 'migrating' && $realUserId) {
                my $accounts = $prefs->get('accounts') || {};
                my $data = delete $accounts->{'migrating'};
                $data->{login} = $me->{login} || '';
                $data->{name}  = _format_account_name($me);
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
        $ynison_instances{$player->id()} = Plugins::yandex::Ynison->new($player, $token, $uid);
        $log->info("YANDEX: Ynison started for player " . $player->name() . " (userId=$userId)");
    }
}

# Remove API client and associated Ynison instances for a userId
sub _remove_api_client {
    my $userId = shift;
    delete $api_clients{$userId};

    # Cleanup Ynison for all players using this account
    foreach my $player (Slim::Player::Client::clients()) {
        my $pUserId = $prefs->client($player)->get('userId') || '';
        if ($pUserId eq $userId) {
            if (exists $ynison_instances{$player->id()}) {
                $ynison_instances{$player->id()}->_cleanup();
                delete $ynison_instances{$player->id()};
            }
            $prefs->client($player)->remove('userId');
        }
    }
}

sub shutdownPlugin {
    my $class = shift;
    Slim::Control::Request::unsubscribe(\&playerEventCallback);

    foreach my $id (keys %ynison_instances) {
        $ynison_instances{$id}->_cleanup();
    }
    %ynison_instances = ();
}

sub _on_enable_ynison_change {
    my ($pref, $new_value, $obj, $old_value) = @_;

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
            $ynison_instances{$player->id()} = Plugins::yandex::Ynison->new($player, $token, $uid);
            $log->info("YANDEX: Ynison enabled for " . $player->name());
        }
    } elsif (!$new_value && $old_value) {
        # Ynison disabled - cleanup all instances
        foreach my $id (keys %ynison_instances) {
            $ynison_instances{$id}->_cleanup();
            delete $ynison_instances{$id};
        }
        $log->info("YANDEX: Ynison disabled");
    }
}

# Player event handler
sub playerEventCallback {
    my $request = shift;
    my $client  = $request->client() || return;

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
                        $ynison_instances{$client->id()} = Plugins::yandex::Ynison->new($client, $token, $uid);
                    }
                }
            }
        }
        elsif ($sub_command eq 'disconnect' || $sub_command eq 'forget') {
            if (exists $ynison_instances{$client->id()}) {
                $ynison_instances{$client->id()}->_cleanup();
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

    # Ynison state update and volume sync
    if ($prefs->get('enable_ynison')) {
        if ($ynison_instances{$client->id()}) {
            my $ynison = $ynison_instances{$client->id()};

            if (!$ynison->{syncing_from_yandex}) {
                my $source = $request->source() // '';
                my $sub    = ($command eq 'playlist') ? ($request->getRequest(2) // '') : '';
                if (   $command eq 'jump'
                    || $command eq 'stop'
                    || $command eq 'clear'
                    || $command eq 'volume'
                    || ($command eq 'newsong' && $source ne '')
                    || ($command eq 'playlist'
                        && $sub =~ /^(?:play|load|playtracks|loadtracks|playalbum|loadalbum)$/i)
                ) {
                    $ynison->detach_from_yandex();
                }
            }

            if ($command eq 'volume' && !$ynison->{syncing_from_yandex}) {
                my $vol = $client->volume() || 0;
                $ynison->_send_volume_update($vol / 100.0) if $vol > 0;
            }
            $ynison->update_state();
        } else {
            # Try to initialize if not yet done
            my $userId = _getUserIdForClient($client);
            if ($userId && exists $api_clients{$userId}) {
                require Plugins::yandex::Ynison;
                my $accounts = $prefs->get('accounts') || {};
                my $token    = $accounts->{$userId}{token};
                my $uid      = $api_clients{$userId}->get_me()->{uid};
                if ($token && $uid) {
                    $ynison_instances{$client->id()} = Plugins::yandex::Ynison->new($client, $token, $uid);
                }
            }
        }
    }
}

sub _handleRotorFeedback {
    my ($client, $action) = @_;

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

    my $api = Plugins::yandex::API->new($account->{token});
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


1;
