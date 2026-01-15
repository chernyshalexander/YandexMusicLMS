package Plugins::yandex::Plugin;



use strict;
use utf8;
use vars qw(@ISA);
use File::Basename;
use Cwd 'abs_path';
use File::Spec;
use feature qw(fc);
use Data::Dumper;
use JSON::XS::VersionOneAndTwo;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Player::Song;
use base qw(Slim::Plugin::OPMLBased);
use URI::Escape;
use URI::Escape qw(uri_escape_utf8);
use Encode qw(encode decode);
use Encode::Guess;
use Slim::Player::ProtocolHandlers;
use Plugins::yandex::Client;
use Plugins::yandex::Request;
use Plugins::yandex::Track;
use Plugins::yandex::TrackShort;
use Plugins::yandex::Player;
use Plugins::yandex::ProtocolHandler;

use constant MIN_SEARCH_LENGTH => 3;

use warnings;

#use Encode qw(decode);



# Get the data related to this plugin and preset certain variables with 
# default values in case they are not set
my $prefs = preferences('plugin.yandex');

my $log;

our $pluginDir;

our $ymClient;

# This is the entry point in the script
BEGIN {
    $pluginDir = $INC{"Plugins/yandex/Plugin.pm"};
    $pluginDir =~ s/Plugin.pm$//; 
}
    # Initialize the logging
    $log = Slim::Utils::Log->addLogCategory({
        'category'     => 'plugin.yandex',
        'defaultLevel' => 'DEBUG',
        'description'  => string('PLUGIN_YANDEX'),
    });


#
#



# This is called when squeezebox server loads the plugin.
# It is used to initialize variables and the like.
sub initPlugin {
    my $class = shift;
    $prefs->init({ menuLocation => 'radio',
                    streamingQuality => 'highest',
                    translitSearch=>'disable',
                    token=>'*****',
                    });

    my $token = $prefs->get('token');
    $ymClient = Plugins::yandex::Client->new($token)->init();
    $log->info("YANDEX INIT: $ymClient token: $token");
    # Регистрация протокола
    $log->error("YANDEX INIT: Registering ProtocolHandler...");
    Slim::Player::ProtocolHandlers->registerHandler('yandexmusic', 'Plugins::yandex::ProtocolHandler');

    # Initialize the plugin with the given values. The 'feed' is the first
    # method called. The available menu entries will be shown in the new 
    # menu entry 'yandex'.
    $class->SUPER::initPlugin(
        feed   => \&_feedHandler,
        tag    => 'yandex',
        menu   => 'radios',
        is_app => $class->can('nonSNApps') && ($prefs->get('menuLocation') eq 'apps') ? 1 : undef, 
        weight => 10,
    );
  

    if (!$::noweb) {
        require Plugins::yandex::Settings;
        Plugins::yandex::Settings->new;
    }

}

 
# Called when the plugin is stopped
sub shutdownPlugin {
    my $class = shift;
}

# Returns the name to display on the squeezebox
sub getDisplayName {'PLUGIN_YANDEX' }

sub playerMenu { undef }

sub _feedHandler {
    my ($client, $callback, $args, $passDict) = @_;

    my $menu = [];

    my $fetch = sub {      
        # add menu item "Favorite tracks"
        push @$menu, {
            name    => 'Favorite tracks',
            type    => 'link',
            image   => 'plugins/yandex/html/images/foundbroadcast1_svg.png',
            url     => sub {
                my ($client, $cb) = @_;
                my $token = $prefs->get('token');

                unless ($token) {
                    $log->warn("Токен не задан");
                    $cb->([]);
                    return;
                }

                # 1. Получаем список лайков
                my $playlist = [];
                eval { $playlist = $ymClient->users_likes_tracks(); };
                
                if ($@) {
                    $log->error("Error fetching likes: $@");
                    $cb->([]); 
                    return;
                }

                # 2. Берем только первые 5 штук для теста (чтобы не висло)
                my @subset = splice(@$playlist, 0, 5);

                my @items = ();

                foreach my $track_obj (@subset) {
                    # Оборачиваем в eval, так как fetch_track делает сетевой запрос
                    eval {
                        # Получаем полные данные (это медленно, но для 5 штук пойдет)
                        my $ft = $track_obj->fetch_track($ymClient);
                        
                        my $title = $ft->{title} // 'Unknown';
                        my $artist = $ft->{artists}[0]->{name} // 'Unknown';
                        my $track_id = $track_obj->{id}; # ID берем из исходного объекта
                        
                        # Формируем URL вида yandexmusic://12345
                        my $track_url = 'yandexmusic://' . $track_id;

                        $log->info("Generating: $title ($track_url)");

                        push @items, {
                            name     => $artist . ' - ' . $title,
                            type     => 'audio',
                            url      => $track_url,
                            image    => 'plugins/yandex/html/images/foundbroadcast1_svg.png',
                        };
                    };
                    if ($@) {
                        $log->error("Skipping track due to error: $@");
                    }
                }

                $cb->({
                    items => \@items,
                });
            },
        };

        $callback->({ items  => $menu });
    };

    $fetch->();
}




# Always end with a 1 to make Perl happy
1;
