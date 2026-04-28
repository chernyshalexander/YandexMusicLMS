package Plugins::yandex::Browse::Radio;

# Browse handlers for Yandex Radio (rotor): station categories, station lists,
# and the "My Wave" wizard. Selecting a station produces a
# yandexmusic://rotor_session/{id}?... URL that explodePlaylist() in
# ProtocolHandler turns into an infinite stream of track URLs.

use strict;
use warnings;
use utf8;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);
use URI::Escape qw(uri_escape_utf8);

my $log = logger('plugin.yandex');
my $prefs = preferences('plugin.yandex');

# ---------------------------------------------------------------------------
# Wizard step constants (filter steps only — station step is separate)
# ---------------------------------------------------------------------------
my @FILTER_STEPS = ('diversity', 'mood', 'language');
my %FILTER_PREFS = (
    diversity => 'wizard_cat_diversity',
    mood      => 'wizard_cat_mood',
    language  => 'wizard_cat_language',
);

# ---------------------------------------------------------------------------
# Radio menu
# ---------------------------------------------------------------------------

sub handleRadioCategories {
    my ($client, $cb, $args, $yandex_client) = @_;

    my @items;

    # Wave Wizard — shown only if enabled in settings
    my $show_wizard = $prefs->get('show_wave_wizard') // 1;
    if ($show_wizard) {
        push @items, {
            name => cstring($client, 'PLUGIN_YANDEX_WAVE_WIZARD'),
            type => 'link',
            url  => \&handleWaveWizard,
            passthrough => [$yandex_client],
            image => 'plugins/yandex/html/images/settings.png',
        };
    }

    # My Vibe Wheel — personalized AI-picked waves from wheel/new API
    push @items, {
        name => cstring($client, 'PLUGIN_YANDEX_MY_VIBE_WHEEL'),
        type => 'link',
        url  => \&handleVibeWheel,
        passthrough => [$yandex_client],
        image => 'plugins/yandex/html/images/radio.png',
    };

    # My Presets — always shown if any presets saved (regardless of show_wizard)
    my $presets = $prefs->get('yandex_wave_presets') || [];
    if (@$presets) {
        push @items, {
            name => cstring($client, 'PLUGIN_YANDEX_MY_PRESETS'),
            type => 'link',
            url  => \&handlePresets,
            passthrough => [$yandex_client],
            image => 'plugins/yandex/html/images/radio.png',
        };
    }

    push @items, (
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

sub handleVibeWheel {
    my ($client, $cb, $args, $yandex_client) = @_;

    $yandex_client->wheel_new(
        sub {
            my $wheel = shift;
            my (@reshuffles, @waves);

            foreach my $item (@{ $wheel->{items} }) {
                next unless $item->{type} && $item->{type} eq 'WAVE';

                my $wave  = $item->{data}{wave}  // {};
                my $agent = $item->{data}{agent} // {};
                my $seeds = $wave->{seeds} // [];
                next unless @$seeds;

                my $is_reshuffle = ($item->{style} // '') eq 'CONTROL_ACCENT';
                my $name = $is_reshuffle
                    ? cstring($client, 'PLUGIN_YANDEX_VIBE_RESHUFFLE')
                    : ($wave->{name} || $item->{id});

                my $cover = '';
                if ($agent->{cover} && $agent->{cover}{uri}) {
                    my $uri = $agent->{cover}{uri};
                    if ($uri =~ s/%%$/300x300/) {
                        $uri = 'https:' . $uri if $uri =~ /^\/\//;
                        $cover = $uri;
                    }
                }

                my $seeds_param = uri_escape_utf8(join(',', @$seeds));
                my $url = "yandexmusic://rotor_session/_vibe_?seeds=$seeds_param";
                my $entry = {
                    name      => $name,
                    type      => 'audio',
                    url       => $url,
                    play      => $url,
                    on_select => 'play',
                    image     => $cover || 'plugins/yandex/html/images/radio.png',
                };

                if ($is_reshuffle) {
                    push @reshuffles, $entry;
                } else {
                    push @waves, $entry;
                }
            }

            $cb->({
                items => \@waves,
                title => cstring($client, 'PLUGIN_YANDEX_MY_VIBE_WHEEL'),
            });
        },
        sub {
            my $error = shift;
            $log->error("Vibe Wheel: Failed to fetch: $error");
            $cb->([{ name => "Error: $error", type => 'text' }]);
        }
    );
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
                    my $station_url = 'yandexmusic://rotor_session/' . "$category_type:$tag";

                    push @items, {
                        name => $st->{name},
                        type => 'audio',
                        url  => $station_url,
                        play => $station_url,
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

    my $base_url = 'yandexmusic://rotor_session/';

    $yandex_client->wheel_new(
        sub {
            my $wheel = shift;
            my $reshuffle_url;

            foreach my $item (@{ $wheel->{items} }) {
                next unless $item->{type} && $item->{type} eq 'WAVE';
                if (($item->{style} // '') eq 'CONTROL_ACCENT') {
                    my $seeds = $item->{data}{wave}{seeds} // [];
                    if (@$seeds) {
                        my $seeds_param = uri_escape_utf8(join(',', @$seeds));
                        $reshuffle_url = "yandexmusic://rotor_session/_vibe_?seeds=$seeds_param";
                        last;
                    }
                }
            }

            $reshuffle_url //= $base_url . 'user:onyourwave?diversity=reshuffle';

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
                    name => cstring($client, 'PLUGIN_YANDEX_VIBE_RESHUFFLE'),
                    type => 'audio',
                    url  => $reshuffle_url,
                    play => $reshuffle_url,
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
                {
                    name => cstring($client, 'PLUGIN_YANDEX_MODE_LANG_RUSSIAN'),
                    type => 'audio',
                    url  => $base_url . 'user:onyourwave?language=russian',
                    play => $base_url . 'user:onyourwave?language=russian',
                    on_select => 'play',
                    image => 'plugins/yandex/html/images/radio.png',
                },
                {
                    name => cstring($client, 'PLUGIN_YANDEX_MODE_LANG_NOT_RUSSIAN'),
                    type => 'audio',
                    url  => $base_url . 'user:onyourwave?language=not-russian',
                    play => $base_url . 'user:onyourwave?language=not-russian',
                    on_select => 'play',
                    image => 'plugins/yandex/html/images/radio.png',
                },
                {
                    name => cstring($client, 'PLUGIN_YANDEX_MODE_LANG_WITHOUT_WORDS'),
                    type => 'audio',
                    url  => $base_url . 'user:onyourwave?language=without-words',
                    play => $base_url . 'user:onyourwave?language=without-words',
                    on_select => 'play',
                    image => 'plugins/yandex/html/images/radio.png',
                },
            );

            $cb->({
                items => \@items,
                title => cstring($client, 'PLUGIN_YANDEX_MY_WAVE'),
            });
        },
        sub {
            my $error = shift;
            $log->error("Failed to fetch Vibe Wheel for reshuffle: $error");
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
                    name => cstring($client, 'PLUGIN_YANDEX_VIBE_RESHUFFLE'),
                    type => 'audio',
                    url  => $base_url . 'user:onyourwave?diversity=reshuffle',
                    play => $base_url . 'user:onyourwave?diversity=reshuffle',
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
                {
                    name => cstring($client, 'PLUGIN_YANDEX_MODE_LANG_RUSSIAN'),
                    type => 'audio',
                    url  => $base_url . 'user:onyourwave?language=russian',
                    play => $base_url . 'user:onyourwave?language=russian',
                    on_select => 'play',
                    image => 'plugins/yandex/html/images/radio.png',
                },
                {
                    name => cstring($client, 'PLUGIN_YANDEX_MODE_LANG_NOT_RUSSIAN'),
                    type => 'audio',
                    url  => $base_url . 'user:onyourwave?language=not-russian',
                    play => $base_url . 'user:onyourwave?language=not-russian',
                    on_select => 'play',
                    image => 'plugins/yandex/html/images/radio.png',
                },
                {
                    name => cstring($client, 'PLUGIN_YANDEX_MODE_LANG_WITHOUT_WORDS'),
                    type => 'audio',
                    url  => $base_url . 'user:onyourwave?language=without-words',
                    play => $base_url . 'user:onyourwave?language=without-words',
                    on_select => 'play',
                    image => 'plugins/yandex/html/images/radio.png',
                },
            );
            $cb->({
                items => \@items,
                title => cstring($client, 'PLUGIN_YANDEX_MY_WAVE'),
            });
        }
    );
}

# ---------------------------------------------------------------------------
# Wave Wizard — dynamic step chain
# ---------------------------------------------------------------------------

# Returns coderef for the first wizard step based on current prefs
sub _getFirstWizardHandler {
    my $station_type = $prefs->get('wizard_station_type') // 'activity';
    if    ($station_type eq 'activity') { return \&handleWizardActivity; }
    elsif ($station_type eq 'epoch')    { return \&handleWizardEpoch; }
    elsif ($station_type eq 'genre')    { return \&handleWizardGenre; }
    # No station step — return first enabled filter step
    return _getNextWizardHandler('_station');
}

# Returns coderef for the next wizard step after $current_step.
# Station steps ('activity', 'epoch', 'genre', '_station') all map to
# the first enabled filter step. Filter steps find the next enabled one.
sub _getNextWizardHandler {
    my ($current_step) = @_;

    my %is_station_step = map { $_ => 1 } qw(activity epoch genre _station);

    # After any station step — return first enabled filter
    my $start_from_first = $is_station_step{$current_step} ? 1 : 0;

    my $found = $start_from_first;
    for my $step (@FILTER_STEPS) {
        if ($found && $prefs->get($FILTER_PREFS{$step})) {
            if    ($step eq 'diversity') { return \&handleWizardDiversity;  }
            elsif ($step eq 'mood')      { return \&handleWizardMoodEnergy; }
            elsif ($step eq 'language')  { return \&handleWizardLanguage;   }
        }
        $found = 1 if !$start_from_first && $step eq $current_step;
    }
    return \&handleWizardLaunch;
}

# Entry point — builds initial state and dispatches to first step
sub handleWaveWizard {
    my ($client, $cb, $args, $yandex_client) = @_;

    my $initial_state = {
        station         => 'user:onyourwave',
        diversity       => undef,
        moodEnergy      => undef,
        language        => undef,
        label_activity  => '',
        label_epoch     => '',
        label_genre     => '',
        label_diversity => '',
        label_mood      => '',
        label_language  => '',
    };

    my $first = _getFirstWizardHandler();
    $first->($client, $cb, $args, $yandex_client, $initial_state);
}

# Common async helper for station-type steps (activity / epoch / genre)
sub _handleWizardStationStep {
    my ($client, $cb, $args, $yandex_client, $state, $type, $label_key, $any_str) = @_;

    my $next = _getNextWizardHandler($type);

    $yandex_client->rotor_stations_list(
        sub {
            my $stations = shift;
            my @items;

            # "Any" — keep station as user:onyourwave
            push @items, {
                name => cstring($client, $any_str),
                type => 'link',
                url  => $next,
                passthrough => [$yandex_client, { %$state, $label_key => '' }],
                image => 'plugins/yandex/html/images/radio.png',
            };

            foreach my $item (@$stations) {
                my $st = $item->{station};
                next unless $st && $st->{id} && $st->{id}->{type} eq $type;
                my $tag  = $st->{id}->{tag};
                my $name = $st->{name};
                push @items, {
                    name => $name,
                    type => 'link',
                    url  => $next,
                    passthrough => [$yandex_client, { %$state, station => "$type:$tag", $label_key => $name }],
                    image => 'plugins/yandex/html/images/radio.png',
                };
            }

            $cb->({
                items => \@items,
                title => cstring($client, 'PLUGIN_YANDEX_WAVE_WIZARD'),
            });
        },
        sub {
            my $error = shift;
            $log->error("Wave Wizard: Failed to fetch stations ($type): $error");
            $cb->([{ name => "Error: $error", type => 'text' }]);
        }
    );
}

# Step: Activity
sub handleWizardActivity {
    my ($client, $cb, $args, $yandex_client, $state) = @_;
    _handleWizardStationStep($client, $cb, $args, $yandex_client, $state,
        'activity', 'label_activity', 'PLUGIN_YANDEX_WIZARD_ANY_ACTIVITY');
}

# Step: Epoch
sub handleWizardEpoch {
    my ($client, $cb, $args, $yandex_client, $state) = @_;
    _handleWizardStationStep($client, $cb, $args, $yandex_client, $state,
        'epoch', 'label_epoch', 'PLUGIN_YANDEX_WIZARD_ANY_EPOCH');
}

# Step: Genre
sub handleWizardGenre {
    my ($client, $cb, $args, $yandex_client, $state) = @_;
    _handleWizardStationStep($client, $cb, $args, $yandex_client, $state,
        'genre', 'label_genre', 'PLUGIN_YANDEX_WIZARD_ANY_GENRE');
}

# Step: Diversity (character)
sub handleWizardDiversity {
    my ($client, $cb, $args, $yandex_client, $state) = @_;

    my $next = _getNextWizardHandler('diversity');

    my @choices = (
        { value => undef,       label => cstring($client, 'PLUGIN_YANDEX_WIZARD_ANY_DIVERSITY') },
        { value => 'favorite',  label => cstring($client, 'PLUGIN_YANDEX_WIZARD_DIVERSITY_FAVORITE') },
        { value => 'discover',  label => cstring($client, 'PLUGIN_YANDEX_WIZARD_DIVERSITY_DISCOVER') },
        { value => 'popular',   label => cstring($client, 'PLUGIN_YANDEX_WIZARD_DIVERSITY_POPULAR') },
    );

    my @items = map {
        my $c = $_;
        my $new_state = { %$state,
            diversity       => $c->{value},
            label_diversity => $c->{value} ? $c->{label} : '',
        };
        {
            name => $c->{label},
            type => 'link',
            url  => $next,
            passthrough => [$yandex_client, $new_state],
            image => 'plugins/yandex/html/images/radio.png',
        }
    } @choices;

    $cb->({
        items => \@items,
        title => cstring($client, 'PLUGIN_YANDEX_WAVE_WIZARD'),
    });
}

# Step: Mood/Energy
sub handleWizardMoodEnergy {
    my ($client, $cb, $args, $yandex_client, $state) = @_;

    my $next = _getNextWizardHandler('mood');

    my @choices = (
        { value => undef,    label => cstring($client, 'PLUGIN_YANDEX_WIZARD_ANY_MOOD') },
        { value => 'calm',   label => cstring($client, 'PLUGIN_YANDEX_WIZARD_MOOD_CALM') },
        { value => 'active', label => cstring($client, 'PLUGIN_YANDEX_WIZARD_MOOD_ACTIVE') },
        { value => 'fun',    label => cstring($client, 'PLUGIN_YANDEX_WIZARD_MOOD_FUN') },
        { value => 'sad',    label => cstring($client, 'PLUGIN_YANDEX_WIZARD_MOOD_SAD') },
    );

    my @items = map {
        my $c = $_;
        my $new_state = { %$state,
            moodEnergy => $c->{value},
            label_mood => $c->{value} ? $c->{label} : '',
        };
        {
            name => $c->{label},
            type => 'link',
            url  => $next,
            passthrough => [$yandex_client, $new_state],
            image => 'plugins/yandex/html/images/radio.png',
        }
    } @choices;

    $cb->({
        items => \@items,
        title => cstring($client, 'PLUGIN_YANDEX_WAVE_WIZARD'),
    });
}

# Step: Language
sub handleWizardLanguage {
    my ($client, $cb, $args, $yandex_client, $state) = @_;

    my $next = _getNextWizardHandler('language');

    my @choices = (
        { value => undef,           label => cstring($client, 'PLUGIN_YANDEX_WIZARD_ANY_LANGUAGE') },
        { value => 'russian',       label => cstring($client, 'PLUGIN_YANDEX_MODE_LANG_RUSSIAN') },
        { value => 'not-russian',   label => cstring($client, 'PLUGIN_YANDEX_MODE_LANG_NOT_RUSSIAN') },
        { value => 'without-words', label => cstring($client, 'PLUGIN_YANDEX_MODE_LANG_WITHOUT_WORDS') },
    );

    my @items = map {
        my $c = $_;
        my $new_state = { %$state,
            language       => $c->{value},
            label_language => $c->{value} ? $c->{label} : '',
        };
        {
            name => $c->{label},
            type => 'link',
            url  => $next,
            passthrough => [$yandex_client, $new_state],
            image => 'plugins/yandex/html/images/radio.png',
        }
    } @choices;

    $cb->({
        items => \@items,
        title => cstring($client, 'PLUGIN_YANDEX_WAVE_WIZARD'),
    });
}

# Final step: Play or Save
sub handleWizardLaunch {
    my ($client, $cb, $args, $yandex_client, $state) = @_;

    my $name = _buildWizardName($client, $state);
    my $url  = _buildWizardUrl($state);

    my @items = (
        {
            name      => cstring($client, 'PLUGIN_YANDEX_WIZARD_PLAY') . ': ' . $name,
            type      => 'audio',
            url       => $url,
            play      => $url,
            on_select => 'play',
            image     => 'plugins/yandex/html/images/radio.png',
        },
        {
            name => cstring($client, 'PLUGIN_YANDEX_WIZARD_SAVE'),
            type => 'link',
            url  => \&handleWizardSavePreset,
            passthrough => [$yandex_client, $state],
            image => 'plugins/yandex/html/images/radio.png',
        },
    );

    $cb->({
        items => \@items,
        title => $name,
    });
}

# Save preset and return play item
sub handleWizardSavePreset {
    my ($client, $cb, $args, $yandex_client, $state) = @_;

    my $name = _buildWizardName($client, $state);
    my $url  = _buildWizardUrl($state);

    my $new_preset = {
        name       => $name,
        station    => $state->{station},
        diversity  => $state->{diversity},
        moodEnergy => $state->{moodEnergy},
        language   => $state->{language},
    };

    my $presets = $prefs->get('yandex_wave_presets') || [];
    unshift @$presets, $new_preset;
    $presets = [ @{$presets}[0..9] ] if scalar @$presets > 10;
    $prefs->set('yandex_wave_presets', $presets);

    $log->info("Wave Wizard: Saved preset '$name'");

    $cb->({
        items => [{
            name      => cstring($client, 'PLUGIN_YANDEX_WIZARD_SAVED') . ': ' . $name,
            type      => 'audio',
            url       => $url,
            play      => $url,
            on_select => 'play',
            image     => 'plugins/yandex/html/images/radio.png',
        }],
        title => $name,
    });
}

# ---------------------------------------------------------------------------
# Presets
# ---------------------------------------------------------------------------

sub handlePresets {
    my ($client, $cb, $args, $yandex_client) = @_;

    my $presets = $prefs->get('yandex_wave_presets') || [];

    my @items;
    my $index = 0;
    for my $preset (@$presets) {
        my $i = $index++;
        push @items, {
            name => $preset->{name},
            type => 'link',
            url  => \&handlePresetItem,
            passthrough => [$yandex_client, $i],
            image => 'plugins/yandex/html/images/radio.png',
        };
    }

    push @items, {
        name => cstring($client, 'PLUGIN_YANDEX_PRESETS_CLEAR'),
        type => 'link',
        url  => \&handleClearPresets,
        passthrough => [$yandex_client],
        image => 'plugins/yandex/html/images/radio.png',
    };

    $cb->({
        items => \@items,
        title => cstring($client, 'PLUGIN_YANDEX_MY_PRESETS'),
    });
}

sub handlePresetItem {
    my ($client, $cb, $args, $yandex_client, $preset_index) = @_;

    my $presets = $prefs->get('yandex_wave_presets') || [];
    my $preset  = $presets->[$preset_index];

    unless ($preset) {
        $cb->([{ name => 'Preset not found', type => 'text' }]);
        return;
    }

    my $url = _buildWizardUrl($preset);

    $cb->({
        items => [
            {
                name      => cstring($client, 'PLUGIN_YANDEX_PRESET_PLAY'),
                type      => 'audio',
                url       => $url,
                play      => $url,
                on_select => 'play',
                image     => 'plugins/yandex/html/images/radio.png',
            },
            {
                name => cstring($client, 'PLUGIN_YANDEX_PRESET_DELETE'),
                type => 'link',
                url  => \&handleDeletePreset,
                passthrough => [$yandex_client, $preset_index],
                image => 'plugins/yandex/html/images/radio.png',
            },
        ],
        title => $preset->{name},
    });
}

sub handleDeletePreset {
    my ($client, $cb, $args, $yandex_client, $preset_index) = @_;

    my $presets = $prefs->get('yandex_wave_presets') || [];
    splice @$presets, $preset_index, 1;
    $prefs->set('yandex_wave_presets', $presets);

    $log->info("Wave Wizard: Deleted preset at index $preset_index");

    handlePresets($client, $cb, $args, $yandex_client);
}

sub handleClearPresets {
    my ($client, $cb, $args, $yandex_client) = @_;

    $prefs->set('yandex_wave_presets', []);
    $log->info("Wave Wizard: Cleared all presets");

    $cb->([{ name => cstring($client, 'PLUGIN_YANDEX_PRESETS_CLEAR'), type => 'text' }]);
}

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

sub _buildWizardName {
    my ($client, $state) = @_;
    my @parts;
    push @parts, $state->{label_activity}  if $state->{label_activity};
    push @parts, $state->{label_epoch}     if $state->{label_epoch};
    push @parts, $state->{label_genre}     if $state->{label_genre};
    push @parts, $state->{label_diversity} if $state->{label_diversity};
    push @parts, $state->{label_mood}      if $state->{label_mood};
    push @parts, $state->{label_language}  if $state->{label_language};
    return @parts ? join(' + ', @parts) : cstring($client, 'PLUGIN_YANDEX_MY_WAVE');
}

sub _buildWizardUrl {
    my ($state) = @_;
    my $base_url = 'yandexmusic://rotor_session/';

    my $url = $base_url . ($state->{station} || 'user:onyourwave');
    my @params;
    push @params, 'diversity='  . $state->{diversity}  if $state->{diversity};
    push @params, 'moodEnergy=' . $state->{moodEnergy} if $state->{moodEnergy};
    push @params, 'language='   . $state->{language}   if $state->{language};
    $url .= '?' . join('&', @params) if @params;
    return $url;
}

1;
