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
}

# Player event handler
sub playerEventCallback {
    my $request = shift;
    my $client  = $request->client() || return;

    # Respond to LMS player events relevant to Yandex Music.
    # This includes radio feedback and volume
    # synchronization between the local player and Yandex.
    my $command = $request->getRequest(1);

    if ($command eq 'client') {
        my $sub_command = $request->getRequest(2);
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
