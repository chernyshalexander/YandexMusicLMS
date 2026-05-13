package Plugins::yandex::Browse::Collection;

# Browse handlers for discovery content: chart, new releases, new playlists,
# "For You" personal mixes, smart playlists (Deja Vu, Never Heard, etc.),
# themed mixes, and tag-based playlist collections.

use strict;
use warnings;
use utf8;

use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);

use Plugins::yandex::Browse::Common;

my $log = logger('plugin.yandex');

my %TAG_SLUG_CATEGORY = (
    "chill" => "mood", "sad" => "mood", "romantic" => "mood", "party" => "mood", "relax" => "mood", "in the mood" => "mood",
    "workout" => "activity", "focus" => "activity", "morning" => "activity", "evening" => "activity", "driving" => "activity", "background" => "activity",
    "80s" => "era", "90s" => "era", "2000s" => "era", "retro" => "era",
    "rock" => "genres", "jazz" => "genres", "classical" => "genres", "electronic" => "genres", "rnb" => "genres", "hiphop" => "genres", "top" => "genres", "newbies" => "genres",
    "winter" => "seasonal", "spring" => "seasonal", "summer" => "seasonal", "autumn" => "seasonal", "newyear" => "seasonal",
);

sub translate {
    my ($client, $str) = @_;
    my $key;
    if ($str =~ /^(mood|activity|era|genres)$/) {
        $key = 'PLUGIN_YANDEX_CAT_' . uc($str);
    } elsif ($str =~ /^(picks|mixes)$/) {
        $key = 'PLUGIN_YANDEX_' . uc($str);
    } else {
        $key = 'PLUGIN_YANDEX_TAG_' . uc($str);
        $key =~ s/\-/_/g; 
        $key =~ s/\s/_/g; 
    }
    my $translation = cstring($client, $key);
    return ($translation && $translation ne $key) ? $translation : ucfirst($str);
}

sub handleChart {
    my ($client, $cb, $args, $yandex_client) = @_;

    $yandex_client->get_chart(
        '',
        sub {
            my $tracks_short = shift;

            if (!$tracks_short || scalar(@$tracks_short) == 0) {
                Plugins::yandex::Browse::Common::renderTrackList([], $cb, cstring($client, 'PLUGIN_YANDEX_CHART'));
                return;
            }

            # Extract track IDs from chart tracks (which may have .track field)
            my @track_ids;
            foreach my $track_short (@$tracks_short) {
                my $track_data = $track_short->{track} // $track_short;
                if ($track_data->{id}) {
                    push @track_ids, $track_data->{id};
                }
            }

            if (scalar(@track_ids) == 0) {
                Plugins::yandex::Browse::Common::renderTrackList([], $cb, cstring($client, 'PLUGIN_YANDEX_CHART'));
                return;
            }

            # Fetch detailed track information
            $yandex_client->tracks(
                \@track_ids,
                sub {
                    my $tracks_detailed = shift;
                    Plugins::yandex::Browse::Common::renderTrackList($tracks_detailed, $cb, cstring($client, 'PLUGIN_YANDEX_CHART'), 'yandexmusic://chart');
                },
                sub {
                    my $error = shift;
                    $log->error("Error fetching chart tracks details: $error");
                    $cb->({ items => [{ name => "Error: $error", type => 'text' }], title => cstring($client, 'PLUGIN_YANDEX_CHART') });
                }
            );
        },
        sub {
            my $error = shift;
            $log->error("Error retrieving chart: $error");
            $cb->({ items => [{ name => "Error: $error", type => 'text' }], title => cstring($client, 'PLUGIN_YANDEX_CHART') });
        },
    );
}

sub handleNewReleases {
    my ($client, $cb, $args, $yandex_client) = @_;

    $yandex_client->get_new_releases(
        sub {
            my $album_ids = shift;

            if (!$album_ids || scalar(@$album_ids) == 0) {
                Plugins::yandex::Browse::Common::renderAlbumList($yandex_client, [], $cb, cstring($client, 'PLUGIN_YANDEX_NEW_RELEASES'));
                return;
            }

            # Fetch detailed album information
            $yandex_client->albums(
                $album_ids,
                sub {
                    my $albums_detailed = shift;
                    Plugins::yandex::Browse::Common::renderAlbumList($yandex_client, $albums_detailed, $cb, cstring($client, 'PLUGIN_YANDEX_NEW_RELEASES'));
                },
                sub {
                    my $error = shift;
                    $log->error("Error fetching new releases details: $error");
                    $cb->({ items => [{ name => "Error: $error", type => 'text' }], title => cstring($client, 'PLUGIN_YANDEX_NEW_RELEASES') });
                }
            );
        },
        sub {
            my $error = shift;
            $log->error("Error retrieving new releases: $error");
            $cb->({ items => [{ name => "Error: $error", type => 'text' }], title => cstring($client, 'PLUGIN_YANDEX_NEW_RELEASES') });
        },
    );
}

