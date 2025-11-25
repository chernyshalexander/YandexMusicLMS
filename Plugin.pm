package Plugins::yandex::Plugin;

# Plugin to stream audio from yandex music
#
# Released under the MIT Licence
# Written by Alexander Chernysh
# See file LICENSE for full licence details

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
# use constant HTTP_TIMEOUT => 15;
# use constant HTTP_CACHE => 1;
# use constant HTTP_EXPIRES => '1h';
use constant MIN_SEARCH_LENGTH => 3;

use warnings;
use HTML::TokeParser;
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
sub _transliterate {
    my ($text) = @_;

    my %translit_map = ('"' => 'ъ',
        'zh' => 'ж', 'kh' => 'х', 'ts' => 'ц',
        'ch' => 'ч', 'sh' => 'ш', 'shch' => 'щ',
        'ya' => 'я', 'yu' => 'ю', 'yo' => 'ё',
        'eh' => 'э', 'iy'=> 'ий', '\'' => 'ь',
        'a' => 'а', 'b' => 'б', 'v' => 'в',
        'g' => 'г', 'd' => 'д', 'e' => 'е',
        'z' => 'з', 'i' => 'и', 
        'k' => 'к', 'l' => 'л', 'm' => 'м',
        'n' => 'н', 'o' => 'о', 'p' => 'п',
        'r' => 'р', 's' => 'с', 't' => 'т',
        'u' => 'у', 'f' => 'ф', 'y' => 'ы'
    );

    $text = lc $text;

    # processing " -> ъ
    $text =~ s/"/ъ/g;

    # processing goes from the longest sequences to the shortest
    foreach my $key (sort { length($b) <=> length($a) } keys %translit_map) {
        my $value = $translit_map{$key};
        $text =~ s/\Q$key\E/$value/g;
    }

    return $text;
}


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

sub isRemote { 1 }    
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

    my $fetch;
    $fetch = sub {      


        # add menu item "Favorite tracks"
        push @$menu, {
            id      => 'favorite_tracks',
            name    => 'Favorite tracks',
            type    => 'link',
            url     => sub {
                my ($client, $cb) = @_;
                my $token = $prefs->get('token');

                unless ($token) {
                    $log->warn("Токен не задан");
                    $cb->([]);
                    return;
                }

                my $playlist = $ymClient->users_likes_tracks();

                my @items = map {
                    my $ft = $_->fetch_track($ymClient);
                    my $title = $ft->{title};
                    my $name = $ft->{artists}[0]->{name};
                    my $track_url = 'yandexmusic://' . $_->{id};
                    $log->error("YANDEX MENU: Generating item '$title' with URL: $track_url");
                    {
                        #id       => $_->{id},
                        #name     => $_->{title} . " - " . $_->{artists}[0]->{name},
                        #name     => $_->fetch_track($ymClient)->{title} . ', ' . $_->fetch_track($ymClient)->{artists}[0]->{name},
                        name => $title . ' - ' . $name,
                        type     => 'audio',
                        
                        ##url      => url => 'yandexmusic://' . $_->{id},
                       
                   
                        name     => $title . ' - ' . $name,
                        type     => 'audio',
                        
                        
                        url      => $track_url, 
                        duration => 0,
                        image    => 'plugins/yandex/html/images/foundbroadcast1_svg.png',
                        #image      => $class->getCoverUrl($track),
                    }
                } #[@$playlist[0..4]];
                splice(@$playlist, 0, 10);

                $cb->({
                    type => 'opml',
                    items => \@items,
                    name  => 'Favorite tracks',
                });
            },
            image => 'plugins/yandex/html/images/foundbroadcast1_svg.png',
        };


        $callback->({
            items  => $menu
        });
    };

    $fetch->();
}





# Always end with a 1 to make Perl happy
1;
