package Plugins::yandex::Browse::Radio;

use strict;
use warnings;
use utf8;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);

my $log = logger('plugin.yandex');
my $prefs = preferences('plugin.yandex');

sub handleRadioCategories {
    my ($client, $cb, $args, $yandex_client) = @_;

    my @items = (
        {
            name => cstring($client, 'PLUGIN_YANDEX_MY_WAVE'),
            type => 'link',
            url  => \&handleWaveModes,
            passthrough => [$yandex_client],
            image => 'plugins/yandex/html/images/radio.png',
        },
        {
            name => cstring($client, 'PLUGIN_YANDEX_RADIO_GENRES'),
            type => 'link',
            url  => \&handleRadioCategoryList,
            passthrough => [$yandex_client, 'genre'],
            image => 'plugins/yandex/html/images/radio.png',
        },
        {
            name => cstring($client, 'PLUGIN_YANDEX_RADIO_MOODS'),
            type => 'link',
            url  => \&handleRadioCategoryList,
            passthrough => [$yandex_client, 'mood'],
            image => 'plugins/yandex/html/images/radio.png',
        },
        {
            name => cstring($client, 'PLUGIN_YANDEX_RADIO_ACTIVITIES'),
            type => 'link',
            url  => \&handleRadioCategoryList,
            passthrough => [$yandex_client, 'activity'],
            image => 'plugins/yandex/html/images/radio.png',
        },
        {
            name => cstring($client, 'PLUGIN_YANDEX_RADIO_ERAS'),
            type => 'link',
            url  => \&handleRadioCategoryList,
            passthrough => [$yandex_client, 'epoch'],
            image => 'plugins/yandex/html/images/radio.png',
        },
    );

    $cb->(\@items);
}

sub handleRadioCategoryList {
    my ($client, $cb, $args, $yandex_client, $category_type) = @_;

    $yandex_client->rotor_stations_list(
        sub {
            my $stations = shift;
            my @items;

            foreach my $item (@$stations) {
                my $st = $item->{station};
                if ($st && $st->{id} && $st->{id}->{type} eq $category_type) {
                    my $tag = $st->{id}->{tag};
                    
                    my $icon = 'plugins/yandex/html/images/radio.png';

                    my $use_new_radio = $prefs->get('use_new_radio_api');
                    my $base_url = $use_new_radio ? 'yandexmusic://rotor_session/' : 'yandexmusic://rotor/';

                    push @items, {
                        name => $st->{name},
                        type => 'audio',
                        url  => $base_url . "$category_type:$tag",
                        play => $base_url . "$category_type:$tag",
                        on_select => 'play',
                        image => $icon,
                    };
                }
            }

            @items = sort { $a->{name} cmp $b->{name} } @items;

            $cb->(\@items);
        },
        sub {
            my $error = shift;
            $log->error("Failed to fetch radio stations: $error");
            $cb->([{ name => "Error: $error", type => 'text' }]);
        }
    );
}

sub handleWaveModes {
    my ($client, $cb, $args, $yandex_client) = @_;

    my $use_new_radio = $prefs->get('use_new_radio_api');
    my $base_url = $use_new_radio ? 'yandexmusic://rotor_session/' : 'yandexmusic://rotor/';

    my @items = (
        {
            name => cstring($client, 'PLUGIN_YANDEX_MODE_DEFAULT'),
            type => 'audio',
            url  => $base_url . 'user:onyourwave',
            play => $base_url . 'user:onyourwave',
            on_select => 'play',
            image => 'plugins/yandex/html/images/radio.png',
        },
        {
            name => cstring($client, 'PLUGIN_YANDEX_MODE_DISCOVER'),
            type => 'audio',
            url  => $base_url . 'user:onyourwave?diversity=discover',
            play => $base_url . 'user:onyourwave?diversity=discover',
            on_select => 'play',
            image => 'plugins/yandex/html/images/radio.png',
        },
        {
            name => cstring($client, 'PLUGIN_YANDEX_MODE_FAVORITE'),
            type => 'audio',
            url  => $base_url . 'user:onyourwave?diversity=favorite',
            play => $base_url . 'user:onyourwave?diversity=favorite',
            on_select => 'play',
            image => 'plugins/yandex/html/images/radio.png',
        },
        {
            name => cstring($client, 'PLUGIN_YANDEX_MODE_POPULAR'),
            type => 'audio',
            url  => $base_url . 'user:onyourwave?diversity=popular',
            play => $base_url . 'user:onyourwave?diversity=popular',
            on_select => 'play',
            image => 'plugins/yandex/html/images/radio.png',
        },
        {
            name => cstring($client, 'PLUGIN_YANDEX_MODE_CALM'),
            type => 'audio',
            url  => $base_url . 'user:onyourwave?moodEnergy=calm',
            play => $base_url . 'user:onyourwave?moodEnergy=calm',
            on_select => 'play',
            image => 'plugins/yandex/html/images/radio.png',
        },
        {
            name => cstring($client, 'PLUGIN_YANDEX_MODE_ACTIVE'),
            type => 'audio',
            url  => $base_url . 'user:onyourwave?moodEnergy=active',
            play => $base_url . 'user:onyourwave?moodEnergy=active',
            on_select => 'play',
            image => 'plugins/yandex/html/images/radio.png',
        },
        {
            name => cstring($client, 'PLUGIN_YANDEX_MODE_FUN'),
            type => 'audio',
            url  => $base_url . 'user:onyourwave?moodEnergy=fun',
            play => $base_url . 'user:onyourwave?moodEnergy=fun',
            on_select => 'play',
            image => 'plugins/yandex/html/images/radio.png',
        },
        {
            name => cstring($client, 'PLUGIN_YANDEX_MODE_SAD'),
            type => 'audio',
            url  => $base_url . 'user:onyourwave?moodEnergy=sad',
            play => $base_url . 'user:onyourwave?moodEnergy=sad',
            on_select => 'play',
            image => 'plugins/yandex/html/images/radio.png',
        },
    );

    $cb->({
        items => \@items,
        title => cstring($client, 'PLUGIN_YANDEX_MY_WAVE'),
    });
}

1;