sub handleNewPlaylists {
    my ($client, $cb, $args, $yandex_client) = @_;

    $yandex_client->get_new_playlists(
        sub {
            my $playlists_data = shift;

            if (!$playlists_data || scalar(@$playlists_data) == 0) {
                Plugins::yandex::Browse::Common::renderPlaylistList($yandex_client, [], $cb, cstring($client, 'PLUGIN_YANDEX_NEW_PLAYLISTS'));
                return;
            }

            # Fetch detailed playlist information for each playlist
            my @items;
            my $pending = scalar(@$playlists_data);

            foreach my $pdata (@$playlists_data) {
                my $uid = $pdata->{uid};
                my $kind = $pdata->{kind};

                $yandex_client->get_playlist($uid, $kind, sub {
                    my $playlist = shift;
                    if ($playlist) {
                        push @items, $playlist;
                    }
                    $pending--;
                    if ($pending == 0) {
                        Plugins::yandex::Browse::Common::renderPlaylistList($yandex_client, \@items, $cb, cstring($client, 'PLUGIN_YANDEX_NEW_PLAYLISTS'));
                    }
                }, sub {
                    $log->error("Error fetching playlist: $_[0]");
                    $pending--;
                    if ($pending == 0) {
                        Plugins::yandex::Browse::Common::renderPlaylistList($yandex_client, \@items, $cb, cstring($client, 'PLUGIN_YANDEX_NEW_PLAYLISTS'));
                    }
                });
            }
        },
        sub {
            my $error = shift;
            $log->error("Error retrieving new playlists: $error");
            $cb->({ items => [{ name => "Error: $error", type => 'text' }], title => cstring($client, 'PLUGIN_YANDEX_NEW_PLAYLISTS') });
        },
    );
}

sub handleForYou {
    my ($client, $cb, $args, $yandex_client) = @_;
    my @items = (
        {
            name => cstring($client, 'PLUGIN_YANDEX_SMART_PLAYLISTS'),
            type => 'link',
            url  => \&handleSmartPlaylists,
            passthrough => [$yandex_client],
            image => 'plugins/yandex/html/images/personal.png',
        },
        {
            name => translate($client, 'picks'),
            type => 'link',
            url  => \&handlePicks,
            passthrough => [$yandex_client],
            image => 'plugins/yandex/html/images/personal.png',
        },
        {
            name => translate($client, 'mixes'),
            type => 'link',
            url  => \&handleMixes,
            passthrough => [$yandex_client],
            image => 'plugins/yandex/html/images/personal.png',
        }
    );
    $cb->({ items => \@items, title => cstring($client, 'PLUGIN_YANDEX_FOR_YOU') });
}

sub handleSmartPlaylists {
    my ($client, $cb, $args, $yandex_client) = @_;

    $yandex_client->landing_personal_playlists(
        sub {
            my $blocks = shift;
            my @items;

            foreach my $block (@$blocks) {
                if ($block->{entities}) {
                    foreach my $entity (@{$block->{entities}}) {
                        if ($entity->{data}) {
                            my $pl = $entity->{data};
                            my $uid = $pl->{owner}->{uid};
                            my $kind = $pl->{kind};
                            my $title = $pl->{title};

                            my $icon = 'plugins/yandex/html/images/personal.png';
                            if ($pl->{cover} && $pl->{cover}->{uri}) {
                                $icon = "https://" . $pl->{cover}->{uri};
                                $icon =~ s/%%/200x200/;
                            }

                            push @items, {
                                name => $title,
                                type => 'playlist',
                                url  => \&Plugins::yandex::Browse::_handlePlaylist,
                                passthrough => [$yandex_client, $uid, $kind],
                                image => $icon,
                                play => "yandexmusic://playlist/$uid/$kind",
                            };
                        }
                    }
                }
            }

            $cb->({
                items => \@items,
                title => cstring($client, 'PLUGIN_YANDEX_SMART_PLAYLISTS'),
            });
        },
        sub {
            my $error = shift;
            $cb->([{ name => "Error: $error", type => 'text' }]);
        }
    );
}

