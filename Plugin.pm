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
# Add variable to store client instance
my $yandex_client_instance;
my %ynison_instances;


sub initPlugin {
    my $class = shift;

    $prefs->init({
        token => '',
        fullName => '',
        max_bitrate => 320,
        use_new_radio_api => 0,
        remove_duplicates => 1,
        show_chart => 0,
        show_new_releases => 0,
        show_new_playlists => 0,
        show_audiobooks_in_collection => 1,
        enable_ynison => 0,
    });

    # Handle enable_ynison preference changes
    $prefs->setChange(\&_on_enable_ynison_change, 'enable_ynison');

    # Protocol registration
    $log->error("YANDEX INIT: Registering ProtocolHandler...");
    Slim::Player::ProtocolHandlers->registerHandler('yandexmusic', 'Plugins::yandex::ProtocolHandler');

    # Subscription to player status changes (play, pause, stop, etc.)
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

    # Initialize Yandex client at startup if token is available
    my $token = $prefs->get('token');
    if ($token) {
        my $yandex_client = Plugins::yandex::API->new($token);
        $yandex_client->init(
            sub {
                $yandex_client_instance = shift;
                $log->info("YANDEX: Client initialized at startup for " . ($yandex_client_instance->{me}->{login} || 'unknown user'));

                if ($prefs->get('enable_ynison')) {
                    require Plugins::yandex::Ynison;
                    foreach my $client (Slim::Player::Client::clients()) {
                        $ynison_instances{$client->id()} = Plugins::yandex::Ynison->new($client);
                    }
                }
            },
            sub {
                my $error = shift;
                $log->error("YANDEX: Static client initialization error at startup: $error");
            },
        );
    }

    if (main::WEBUI) {
        require Plugins::yandex::Settings;
        Plugins::yandex::Settings->new();
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
        # Ynison enabled - initialize it
        if ($yandex_client_instance) {
            require Plugins::yandex::Ynison;
            foreach my $client (Slim::Player::Client::clients()) {
                next if exists $ynison_instances{$client->id()};
                $ynison_instances{$client->id()} = Plugins::yandex::Ynison->new($client);
                $log->info("YANDEX: Ynison enabled for " . $client->name());
            }
        }
    } elsif (!$new_value && $old_value) {
        # Ynison disabled - cleanup all instances
        foreach my $id (keys %ynison_instances) {
            $ynison_instances{$id}->_cleanup();
            delete $ynison_instances{$id};
            $log->info("YANDEX: Ynison disabled");
        }
    }
}

# Player event handler for sending skip feedback
sub playerEventCallback {
    my $request = shift;
    my $client  = $request->client() || return;

    my $command = $request->getRequest(1);

    # Handle client connection/disconnection for Ynison
    if ($command eq 'client') {
        my $sub_command = $request->getRequest(2);
        if ($sub_command eq 'new' || $sub_command eq 'reconnect') {
            if ($prefs->get('enable_ynison') && $yandex_client_instance) {
                require Plugins::yandex::Ynison;
                $ynison_instances{$client->id()} //= Plugins::yandex::Ynison->new($client);
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
        # 1. Did the previous track finish naturally?
        _handleRotorFeedback($client, 'natural_finish');
        
        # 2. Setup the NEW track
        my $song = $client->playingSong();
        if ($song && $song->track() && $song->track()->url() =~ /rotor_(station|session)=/) {
            $client->pluginData('yandex_radio_url', $song->track()->url());
            $client->pluginData('yandex_track_duration', $song->duration() || 0);
            $client->pluginData('yandex_track_start_time', time());
            $client->pluginData('yandex_track_active', 1);
            
            # Send trackStarted if it's radio
            _handleRotorFeedback($client, 'trackStarted');
        } else {
            $client->pluginData('yandex_track_active', 0);
        }
    }
    elsif ($command eq 'jump' || $command eq 'stop' || $command eq 'clear') {
        # User manually skipped or stopped
        _handleRotorFeedback($client, 'manual_skip_or_stop');
    }

    # Ynison state update and volume sync
    if ($prefs->get('enable_ynison')) {
        if ($ynison_instances{$client->id()}) {
            # Send volume update if volume changed and not syncing from Yandex
            if (!$ynison_instances{$client->id()}->{syncing_from_yandex}) {
                my $vol = $client->volume() || 0;
                # Don't send volume 0 (can be misinterpreted as pause/stop)
                $ynison_instances{$client->id()}->_send_volume_update($vol / 100.0) if $vol > 0;
            }
            $ynison_instances{$client->id()}->update_state();
        } else {
            # Try to initialize if not yet done (e.g. if enable_ynison was tuned on after startup)
            if ($yandex_client_instance) {
                require Plugins::yandex::Ynison;
                $ynison_instances{$client->id()} = Plugins::yandex::Ynison->new($client);
            }
        }
    }
}

sub _handleRotorFeedback {
    my ($client, $action) = @_;
    
    my $yandex_client = Plugins::yandex::Plugin->getClient();
    return unless $yandex_client;

    if ($action eq 'trackStarted') {
        my $song = $client->playingSong();
        return unless $song;
        my $url = $song->track()->url;
        
        if ($url && $url =~ /rotor_station=([^&]+)/) {
            my $station = URI::Escape::uri_unescape($1);
            my $batch_id = ($url =~ /batch_id=([^&]+)/) ? URI::Escape::uri_unescape($1) : undef;
            my $track_id = ($url =~ /yandexmusic:\/\/(?:track\/)?(\d+)/)[0];
            
            return unless $track_id;
            
            $log->info("YANDEX ROTOR: Track started. Station: $station, batch: " . ($batch_id||'none') . ", track: $track_id");
            $yandex_client->rotor_station_feedback($station, 'trackStarted', $batch_id, $track_id, 0, sub {}, sub {});
        } elsif ($url && $url =~ /rotor_session=([^&]+)/) {
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
        # Feedback for the OLD track
        my $active = $client->pluginData('yandex_track_active');
        return unless $active; # No active yandex radio track to send feedback for
        
        my $url = $client->pluginData('yandex_radio_url');
        my $duration = $client->pluginData('yandex_track_duration') || 0;
        
        if ($url && $url =~ /rotor_(station|session)=([^&]+)/) {
            my $is_session = ($1 eq 'session');
            my $station_or_session_id = URI::Escape::uri_unescape($2);
            my $batch_id = ($url =~ /batch_id=([^&]+)/) ? URI::Escape::uri_unescape($1) : undef;
            my $track_id = ($url =~ /yandexmusic:\/\/(?:track\/)?(\d+)/)[0];
            return unless $track_id;
            
            my $type;
            my $played_seconds = 0;
            
            if ($action eq 'natural_finish') {
                $type = 'trackFinished';
                # If we transition naturally, the track played its full duration
                $played_seconds = $duration; 
            } else {
                # manual_skip_or_stop -> we can still grab songTime() before LMS clears it
                $played_seconds = Slim::Player::Source::songTime($client) || 0;
                
                # FALLBACK: songTime can be 0 if LMS already cleared it on jump
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
            
            # Avoid spamming skips if less than 2 seconds were played
            if ($type eq 'skip' && $played_seconds < 2) {
                # Just mark inactive and return
                $client->pluginData('yandex_track_active', 0);
                return;
            }

            if ($is_session) {
                require Plugins::yandex::ProtocolHandler;
                my $timestamp = Plugins::yandex::ProtocolHandler::_get_current_timestamp();
                $log->info("YANDEX NEW ROTOR SESSION: Sending '$type' feedback. Played: $played_seconds s. batch: " . ($batch_id||'none') . ", track: $track_id");
                $yandex_client->rotor_session_feedback($station_or_session_id, $batch_id, $type, $track_id, $played_seconds, $timestamp, sub {}, sub {});
            } else {
                $log->info("YANDEX ROTOR: Sending '$type' feedback. Played: $played_seconds s. Station: $station_or_session_id, batch: " . ($batch_id||'none') . ", track: $track_id");
                $yandex_client->rotor_station_feedback($station_or_session_id, $type, $batch_id, $track_id, $played_seconds, sub {}, sub {});
            }
            
            # Mark feedback as sent so we don't send it again on natural_finish
            $client->pluginData('yandex_track_active', 0);
        }
    }
}

sub getDisplayName { 'Yandex Music' }

sub handleFeed {
    my ($client, $cb, $args) = @_;
    
    my $token = $prefs->get('token');
    unless ($token) {
        $log->error("Token not set. Check plugin settings.");
        $cb->([{
            name => 'Error: token not set',
            type => 'text',
        }]);
        return;
    }

    if ($yandex_client_instance && $yandex_client_instance->{token} eq $token && $yandex_client_instance->{me}) {
        _renderRootMenu($client, $cb, $yandex_client_instance);
        return;
    }

    my $yandex_client = Plugins::yandex::API->new($token);

    $yandex_client->init(
        sub {
            $yandex_client_instance = shift;
            _renderRootMenu($client, $cb, $yandex_client_instance);
        },
        sub {
            my $error = shift;
            $log->error("Initialization error: $error");
            $cb->([{
                name => "Error: $error",
                type => 'text',
            }]);
        },
    );
}

sub _renderRootMenu {
    my ($client, $cb, $client_instance) = @_;

    my @items;

    # Add Chart menu item if setting is enabled
    if ($prefs->get('show_chart')) {
        push @items, {
            name => cstring($client, 'PLUGIN_YANDEX_CHART'),
            type => 'link',
            url  => \&Plugins::yandex::Browse::_handleChart,
            passthrough => [$client_instance],
            image => 'plugins/yandex/html/images/focus.png',
        };
    }

    # Add New Releases menu item if setting is enabled
    if ($prefs->get('show_new_releases')) {
        push @items, {
            name => cstring($client, 'PLUGIN_YANDEX_NEW_RELEASES'),
            type => 'link',
            url  => \&Plugins::yandex::Browse::_handleNewReleases,
            passthrough => [$client_instance],
            image => 'html/images/albums.png',
        };
    }

    # Add New Playlists menu item if setting is enabled
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

    $cb->(\@items);
}

# method for accessing client from other modules
sub getClient {
    return $yandex_client_instance;
}

1;