sub handlePicks {
    my ($client, $cb, $args, $yandex_client, $category) = @_;

    $yandex_client->landing_mixes(
        sub {
            my $blocks = shift;
            my @discovered_tags;
            
            foreach my $block (@$blocks) {
                if ($block->{entities}) {
                    foreach my $entity (@{$block->{entities}}) {
                        if ($entity->{type} eq 'mix-link' && $entity->{data} && $entity->{data}->{url}) {
                            my $url = $entity->{data}->{url};
                            if ($url =~ /^\/tag\/([^\/]+)\/?$/) {
                                my $slug = $1;
                                my $title = $entity->{data}->{title} || $slug;
                                push @discovered_tags, { slug => $slug, title => $title };
                            }
                        }
                    }
                }
            }

            if (!$category) {
                my %active_categories;
                foreach my $t (@discovered_tags) {
                    my $cat = $TAG_SLUG_CATEGORY{$t->{slug}} || 'mood';
                    next if $cat eq 'seasonal';
                    $active_categories{$cat} = 1;
                }

                my @items;
                for my $cat (qw(mood activity era genres)) {
                    if ($active_categories{$cat}) {
                        push @items, {
                            name => translate($client, $cat),
                            type => 'link',
                            url  => \&handlePicks,
                            passthrough => [$yandex_client, $cat],
                            image => 'plugins/yandex/html/images/personal.png',
                        }
                    }
                }
                
                if (!@items) {
                    for my $cat (qw(mood activity era genres)) {
                         push @items, {
                            name => translate($client, $cat),
                            type => 'link',
                            url  => \&handlePicks,
                            passthrough => [$yandex_client, $cat],
                            image => 'plugins/yandex/html/images/personal.png',
                         }
                    }
                }

                return $cb->({ items => \@items, title => translate($client, 'picks') });
            } 
            
            my @items;
            my %seen_slugs;
            foreach my $t (@discovered_tags) {
                my $slug = $t->{slug};
                my $cat = $TAG_SLUG_CATEGORY{$slug} || 'mood';
                if ($cat eq $category && !$seen_slugs{$slug}++) {
                    push @items, {
                        name => translate($client, $slug),
                        type => 'link',
                        url  => \&handleTagPlaylists,
                        passthrough => [$yandex_client, $slug],
                        image => 'plugins/yandex/html/images/personal.png',
                    };
                }
            }

            if (!@items) {
                foreach my $slug (keys %TAG_SLUG_CATEGORY) {
                    if ($TAG_SLUG_CATEGORY{$slug} eq $category) {
                        push @items, {
                            name => translate($client, $slug),
                            type => 'link',
                            url  => \&handleTagPlaylists,
                            passthrough => [$yandex_client, $slug],
                            image => 'plugins/yandex/html/images/personal.png',
                        };
                    }
                }
            }

            $cb->({ items => \@items, title => translate($client, $category) });
        },
        sub {
            my $error = shift;
            $cb->([{ name => "Error loading mixes: $error", type => 'text' }]);
        }
    );
}

sub handleMixes {
    my ($client, $cb, $args, $yandex_client) = @_;
    
    my @seasonal_tags = qw(winter spring summer autumn newyear);
    my @items;

    foreach my $tag (@seasonal_tags) {
        push @items, {
            name => translate($client, $tag),
            type => 'link',
            url  => \&handleTagPlaylists,
            passthrough => [$yandex_client, $tag],
            image => 'plugins/yandex/html/images/personal.png',
        };
    }

    $cb->({ items => \@items, title => translate($client, 'mixes') });
}

sub handleTagPlaylists {
    my ($client, $cb, $args, $yandex_client, $tag_id) = @_;

    $yandex_client->tags(
        $tag_id,
        sub {
            my $ids = shift;
            
            if (!@$ids) {
                return $cb->({ items => [{ name => "No playlists found for tag", type => 'text' }] });
            }

            my @playlist_uids;
            foreach my $id_obj (@$ids) {
                if ($id_obj->{uid} && $id_obj->{kind}) {
                    push @playlist_uids, $id_obj->{uid} . ":" . $id_obj->{kind};
                }
            }

            $yandex_client->playlists_list(
                \@playlist_uids,
                sub {
                    my $playlists = shift;
                    my @items;

                    foreach my $playlist (@$playlists) {
                        my $title = $playlist->{title} // 'Unknown Playlist';
                        my $owner = $playlist->{owner}->{name} // 'Unknown User';
                        
                        my $icon = 'plugins/yandex/html/images/foundbroadcast1_svg.png';
                        if ($playlist->{cover} && $playlist->{cover}->{uri}) {
                            $icon = $playlist->{cover}->{uri};
                            $icon =~ s/%%/200x200/;
                            $icon = "https://$icon";
                        } elsif ($playlist->{ogImage}) {
                            $icon = $playlist->{ogImage};
                            $icon =~ s/%%/200x200/;
                            $icon = "https://$icon";
                        }

                        push @items, {
                            name => $title . ' (' . $owner . ')',
                            type => 'playlist',
                            url => \&Plugins::yandex::Browse::_handlePlaylist,
                            passthrough => [$yandex_client, $playlist->{owner}->{uid}, $playlist->{kind}],
                            image => $icon,
                            play => 'yandexmusic://playlist/' . $playlist->{owner}->{uid} . '/' . $playlist->{kind},
                        };
                    }

                    $cb->({ items => \@items, title => translate($client, $tag_id) });
                },
                sub {
                    my $err = shift;
                    $cb->([{ name => "Error fetching playlists: $err", type => 'text' }]);
                }
            );
        },
        sub {
            my $error = shift;
            $cb->([{ name => "Error fetching tags: $error", type => 'text' }]);
        }
    );
}

1;
