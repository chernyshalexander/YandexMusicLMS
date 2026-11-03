package Plugins::yandex::Browse::History;

=encoding utf8

=head1 NAME

Plugins::yandex::Browse::History - Browse handlers for listening history and audiobook resume

=head1 DESCRIPTION

Provides menu navigation for:
- Music listening history (grouped by date: Today, Yesterday, earlier dates)
- Audiobooks & podcasts bookshelf of recently played items
- Audiobook resume menu: continue from saved chapter and second offset,
  listen from start, chapter listing (table of contents), mark as finished.
- 1-click quick resume from the main menu.

=cut

use strict;
use warnings;
use utf8;

use Scalar::Util qw(blessed);
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);

use Plugins::yandex::Browse::Common;

my $log   = logger('plugin.yandex');
my $prefs = preferences('plugin.yandex');

sub _resolve_api_client {
    my ($client, $yandex_client, $id_ref) = @_;
    if (ref $yandex_client eq 'HASH') {
        if ($yandex_client->{get_album_with_tracks} || $yandex_client->{get_music_history} || $yandex_client->{get_bookshelf_recently_played} || $yandex_client->{mark_album_finished}) {
            return $yandex_client;
        }
        if ($id_ref && ref $id_ref eq 'SCALAR') {
            $$id_ref ||= $yandex_client->{id} || $yandex_client->{album_id};
        }
        $yandex_client = undef;
    }
    $yandex_client ||= eval { Plugins::yandex::Plugin::getAPIForClient($client) };
    return $yandex_client;
}

sub _is_audiobook_or_podcast_track {
    my $tr = shift;
    return 0 unless ref $tr eq 'HASH';

    return 1 if $tr->{is_chapter} || $tr->{is_podcast};
    return 1 if ($tr->{type} && $tr->{type} =~ /^(?:podcast|audiobook)$/i);

    if ($tr->{albums} && ref $tr->{albums} eq 'ARRAY') {
        for my $alb (@{$tr->{albums}}) {
            next unless ref $alb eq 'HASH';
            return 1 if ($alb->{type} && $alb->{type} =~ /podcast|audiobook/i);
            return 1 if ($alb->{metaType} && $alb->{metaType} =~ /podcast|audiobook/i);
            return 1 if ($alb->{genre} && $alb->{genre} =~ /audiobook/i);
        }
    }

    # Check cached track metadata if available
    my $tid = $tr->{track_id} // $tr->{id};
    if ($tid) {
        my $cache = Slim::Utils::Cache->new();
        my $meta = eval { $cache->get('yandex_meta_' . $tid) };
        if ($meta && ref $meta eq 'HASH') {
            return 1 if ($meta->{is_podcast} || ($meta->{album_type} && $meta->{album_type} =~ /podcast|audiobook/i));
        }
    }

    # Check cached album metadata if available
    my $aid = $tr->{album_id} // (($tr->{albums} && ref $tr->{albums} eq 'ARRAY' && $tr->{albums}[0]) ? $tr->{albums}[0]{id} : undef);
    if ($aid) {
        my $cache = Slim::Utils::Cache->new();
        my $alb = eval { $cache->get('yandex_album_' . $aid) };
        if ($alb && ref $alb eq 'HASH') {
            return 1 if ($alb->{type} && $alb->{type} =~ /podcast|audiobook/i);
            return 1 if ($alb->{metaType} && $alb->{metaType} =~ /podcast|audiobook/i);
            return 1 if ($alb->{genre} && $alb->{genre} =~ /audiobook/i);
        }
    }

    # Title / Album patterns for audiobooks and podcast episodes
    my $title = $tr->{title} || '';
    my $album_title = $tr->{album} || (($tr->{albums} && ref $tr->{albums} eq 'ARRAY' && $tr->{albums}[0]) ? $tr->{albums}[0]{title} : '') || '';
    if ($title =~ /(?:Часть|Глава|Выпуск|Chapter|Episode)\s+\d+/i) {
        return 1;
    }
    if ($album_title =~ /(?:аудиокнига|audiobook)/i) {
        return 1;
    }

    return 0;
}

# Root history menu: Music vs Audiobooks & Podcasts
sub handleHistory {
    my ($client, $cb, $args, $yandex_client) = @_;
    $yandex_client = _resolve_api_client($client, $yandex_client);

    my @items = (
        {
            name        => cstring($client, 'PLUGIN_YANDEX_HISTORY_MUSIC'),
            type        => 'link',
            url         => \&handleMusicHistory,
            passthrough => [$yandex_client],
            image       => 'plugins/yandex/html/images/history_svg.png',
        },
        {
            name        => cstring($client, 'PLUGIN_YANDEX_HISTORY_AUDIOBOOKS'),
            type        => 'link',
            url         => \&handleAudiobooksHistory,
            passthrough => [$yandex_client],
            image       => 'plugins/yandex/html/images/podcast_svg.png',
        },
    );

    $cb->({
        items => \@items,
        title => cstring($client, 'PLUGIN_YANDEX_HISTORY'),
    });
}

# Music history: 2-level menu (Dates -> Tracks)
sub handleMusicHistory {
    my ($client, $cb, $args, $yandex_client) = @_;
    $yandex_client = _resolve_api_client($client, $yandex_client);

    $yandex_client->get_music_history(
        50,
        sub {
            my $data = shift;
            my $tabs = (ref $data eq 'HASH') ? ($data->{historyTabs} // []) : [];

            my ($sec, $min, $hour, $mday, $mon, $year) = localtime(time);
            my $today_str = sprintf("%04d-%02d-%02d", $year + 1900, $mon + 1, $mday);
            my ($ysec, $ymin, $yhour, $ymday, $ymon, $yyear) = localtime(time - 86400);
            my $yesterday_str = sprintf("%04d-%02d-%02d", $yyear + 1900, $ymon + 1, $ymday);

            my $userId = eval { Plugins::yandex::Plugin::_getUserIdForClient($client) } || 'default';
            my $local_tracks = $prefs->get("recent_played_music_${userId}") || [];

            # Clean and sanitize recent_played_music so no audiobooks or podcasts linger in music history
            my @clean_local = grep { ref $_ eq 'HASH' && !_is_audiobook_or_podcast_track($_) } @$local_tracks;
            if (scalar(@clean_local) != scalar(@$local_tracks)) {
                $prefs->set("recent_played_music_${userId}", \@clean_local);
                $local_tracks = \@clean_local;
            }

            # Check if historyTabs already has today's tab
            my $today_tab;
            for my $t (@$tabs) {
                if (($t->{date} // '') eq $today_str) {
                    $today_tab = $t;
                    last;
                }
            }

            # Filter local tracks played today (music only)
            require Time::Local;
            my $today_midnight = eval { Time::Local::timelocal(0, 0, 0, $mday, $mon, $year) } || (time - 86400);
            my @today_local = grep { ref $_ eq 'HASH' && ($_->{timestamp} || 0) >= $today_midnight && !_is_audiobook_or_podcast_track($_) } @$local_tracks;

            if (@today_local) {
                if (!$today_tab) {
                    my @tracks_list;
                    for my $lt (@today_local) {
                        push @tracks_list, {
                            type => 'track',
                            data => {
                                fullModel => {
                                    id         => $lt->{track_id},
                                    title      => $lt->{title} || 'Track ' . $lt->{track_id},
                                    durationMs => ($lt->{duration} || 0) * 1000,
                                    coverUri   => $lt->{cover_uri},
                                    artists    => $lt->{artist} ? [{ name => $lt->{artist} }] : [],
                                    albums     => $lt->{album} ? [{ title => $lt->{album}, id => $lt->{album_id} }] : ($lt->{album_id} ? [{ id => $lt->{album_id} }] : []),
                                    timestamp  => $lt->{timestamp},
                                },
                            },
                        };
                    }
                    $today_tab = {
                        date  => $today_str,
                        title => cstring($client, 'PLUGIN_YANDEX_TODAY'),
                        items => [{
                            context => { type => 'various' },
                            tracks  => \@tracks_list,
                        }],
                    };
                    unshift @$tabs, $today_tab;
                } else {
                    my $existing_tids = {};
                    for my $grp (@{$today_tab->{items} || []}) {
                        for my $tr (@{$grp->{tracks} || []}) {
                            my $td = $tr->{data} || $tr;
                            my $fm = $td->{fullModel} || $td;
                            my $tid = $fm->{id} // (ref $td->{itemId} eq 'HASH' ? $td->{itemId}{trackId} : $td->{itemId});
                            $existing_tids->{$tid} = 1 if defined $tid;
                        }
                    }
                    my @new_local_tracks;
                    for my $lt (@today_local) {
                        next if $existing_tids->{$lt->{track_id}};
                        push @new_local_tracks, {
                            type => 'track',
                            data => {
                                fullModel => {
                                    id         => $lt->{track_id},
                                    title      => $lt->{title} || 'Track ' . $lt->{track_id},
                                    durationMs => ($lt->{duration} || 0) * 1000,
                                    coverUri   => $lt->{cover_uri},
                                    artists    => $lt->{artist} ? [{ name => $lt->{artist} }] : [],
                                    albums     => $lt->{album} ? [{ title => $lt->{album}, id => $lt->{album_id} }] : ($lt->{album_id} ? [{ id => $lt->{album_id} }] : []),
                                    timestamp  => $lt->{timestamp},
                                },
                            },
                        };
                    }
                    if (@new_local_tracks) {
                        unshift @{$today_tab->{items}}, {
                            context => { type => 'various' },
                            tracks  => \@new_local_tracks,
                        };
                    }
                }
            }

            if (!@$tabs) {
                $cb->({
                    items => [{
                        name => cstring($client, 'PLUGIN_YANDEX_NO_HISTORY'),
                        type => 'text',
                    }],
                    title => cstring($client, 'PLUGIN_YANDEX_HISTORY_MUSIC'),
                });
                return;
            }

            my @items;
            for my $tab (@$tabs) {
                my $date = $tab->{date} // '';

                my $title;
                if ($date eq $today_str) {
                    my $word = cstring($client, 'PLUGIN_YANDEX_TODAY');
                    $title = ($word && $word ne 'PLUGIN_YANDEX_TODAY') ? $word : 'Today';
                } elsif ($date eq $yesterday_str) {
                    my $word = cstring($client, 'PLUGIN_YANDEX_YESTERDAY');
                    $title = ($word && $word ne 'PLUGIN_YANDEX_YESTERDAY') ? $word : 'Yesterday';
                } elsif ($date =~ /^(\d{4})-(\d{2})-(\d{2})$/) {
                    $title = "$3.$2.$1";
                } else {
                    $title = $tab->{title} || $date;
                }

                push @items, {
                    name        => $title,
                    type        => 'link',
                    url         => \&handleMusicHistoryDayTracks,
                    passthrough => [$yandex_client, $tab],
                    image       => 'plugins/yandex/html/images/history_svg.png',
                };
            }

            $cb->({
                items => \@items,
                title => cstring($client, 'PLUGIN_YANDEX_HISTORY_MUSIC'),
            });
        },
        sub {
            my $error = shift;
            $cb->({ items => [{ name => "Error: $error", type => 'text' }] });
        }
    );
}

# Helper: Parse and create LMS browse item for history context (wave, album, artist, playlist)
sub _parse_history_context_item {
    my ($client, $yandex_client, $grp) = @_;
    return undef unless ref $grp eq 'HASH';

    my $ctx = $grp->{context};
    if (!$ctx && $grp->{type} && $grp->{type} ne 'track') {
        $ctx = $grp;
    }
    return undef unless $ctx && ref $ctx eq 'HASH';

    my $type = lc($ctx->{type} || '');
    return undef if !$type || $type eq 'various' || $type eq 'other' || $type eq 'search' || $type eq 'track';

    my $data = (ref $ctx->{data} eq 'HASH') ? $ctx->{data} : $ctx;
    my $full = (ref $data->{fullModel} eq 'HASH') ? $data->{fullModel} : $data;
    my $item_id = $data->{itemId} || $ctx->{itemId};

    if ($type eq 'wave' || $type eq 'q2v_wave') {
        my $seeds = (ref $item_id eq 'HASH' && $item_id->{seeds}) ? $item_id->{seeds} : ($data->{seeds} || []);
        my $seed = (ref $seeds eq 'ARRAY' && @$seeds) ? $seeds->[0] : '';

        my $wave_obj = (ref $full->{wave} eq 'HASH') ? $full->{wave} : $full;
        my $wave_name = (ref $wave_obj eq 'HASH') ? ($wave_obj->{title} || $wave_obj->{name}) : undef;

        my $wave_img = $full->{simpleWaveForegroundImageUrl};
        if ($wave_img) {
            $wave_img = Plugins::yandex::Browse::Common::format_cover_url($wave_img, '200x200');
        } else {
            $wave_img = 'plugins/yandex/html/images/radio.png';
        }

        if (!$wave_name) {
            if ($seed && $seed =~ /^artist:(\d+)/) {
                $wave_name = cstring($client, 'PLUGIN_YANDEX_WAVE_BY_ARTIST');
            } elsif ($seed && $seed =~ /^track:(\d+)/) {
                $wave_name = cstring($client, 'PLUGIN_YANDEX_RADIO');
            } else {
                $wave_name = cstring($client, 'PLUGIN_YANDEX_MY_WAVE');
            }
        }

        my $wave_url = $seed ? ('yandexmusic://rotor_session/' . $seed) : 'yandexmusic://rotor_session/user:onyourwave';

        my $is_basic = Plugins::yandex::Browse::Common::is_basic_display_client($client);
        my $radio_word = cstring($client, 'PLUGIN_YANDEX_RADIO') || 'Radio';
        my $radio_tag = "[$radio_word] ";
        my $line1;
        if ($is_basic) {
            $wave_name = Plugins::yandex::Browse::Common::sanitize_for_client($client, $wave_name);
            $line1 = ($wave_name =~ /^\Q[$radio_word]\E/i) ? $wave_name : ($radio_tag . $wave_name);
        } else {
            $line1 = ($wave_name =~ /^⚡/) ? $wave_name : ("⚡ " . $wave_name);
        }

        return {
            name      => $line1,
            line1     => $line1,
            line2     => cstring($client, 'PLUGIN_YANDEX_RADIO'),
            type      => 'audio',
            url       => $wave_url,
            play      => $wave_url,
            on_select => 'play',
            image     => $wave_img,
        };
    }
    elsif ($type eq 'album') {
        my $alb = (ref $full->{album} eq 'HASH') ? $full->{album} : $full;
        my $alb_id = (ref $alb eq 'HASH' && $alb->{id}) ? $alb->{id} : (ref $item_id eq 'HASH' ? $item_id->{id} : $item_id);
        return undef unless $alb_id;

        my $alb_type = (ref $alb eq 'HASH') ? ($alb->{type} || $alb->{metaType} || '') : '';
        return undef if $alb_type =~ /podcast|audiobook/i;

        my $alb_title = (ref $alb eq 'HASH' && $alb->{title}) ? $alb->{title} : 'Album';
        my $art_name = '';
        if (ref $alb eq 'HASH' && $alb->{artists} && ref $alb->{artists} eq 'ARRAY' && @{$alb->{artists}}) {
            $art_name = $alb->{artists}[0]->{name} || '';
        }

        my $cover_uri = (ref $alb eq 'HASH') ? $alb->{coverUri} : undef;
        my $cover = $cover_uri ? Plugins::yandex::Browse::Common::format_cover_url($cover_uri, '200x200') : 'html/images/albums.png';

        my $is_basic = Plugins::yandex::Browse::Common::is_basic_display_client($client);
        my $label;
        my $line1;
        my $sep = $is_basic ? " - " : " \x{2022} ";
        if ($is_basic) {
            $alb_title = Plugins::yandex::Browse::Common::sanitize_for_client($client, $alb_title);
            $art_name = Plugins::yandex::Browse::Common::sanitize_for_client($client, $art_name);
            my $alb_tag = "[" . cstring($client, 'PLUGIN_YANDEX_ALBUM') . "] ";
            $label = $alb_tag . $alb_title;
            $label .= " ($art_name)" if $art_name;
            $line1 = $alb_tag . $alb_title;
        } else {
            $label = "💿 " . cstring($client, 'PLUGIN_YANDEX_ALBUM') . ": " . $alb_title;
            $label .= " ($art_name)" if $art_name;
            $line1 = "💿 " . $alb_title;
        }

        return {
            name        => $label,
            line1       => $line1,
            line2       => $art_name ? ($art_name . $sep . cstring($client, 'PLUGIN_YANDEX_ALBUM')) : cstring($client, 'PLUGIN_YANDEX_ALBUM'),
            type        => 'playlist',
            url         => \&Plugins::yandex::Browse::_handleAlbum,
            passthrough => [$yandex_client, $alb_id],
            play        => 'yandexmusic://album/' . $alb_id,
            image       => $cover,
        };
    }
    elsif ($type eq 'artist') {
        my $art = (ref $full->{artist} eq 'HASH') ? $full->{artist} : $full;
        my $art_id = (ref $art eq 'HASH' && $art->{id}) ? $art->{id} : (ref $item_id eq 'HASH' ? $item_id->{id} : $item_id);
        return undef unless $art_id;

        my $art_name = (ref $art eq 'HASH' && $art->{name}) ? $art->{name} : 'Artist';
        my $cover_uri = (ref $art eq 'HASH') ? ($art->{cover}{uri} || $art->{coverUri}) : undef;
        my $cover = $cover_uri ? Plugins::yandex::Browse::Common::format_cover_url($cover_uri, '200x200') : 'html/images/artists.png';

        my $is_basic = Plugins::yandex::Browse::Common::is_basic_display_client($client);
        my $label;
        my $line1;
        if ($is_basic) {
            $art_name = Plugins::yandex::Browse::Common::sanitize_for_client($client, $art_name);
            my $art_tag = "[" . cstring($client, 'PLUGIN_YANDEX_ARTIST') . "] ";
            $label = $art_tag . $art_name;
            $line1 = $art_tag . $art_name;
        } else {
            $label = "👤 " . cstring($client, 'PLUGIN_YANDEX_ARTIST') . ": " . $art_name;
            $line1 = "👤 " . $art_name;
        }

        return {
            name        => $label,
            line1       => $line1,
            line2       => cstring($client, 'PLUGIN_YANDEX_ARTIST'),
            type        => 'link',
            url         => \&Plugins::yandex::Browse::_handleArtist,
            passthrough => [$yandex_client, $art_id],
            image       => $cover,
        };
    }
    elsif ($type eq 'playlist') {
        my $pl = (ref $full->{playlist} eq 'HASH') ? $full->{playlist} : $full;
        my $uid = (ref $pl eq 'HASH' && $pl->{uid}) ? $pl->{uid} : (($pl->{owner} && $pl->{owner}{uid}) || (ref $item_id eq 'HASH' ? $item_id->{uid} : undef));
        my $kind = (ref $pl eq 'HASH' && $pl->{kind}) ? $pl->{kind} : (ref $item_id eq 'HASH' ? $item_id->{kind} : undef);
        return undef unless defined $uid && defined $kind;

        my $pl_title = (ref $pl eq 'HASH' && $pl->{title}) ? $pl->{title} : 'Playlist';
        my $owner_name = ($pl->{owner} && $pl->{owner}{name}) ? $pl->{owner}{name} : '';
        my $cover_uri = (ref $pl eq 'HASH') ? (($pl->{cover} && $pl->{cover}{uri}) || $pl->{coverUri}) : undef;
        my $cover = $cover_uri ? Plugins::yandex::Browse::Common::format_cover_url($cover_uri, '200x200') : 'plugins/yandex/html/images/playlist.png';

        my $is_basic = Plugins::yandex::Browse::Common::is_basic_display_client($client);
        my $label;
        my $line1;
        my $sep = $is_basic ? " - " : " \x{2022} ";
        if ($is_basic) {
            $pl_title = Plugins::yandex::Browse::Common::sanitize_for_client($client, $pl_title);
            $owner_name = Plugins::yandex::Browse::Common::sanitize_for_client($client, $owner_name);
            my $pl_tag = "[" . cstring($client, 'PLUGIN_YANDEX_PLAYLIST') . "] ";
            $label = $pl_tag . $pl_title;
            $label .= " ($owner_name)" if $owner_name;
            $line1 = $pl_tag . $pl_title;
        } else {
            $label = "📜 " . cstring($client, 'PLUGIN_YANDEX_PLAYLIST') . ": " . $pl_title;
            $label .= " ($owner_name)" if $owner_name;
            $line1 = "📜 " . $pl_title;
        }

        return {
            name        => $label,
            line1       => $line1,
            line2       => $owner_name ? ($owner_name . $sep . cstring($client, 'PLUGIN_YANDEX_PLAYLIST')) : cstring($client, 'PLUGIN_YANDEX_PLAYLIST'),
            type        => 'playlist',
            url         => \&Plugins::yandex::Browse::_handlePlaylist,
            passthrough => [$yandex_client, $uid, $kind],
            play        => 'yandexmusic://playlist/' . $uid . '/' . $kind,
            image       => $cover,
        };
    }

    return undef;
}

# Helper: Format individual track into LMS browse item
sub _format_history_track_item {
    my ($client, $track_object) = @_;
    return undef unless $track_object && ref $track_object eq 'HASH';

    my $track_id = $track_object->{id};
    return undef unless $track_id;

    my $track_title = $track_object->{title} // 'Unknown';
    my $artist_name = 'Unknown';
    if ($track_object->{artists} && ref $track_object->{artists} eq 'ARRAY' && @{$track_object->{artists}}) {
        $artist_name = $track_object->{artists}[0]->{name} // 'Unknown';
    }

    my $album_name = '';
    if ($track_object->{albums} && ref $track_object->{albums} eq 'ARRAY' && @{$track_object->{albums}}) {
        $album_name = $track_object->{albums}[0]->{title} // '';
    }

    my $cover_uri = $track_object->{coverUri} || ($track_object->{albums} && ref $track_object->{albums} eq 'ARRAY' && $track_object->{albums}[0]->{coverUri}) || $track_object->{ogImage};
    my $icon = $cover_uri ? Plugins::yandex::Browse::Common::format_cover_url($cover_uri, '200x200') : 'html/images/cover.png';

    my $duration_ms = $track_object->{durationMs} || $track_object->{duration_ms} || 0;
    my $track_url = 'yandexmusic://' . $track_id;

    my $is_basic = Plugins::yandex::Browse::Common::is_basic_display_client($client);
    my $sep = $is_basic ? " - " : " \x{2022} ";
    if ($is_basic) {
        $track_title = Plugins::yandex::Browse::Common::sanitize_for_client($client, $track_title);
        $artist_name = Plugins::yandex::Browse::Common::sanitize_for_client($client, $artist_name);
        $album_name  = Plugins::yandex::Browse::Common::sanitize_for_client($client, $album_name);
    }

    my $line2 = $artist_name;
    $line2 .= $sep . $album_name if $album_name;

    my $raw_date = $track_object->{timestamp} || $track_object->{date} || $track_object->{listeningDate};
    if ($raw_date) {
        my $date_lbl = _format_listening_date($client, $raw_date);
        $line2 .= $sep . $date_lbl if $date_lbl;
    }

    Plugins::yandex::Browse::Common::cache_track_metadata($track_object);

    return {
        name      => $artist_name . ' - ' . $track_title,
        line1     => $track_title,
        line2     => $line2,
        type      => 'audio',
        url       => $track_url,
        image     => $icon,
        duration  => $duration_ms ? int($duration_ms / 1000) : undef,
        playall   => 1,
        on_select => 'play',
        play      => $track_url,
    };
}

# Music history: items and tracks list for a specific day
sub handleMusicHistoryDayTracks {
    my ($client, $cb, $args, $yandex_client, $tab) = @_;
    if (ref $yandex_client eq 'HASH' && !($yandex_client->{get_music_history} || $yandex_client->{tracks})) {
        $tab ||= $yandex_client;
        $yandex_client = undef;
    }
    $yandex_client = _resolve_api_client($client, $yandex_client);

    my $date = $tab->{date} // 'History';
    my $title = $tab->{title};
    if (!$title) {
        if ($date =~ /^(\d{4})-(\d{2})-(\d{2})$/) {
            $title = "$3.$2.$1";
        } else {
            $title = $date;
        }
    }

    my @menu_items;
    my @missing_ids;

    my $raw_groups = $tab->{items} // $tab->{tracks} // [];
    if (ref $raw_groups eq 'ARRAY') {
        for my $grp (@$raw_groups) {
            next unless ref $grp eq 'HASH';

            # 1. Parse context header item if present (wave, album, artist, playlist)
            my $ctx_item = _parse_history_context_item($client, $yandex_client, $grp);
            push @menu_items, $ctx_item if $ctx_item;

            # 2. Extract tracks within this group
            my @raw_tracks;
            if ($grp->{tracks} && ref $grp->{tracks} eq 'ARRAY') {
                @raw_tracks = @{$grp->{tracks}};
            } elsif ($grp->{track}) {
                @raw_tracks = ($grp->{track});
            } elsif ($grp->{id} || $grp->{title}) {
                @raw_tracks = ($grp);
            }

            for my $raw_tr (@raw_tracks) {
                next unless ref $raw_tr eq 'HASH';
                my $tr_data = (ref $raw_tr->{data} eq 'HASH') ? $raw_tr->{data} : $raw_tr;
                my $full = (ref $tr_data->{fullModel} eq 'HASH') ? $tr_data->{fullModel} : $tr_data;

                if ($full->{id} && $full->{title}) {
                    next if _is_audiobook_or_podcast_track($full);
                    my $tr_item = _format_history_track_item($client, $full);
                    push @menu_items, $tr_item if $tr_item;
                } else {
                    my $tid;
                    if (ref $tr_data->{itemId} eq 'HASH') {
                        $tid = $tr_data->{itemId}{trackId} // $tr_data->{itemId}{id};
                    } else {
                        $tid = $tr_data->{itemId} // $raw_tr->{id};
                    }
                    if ($tid) {
                        push @missing_ids, $tid;
                        push @menu_items, { _placeholder_track_id => $tid };
                    }
                }
            }
        }
    }

    if (!@menu_items) {
        $cb->({
            items => [{ name => cstring($client, 'PLUGIN_YANDEX_NO_HISTORY'), type => 'text' }],
            title => $title,
        });
        return;
    }

    if (@missing_ids) {
        $yandex_client->tracks(
            \@missing_ids,
            sub {
                my $resolved = shift;
                my %map;
                if (ref $resolved eq 'ARRAY') {
                    for my $t (@$resolved) {
                        $map{$t->{id}} = $t if $t && $t->{id};
                    }
                }
                my @final_items;
                for my $it (@menu_items) {
                    if ($it->{_placeholder_track_id}) {
                        my $tid = $it->{_placeholder_track_id};
                        my $resolved_tr = $map{$tid};
                        if ($resolved_tr) {
                            next if _is_audiobook_or_podcast_track($resolved_tr);
                            my $tr_item = _format_history_track_item($client, $resolved_tr);
                            push @final_items, $tr_item if $tr_item;
                        } else {
                            push @final_items, {
                                name => "Track $tid",
                                type => 'audio',
                                url  => 'yandexmusic://' . $tid,
                                play => 'yandexmusic://' . $tid,
                            };
                        }
                    } else {
                        push @final_items, $it;
                    }
                }
                $cb->({
                    items => \@final_items,
                    title => $title,
                });
            },
            sub {
                # Fallback: render items without unresolved placeholders
                my @avail = grep { !$_->{_placeholder_track_id} } @menu_items;
                $cb->({
                    items => \@avail,
                    title => $title,
                });
            }
        );
    } else {
        $cb->({
            items => \@menu_items,
            title => $title,
        });
    }
}

sub _iso_to_epoch {
    my $str = shift;
    return 0 unless defined $str && $str ne '';
    if ($str =~ /^\d{13,}$/) {
        return int($str / 1000);
    }
    if ($str =~ /^\d{9,11}$/) {
        return int($str);
    }
    if ($str =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:Z|([+-])(\d{2}):?(\d{2}))?/) {
        my ($y, $mon, $d, $h, $min, $s, $tz_sign, $tz_h, $tz_m) = ($1, $2, $3, $4, $5, $6, $7, $8, $9);
        require Time::Local;
        my $epoch = eval { Time::Local::timegm($s, $min, $h, $d, $mon - 1, $y) } || 0;
        if ($epoch && defined $tz_sign && defined $tz_h) {
            my $offset = $tz_h * 3600 + ($tz_m || 0) * 60;
            $epoch -= ($tz_sign eq '+' ? $offset : -$offset);
        }
        return $epoch;
    }
    return 0;
}

sub _extract_item_epoch {
    my ($item) = @_;
    return 0 unless ref $item eq 'HASH';

    my $album = $item->{album} // (exists $item->{volumes} || exists $item->{trackCount} ? $item : {});
    my $date_str = $item->{listeningDate}
                || $album->{listeningDate}
                || $item->{updateTime}
                || $album->{updateTime}
                || ($item->{track} && $item->{track}{streamProgress} && ($item->{track}{streamProgress}{updateTime} || $item->{track}{streamProgress}{timestamp}))
                || $item->{lastPlayedTimestamp}
                || $item->{timestamp}
                || $album->{timestamp}
                || '';
    return _iso_to_epoch($date_str);
}

sub _format_listening_date {
    my ($client, $raw_date) = @_;
    return '' unless defined $raw_date && $raw_date ne '';

    my $epoch = _iso_to_epoch($raw_date);
    return '' unless $epoch > 0;

    my ($sec, $min, $hour, $mday, $mon, $year) = localtime($epoch);
    my $time_str = sprintf("%02d:%02d", $hour, $min);

    my ($c_sec, $c_min, $c_hour, $c_mday, $c_mon, $c_year) = localtime(time);
    my $today_str     = sprintf("%04d-%02d-%02d", $c_year + 1900, $c_mon + 1, $c_mday);
    my ($y_sec, $y_min, $y_hour, $y_mday, $y_mon, $y_year) = localtime(time - 86400);
    my $yesterday_str = sprintf("%04d-%02d-%02d", $y_year + 1900, $y_mon + 1, $y_mday);

    my $target_date_str = sprintf("%04d-%02d-%02d", $year + 1900, $mon + 1, $mday);

    if ($target_date_str eq $today_str) {
        my $word = cstring($client, 'PLUGIN_YANDEX_TODAY');
        $word = 'Today' if !$word || $word eq 'PLUGIN_YANDEX_TODAY';
        return "$word, $time_str";
    } elsif ($target_date_str eq $yesterday_str) {
        my $word = cstring($client, 'PLUGIN_YANDEX_YESTERDAY');
        $word = 'Yesterday' if !$word || $word eq 'PLUGIN_YANDEX_YESTERDAY';
        return "$word, $time_str";
    } else {
        return sprintf("%02d.%02d.%04d %s", $mday, $mon + 1, $year + 1900, $time_str);
    }
}

# Audiobooks and podcasts history
sub handleAudiobooksHistory {
    my ($client, $cb, $args, $yandex_client) = @_;
    $yandex_client = _resolve_api_client($client, $yandex_client);

    $yandex_client->get_bookshelf_recently_played(
        0,
        20,
        sub {
            my $res = shift;
            my @raw_items;
            if (ref $res eq 'ARRAY') {
                @raw_items = @$res;
            } elsif (ref $res eq 'HASH') {
                if ($res->{entities} && ref $res->{entities} eq 'ARRAY') {
                    @raw_items = @{$res->{entities}};
                } elsif ($res->{items} && ref $res->{items} eq 'ARRAY') {
                    @raw_items = @{$res->{items}};
                } elsif ($res->{books} && ref $res->{books} eq 'ARRAY') {
                    @raw_items = @{$res->{books}};
                } elsif ($res->{albums} && ref $res->{albums} eq 'ARRAY') {
                    @raw_items = @{$res->{albums}};
                } elsif ($res->{history} && ref $res->{history} eq 'ARRAY') {
                    @raw_items = @{$res->{history}};
                }
            }

            my $userId = eval { Plugins::yandex::Plugin::_getUserIdForClient($client) } || 'default';
            my $local_book = $prefs->get("last_played_audiobook_${userId}")
                          || ($client && eval { $client->can('pluginData') } ? $client->pluginData('yandex_last_played_audiobook') : undef);

            for my $item (@raw_items) {
                $item->{_epoch} = _extract_item_epoch($item);
                if ($local_book && $local_book->{album_id}) {
                    my $alb = $item->{album} // (exists $item->{volumes} || exists $item->{trackCount} ? $item : {});
                    my $aid = $alb->{id} // $item->{id} // $item->{albumId};
                    if ($aid && $aid == $local_book->{album_id}) {
                        if (($local_book->{timestamp} || 0) > ($item->{_epoch} || 0)) {
                            $item->{_epoch} = $local_book->{timestamp};
                            $item->{timestamp} = $local_book->{timestamp};
                        }
                    }
                }
            }

            if (!@raw_items) {
                $cb->({
                    items => [{
                        name => cstring($client, 'PLUGIN_YANDEX_NO_AUDIOBOOKS'),
                        type => 'text',
                    }],
                    title => cstring($client, 'PLUGIN_YANDEX_HISTORY_AUDIOBOOKS'),
                });
                return;
            }

            # Sort descending by listening date/time: latest listened is first
            @raw_items = sort { ($b->{_epoch} || 0) <=> ($a->{_epoch} || 0) } @raw_items;

            my @items;
            for my $item (@raw_items) {
                my $album = $item->{album} // (exists $item->{volumes} || exists $item->{trackCount} ? $item : {});
                my $album_id = $album->{id} // $item->{id} // $item->{albumId};
                next unless $album_id;

                my $title = $album->{title} // $item->{title} // $item->{name} // 'Audiobook';
                my $artists = $album->{artists} // $item->{artists} // $album->{authors} // $item->{authors} // [];
                my $author_name = '';
                if (ref $artists eq 'ARRAY' && @$artists) {
                    $author_name = join(', ', map { $_->{name} // '' } @$artists);
                }

                my $cover_uri = $album->{coverUri} // $item->{coverUri} // $album->{ogImage} // $item->{ogImage};
                my $icon = Plugins::yandex::Browse::Common::format_cover_url($cover_uri, '200x200');

                my $is_basic = Plugins::yandex::Browse::Common::is_basic_display_client($client);
                my $sep = $is_basic ? " - " : " \x{2022} ";
                my $dur_left = $album->{durationLeft} // $item->{durationLeft};
                my $dur_sec  = $album->{durationSec}  // $item->{durationSec};
                my $progress_str = '';
                if ($dur_left && $dur_sec && $dur_sec > 0) {
                    my $pct = int((($dur_sec - $dur_left) / $dur_sec) * 100);
                    $pct = 100 if $pct > 100;
                    $progress_str = "$pct%";
                }

                my $tr_info = '';
                if ($item->{track} && ref $item->{track} eq 'HASH') {
                    my $tr = $item->{track};
                    my $pos = ($tr->{streamProgress} && $tr->{streamProgress}{endPositionSec})
                        ? int($tr->{streamProgress}{endPositionSec}) : 0;
                    my $tr_title = $tr->{title} || '';
                    if ($tr_title && $title) {
                        $tr_title =~ s/^\Q$title\E[\.\s\:\-]*//i;
                    }
                    if ($pos > 0) {
                        my $pos_fmt = _format_seconds($pos);
                        $tr_info = $tr_title ? "$tr_title ($pos_fmt)" : $pos_fmt;
                    } elsif ($tr_title) {
                        $tr_info = $tr_title;
                    }
                }

                my $subtitle = $author_name;
                if ($tr_info) {
                    $subtitle .= ($subtitle ? $sep : "") . $tr_info;
                    $subtitle .= " ($progress_str)" if $progress_str && $tr_info !~ /\Q$progress_str\E/;
                } elsif ($progress_str) {
                    $subtitle .= ($subtitle ? $sep : "") . $progress_str;
                }

                # Display listening date/time if available
                my $raw_date = $item->{listeningDate}
                            || $album->{listeningDate}
                            || $item->{updateTime}
                            || $album->{updateTime}
                            || ($item->{track} && $item->{track}{streamProgress} && ($item->{track}{streamProgress}{updateTime} || $item->{track}{streamProgress}{timestamp}))
                            || $item->{lastPlayedTimestamp}
                            || $item->{timestamp}
                            || $album->{timestamp};
                my $date_label = _format_listening_date($client, $item->{_epoch} || $raw_date);
                if ($date_label) {
                    $subtitle .= ($subtitle ? $sep : "") . $date_label;
                }

                if ($is_basic) {
                    $title = Plugins::yandex::Browse::Common::sanitize_for_client($client, $title);
                    $subtitle = Plugins::yandex::Browse::Common::sanitize_for_client($client, $subtitle);
                }

                push @items, {
                    name        => $title,
                    line1       => $title,
                    line2       => $subtitle,
                    type        => 'link',
                    url         => \&handleBookMenu,
                    passthrough => [$yandex_client, $album_id],
                    image       => $icon,
                };
            }

            $cb->({
                items => \@items,
                title => cstring($client, 'PLUGIN_YANDEX_HISTORY_AUDIOBOOKS'),
            });
        },
        sub {
            my $error = shift;
            $cb->({ items => [{ name => "Error: $error", type => 'text' }] });
        }
    );
}

# Book actions menu: Resume, Start from beginning, Table of contents, Mark finished
sub handleBookMenu {
    my ($client, $cb, $args, $yandex_client, $album_id) = @_;
    $yandex_client = _resolve_api_client($client, $yandex_client, \$album_id);

    $yandex_client->get_album_with_tracks(
        $album_id,
        sub {
            my $album = shift;
            my @all_tracks = _flatten_album_tracks($album);
            unless (@all_tracks) {
                $cb->({ items => [{ name => 'No tracks in album', type => 'text' }] });
                return;
            }

            my ($resume_idx, $offset_sec) = _calculate_resume_point($album, \@all_tracks);
            my $chapter_num = $resume_idx + 1;
            my $offset_fmt = _format_seconds($offset_sec);

            my $resume_name;
            if ($album->{listeningFinished}) {
                $resume_name = cstring($client, 'PLUGIN_YANDEX_PLAY_FROM_START');
            } else {
                $resume_name = sprintf(cstring($client, 'PLUGIN_YANDEX_RESUME_CHAPTER_AT'), $chapter_num, $offset_fmt);
            }

            my @items;
            if ($album->{listeningFinished}) {
                push @items, {
                    name        => cstring($client, 'PLUGIN_YANDEX_PLAY_FROM_START'),
                    type        => 'action',
                    url         => \&handleResumeBookAction,
                    passthrough => [$yandex_client, $album_id, 0, 0],
                    image       => 'plugins/yandex/html/images/foundbroadcast1_svg.png',
                    nextWindow  => 'nowPlaying',
                };
            } else {
                push @items, (
                    {
                        name        => sprintf(cstring($client, 'PLUGIN_YANDEX_RESUME_CHAPTER_AT'), $chapter_num, $offset_fmt),
                        type        => 'action',
                        url         => \&handleResumeBookAction,
                        passthrough => [$yandex_client, $album_id, $resume_idx, $offset_sec],
                        image       => 'plugins/yandex/html/images/foundbroadcast1_svg.png',
                        nextWindow  => 'nowPlaying',
                    },
                    {
                        name        => cstring($client, 'PLUGIN_YANDEX_PLAY_FROM_START'),
                        type        => 'action',
                        url         => \&handleResumeBookAction,
                        passthrough => [$yandex_client, $album_id, 0, 0],
                        image       => 'plugins/yandex/html/images/foundbroadcast1_svg.png',
                        nextWindow  => 'nowPlaying',
                    },
                );
            }

            push @items, (
                {
                    name        => cstring($client, 'PLUGIN_YANDEX_TABLE_OF_CONTENTS'),
                    type        => 'link',
                    url         => \&handleBookChaptersList,
                    passthrough => [$yandex_client, $album_id],
                    image       => 'html/images/playlists.png',
                },
                {
                    name        => cstring($client, 'PLUGIN_YANDEX_MARK_FINISHED'),
                    type        => 'action',
                    url         => \&handleMarkBookFinished,
                    passthrough => [$yandex_client, $album_id],
                    image       => 'plugins/yandex/html/images/icon_blank_svg.png',
                },
            );

            $cb->({
                items => \@items,
                title => $album->{title} // 'Audiobook',
            });
        },
        sub {
            my $error = shift;
            $cb->({ items => [{ name => "Error: $error", type => 'text' }] });
        },
        { resumeStream => 'true', richTracks => 'true', withListeningFinished => 'true' }
    );
}

# Quick 1-click resume from main menu
sub handleQuickResumeBook {
    my ($client, $cb, $args, $yandex_client, $album_id) = @_;
    $yandex_client = _resolve_api_client($client, $yandex_client, \$album_id);

    $yandex_client->get_album_with_tracks(
        $album_id,
        sub {
            my $album = shift;
            my @all_tracks = _flatten_album_tracks($album);
            unless (@all_tracks) {
                $cb->({ items => [{ name => 'No tracks in album', type => 'text' }] });
                return;
            }

            my ($resume_idx, $offset_sec) = _calculate_resume_point($album, \@all_tracks);
            handleResumeBookAction($client, $cb, $args, $yandex_client, $album_id, $resume_idx, $offset_sec);
        },
        sub {
            my $error = shift;
            $cb->({ items => [{ name => "Error: $error", type => 'text' }] });
        },
        { resumeStream => 'true', richTracks => 'true', withListeningFinished => 'true' }
    );
}

# Action to queue all chapters and jump to the target chapter and offset
sub handleResumeBookAction {
    my ($client, $cb, $args, $yandex_client, $album_id, $start_idx, $offset_sec) = @_;
    if (ref $yandex_client eq 'HASH' && !($yandex_client->{get_album_with_tracks})) {
        $album_id   ||= $yandex_client->{album_id};
        $start_idx  //= $yandex_client->{start_idx};
        $offset_sec //= $yandex_client->{offset_sec};
        $yandex_client = undef;
    }
    $yandex_client = _resolve_api_client($client, $yandex_client, \$album_id);

    $start_idx  = int($start_idx || 0);
    $offset_sec = int($offset_sec || 0);

    $yandex_client->get_album_with_tracks(
        $album_id,
        sub {
            my $album = shift;
            my @all_tracks = _flatten_album_tracks($album);
            unless (@all_tracks) {
                $cb->({ items => [{ name => 'No tracks in album', type => 'text' }] });
                return;
            }

            $log->info(sprintf("YANDEX: Starting book %s at chapter %d offset %ds",
                $album_id, $start_idx, $offset_sec));

            # Track last played audiobook locally for quick resume
            if ($album && $album->{title} && $album_id) {
                my $userId = eval { Plugins::yandex::Plugin::_getUserIdForClient($client) } || 'default';
                my $book_info = {
                    album_id  => $album_id,
                    title     => $album->{title},
                    cover_uri => $album->{coverUri} || $album->{ogImage} || '',
                    timestamp => time(),
                };
                $prefs->set("last_played_audiobook_${userId}", $book_info);
                if ($client && eval { $client->can('pluginData') }) {
                    $client->pluginData('yandex_last_played_audiobook', $book_info);
                }
                my $cache = Slim::Utils::Cache->new();
                $cache->set('yandex_album_' . $album_id, $album, 86400);
            }

            # Clear existing playlist
            $client->execute(['playlist', 'clear']);

            # Add all chapters with metadata cached
            for my $i (0 .. $#all_tracks) {
                my $tr = $all_tracks[$i];
                my $tid = $tr->{id} or next;

                # Ensure metadata cache has track info
                Plugins::yandex::Browse::Common::cache_track_metadata($tr);

                my $track_url = 'yandexmusic://' . $tid . '?album_id=' . $album_id . '&type=audiobook';
                if ($i == $start_idx && $offset_sec > 0) {
                    $track_url .= '&offset=' . $offset_sec;
                }
                $client->execute(['playlist', 'add', $track_url]);
            }

            # Jump to the target chapter with timeOffset
            if ($offset_sec > 0) {
                $client->execute(['playlist', 'jump', $start_idx, 0, 0, { timeOffset => $offset_sec }]);
            } else {
                $client->execute(['playlist', 'jump', $start_idx]);
            }

            # On hardware players with button/display navigation (Boom, Classic, Transporter, etc.),
            # transition directly to Now Playing ('playlist' mode) and abort OPML feed processing.
            # Returning an items list would cause LMS XMLBrowser to display a dummy "1 of 1 / Playing..." menu.
            my $is_button = ($args && ref $args eq 'HASH' && $args->{isButton}) ? 1 : 0;
            my $has_button_mode = (defined $client && blessed($client) && eval { defined &Slim::Buttons::Common::mode } && !eval { $client->isa('Slim::Player::SqueezePlay') });
            my $cur_mode = $has_button_mode ? eval { Slim::Buttons::Common::mode($client) } : undef;

            if (defined $cur_mode) {
                # If player was blocked during XMLBrowser async fetch, unblock first
                if ($client->can('unblock')) {
                    eval { $client->unblock(); };
                }
                $cur_mode = eval { Slim::Buttons::Common::mode($client) } || '';
                if ($cur_mode eq 'xmlbrowser') {
                    eval { Slim::Buttons::Common::popMode($client); };
                }
                my $after_mode = eval { Slim::Buttons::Common::mode($client) } || '';
                if ($after_mode ne 'playlist') {
                    eval { Slim::Buttons::Common::pushModeLeft($client, 'playlist'); };
                }
                eval { $client->update if $client->can('update'); };
            }

            if ($is_button) {
                $cb->({
                    command    => 'mode ?',
                    abort      => 1,
                    nextWindow => 'nowPlaying',
                });
            } else {
                $cb->({
                    items => [{
                        name => cstring($client, 'PLUGIN_YANDEX_PLAYING'),
                        type => 'text',
                    }],
                    title => $album->{title} // 'Audiobook',
                    nextWindow => 'nowPlaying',
                });
            }
        },
        sub {
            my $error = shift;
            $cb->({ items => [{ name => "Error: $error", type => 'text' }] });
        },
        { resumeStream => 'true', richTracks => 'true', withListeningFinished => 'true' }
    );
}

# Table of contents (list of chapters)
sub handleBookChaptersList {
    my ($client, $cb, $args, $yandex_client, $album_id) = @_;
    $yandex_client = _resolve_api_client($client, $yandex_client, \$album_id);

    $yandex_client->get_album_with_tracks(
        $album_id,
        sub {
            my $album = shift;
            my @all_tracks = _flatten_album_tracks($album);
            unless (@all_tracks) {
                $cb->({ items => [{ name => 'No tracks in album', type => 'text' }] });
                return;
            }

            my ($resume_idx, $offset_sec) = _calculate_resume_point($album, \@all_tracks);
            my $last_tid = ($album->{lastListened} && ref $album->{lastListened} eq 'HASH') ? $album->{lastListened}{trackId} : undef;
            my $is_basic = Plugins::yandex::Browse::Common::is_basic_display_client($client);
            my $sep = $is_basic ? " - " : " \x{2022} ";

            my @items;
            for my $i (0 .. $#all_tracks) {
                my $tr = $all_tracks[$i];
                my $num = $i + 1;
                my $dur_sec = int(($tr->{durationMs} || 0) / 1000);
                my $dur_fmt = _format_seconds($dur_sec);
                my $title   = $tr->{title} || sprintf(cstring($client, 'PLUGIN_YANDEX_CHAPTER'), $num);

                my $is_current = ($i == $resume_idx) || ($last_tid && $tr->{id} && $tr->{id} eq $last_tid);
                my $sp = ($tr->{streamProgress} && ref $tr->{streamProgress} eq 'HASH') ? $tr->{streamProgress} : undef;

                my $status_lbl = '';
                my $is_fin = $sp && ((ref $sp->{everFinished}) ? ${$sp->{everFinished}} : ($sp->{everFinished} || 0));
                if ($is_fin) {
                    my $word = cstring($client, 'PLUGIN_YANDEX_FINISHED');
                    $status_lbl = ($word && $word ne 'PLUGIN_YANDEX_FINISHED') ? $word : 'Finished';
                } elsif ($sp && ($sp->{endPositionSec} || 0) > 0) {
                    $status_lbl = _format_seconds(int($sp->{endPositionSec})) . " / $dur_fmt";
                } elsif ($is_current) {
                    my $word = cstring($client, 'PLUGIN_YANDEX_CURRENT');
                    $status_lbl = ($word && $word ne 'PLUGIN_YANDEX_CURRENT') ? $word : 'Current';
                }

                my $line2 = $dur_fmt;
                if ($status_lbl) {
                    $line2 .= $sep . $status_lbl;
                }

                my $line1 = "$num. $title";
                if ($is_current && !$is_basic) {
                    $line1 = "▶ $line1";
                }

                if ($is_basic) {
                    $line1 = Plugins::yandex::Browse::Common::sanitize_for_client($client, $line1);
                    $line2 = Plugins::yandex::Browse::Common::sanitize_for_client($client, $line2);
                }

                push @items, {
                    name        => "$num. $title ($dur_fmt)" . ($status_lbl ? " - $status_lbl" : ""),
                    line1       => $line1,
                    line2       => $line2,
                    type        => 'action',
                    url         => \&handleResumeBookAction,
                    passthrough => [$yandex_client, $album_id, $i, 0],
                    image       => 'plugins/yandex/html/images/foundbroadcast1_svg.png',
                    nextWindow  => 'nowPlaying',
                };
            }

            $cb->({
                items => \@items,
                title => cstring($client, 'PLUGIN_YANDEX_TABLE_OF_CONTENTS'),
            });
        },
        sub {
            my $error = shift;
            $cb->({ items => [{ name => "Error: $error", type => 'text' }] });
        },
        { richTracks => 'true' }
    );
}

# Mark entire album as finished
sub handleMarkBookFinished {
    my ($client, $cb, $args, $yandex_client, $album_id) = @_;
    $yandex_client = _resolve_api_client($client, $yandex_client, \$album_id);

    $yandex_client->mark_album_finished(
        $album_id,
        sub {
            $log->info("YANDEX: Marked album $album_id as finished");
            $cb->({
                items => [{
                    name => cstring($client, 'PLUGIN_YANDEX_MARKED_FINISHED'),
                    type => 'text',
                }],
            });
        },
        sub {
            my $error = shift;
            $log->error("YANDEX: Failed to mark album $album_id as finished: $error");
            $cb->({
                items => [{
                    name => "Error: $error",
                    type => 'text',
                }],
            });
        }
    );
}

# Helper: flatten tracks from volumes
sub _flatten_album_tracks {
    my ($album) = @_;
    return () unless $album;

    my $album_type = $album->{type} || $album->{metaType} || 'audiobook';
    my @all_tracks;
    if ($album->{volumes} && ref $album->{volumes} eq 'ARRAY') {
        for my $volume (@{$album->{volumes}}) {
            if (ref $volume eq 'ARRAY') {
                for my $tr (@$volume) {
                    if ($tr) {
                        $tr->{albums} ||= [{ id => $album->{id}, title => $album->{title}, type => $album_type }];
                        push @all_tracks, $tr;
                    }
                }
            }
        }
    } elsif ($album->{tracks} && ref $album->{tracks} eq 'ARRAY') {
        for my $tr (@{$album->{tracks}}) {
            if ($tr) {
                $tr->{albums} ||= [{ id => $album->{id}, title => $album->{title}, type => $album_type }];
                push @all_tracks, $tr;
            }
        }
    }
    return @all_tracks;
}

# Helper: calculate resume chapter index and offset seconds within chapter
sub _calculate_resume_point {
    my ($album, $all_tracks) = @_;
    return (0, 0) unless $all_tracks && @$all_tracks;

    if ($album->{listeningFinished}) {
        return (0, 0);
    }

    my $target_idx = 0;
    my $found_by_pos = 0;

    if ($album->{trackPosition} && ref $album->{trackPosition} eq 'HASH') {
        my $tp_vol = $album->{trackPosition}{volume};
        my $tp_idx = $album->{trackPosition}{index};

        if (defined $tp_vol && defined $tp_idx) {
            if ($album->{volumes} && ref $album->{volumes} eq 'ARRAY' && @{$album->{volumes}} > 0) {
                # Try 0-based volume & index first ($v == $tp_vol && $i == $tp_idx),
                # then 1-based volume & index ($v + 1 == $tp_vol && $i + 1 == $tp_idx)
                for my $one_based (0, 1) {
                    my $count = 0;
                    VOLUME_LOOP: for my $v (0 .. $#{$album->{volumes}}) {
                        my $vol = $album->{volumes}[$v];
                        next unless ref $vol eq 'ARRAY';
                        for my $i (0 .. $#$vol) {
                            my $match_v = $one_based ? ($v + 1) : $v;
                            my $match_i = $one_based ? ($i + 1) : $i;
                            if ($match_v == $tp_vol && $match_i == $tp_idx) {
                                $target_idx = $count;
                                $found_by_pos = 1;
                                last VOLUME_LOOP;
                            }
                            $count++;
                        }
                    }
                    last if $found_by_pos;
                }
            } else {
                # Single volume or flat track list
                if ($tp_idx < @$all_tracks) {
                    # Could be 0-based or 1-based; disambiguate using duration if available
                    if ($tp_idx > 0 && $tp_idx <= @$all_tracks && defined $album->{durationSec} && defined $album->{durationLeft}) {
                        my $elapsed = ($album->{durationSec} || 0) - ($album->{durationLeft} || 0);
                        my $accum_0 = 0;
                        for my $k (0 .. $tp_idx - 1) {
                            $accum_0 += int(($all_tracks->[$k]{durationMs} || 0) / 1000);
                        }
                        my $accum_1 = 0;
                        for my $k (0 .. $tp_idx - 2) {
                            $accum_1 += int(($all_tracks->[$k]{durationMs} || 0) / 1000);
                        }
                        if (abs($elapsed - $accum_1) < abs($elapsed - $accum_0)) {
                            $target_idx = $tp_idx - 1;
                        } else {
                            $target_idx = $tp_idx;
                        }
                    } else {
                        $target_idx = $tp_idx;
                    }
                    $found_by_pos = 1;
                }
            }
        }
    }

    # If trackPosition was missing or not found, calculate chapter from total elapsed time
    my $offset_sec = 0;
    if (defined $album->{durationSec} && defined $album->{durationLeft}) {
        my $total_elapsed = ($album->{durationSec} || 0) - ($album->{durationLeft} || 0);
        $total_elapsed = 0 if $total_elapsed < 0;

        if (!$found_by_pos) {
            my $accum = 0;
            for my $i (0 .. $#$all_tracks) {
                my $d = int(($all_tracks->[$i]{durationMs} || 0) / 1000);
                if ($accum + $d > $total_elapsed || $i == $#$all_tracks) {
                    $target_idx = $i;
                    last;
                }
                $accum += $d;
            }
        }

        $target_idx = 0 if $target_idx < 0 || $target_idx >= @$all_tracks;

        my $preceding_sec = 0;
        for my $i (0 .. $target_idx - 1) {
            $preceding_sec += int(($all_tracks->[$i]{durationMs} || 0) / 1000);
        }

        $offset_sec = $total_elapsed - $preceding_sec;
        $offset_sec = 0 if $offset_sec < 0;

        my $cur_dur_sec = int(($all_tracks->[$target_idx]{durationMs} || 0) / 1000);
        if ($cur_dur_sec > 0 && $offset_sec >= $cur_dur_sec) {
            $offset_sec = $cur_dur_sec - 1;
        }
    } elsif (!$found_by_pos) {
        # Fallback: scan individual tracks for streamProgress (e.g. Orwell album without root trackPosition)
        my $last_finished_idx = -1;
        my $in_progress_found = 0;
        for my $i (0 .. $#$all_tracks) {
            my $tr = $all_tracks->[$i];
            if ($tr->{streamProgress} && ref $tr->{streamProgress} eq 'HASH') {
                my $sp = $tr->{streamProgress};
                my $pos = int($sp->{endPositionSec} || 0);
                my $is_fin = (ref $sp->{everFinished}) ? ${$sp->{everFinished}} : ($sp->{everFinished} || 0);
                if ($is_fin) {
                    $last_finished_idx = $i;
                } elsif ($pos > 0) {
                    $target_idx = $i;
                    $offset_sec = $pos;
                    $in_progress_found = 1;
                    last;
                }
            }
        }
        if (!$in_progress_found && $last_finished_idx >= 0) {
            if ($last_finished_idx + 1 < @$all_tracks) {
                $target_idx = $last_finished_idx + 1;
                $offset_sec = 0;
            } else {
                $target_idx = 0;
                $offset_sec = 0;
            }
        }
    }

    $target_idx = 0 if $target_idx < 0 || $target_idx >= @$all_tracks;
    return ($target_idx, $offset_sec);
}

# Helper: format seconds to MM:SS or H:MM:SS
sub _format_seconds {
    my ($sec) = @_;
    $sec = int($sec || 0);
    $sec = 0 if $sec < 0;

    my $hours = int($sec / 3600);
    my $mins  = int(($sec % 3600) / 60);
    my $secs  = $sec % 60;

    if ($hours > 0) {
        return sprintf("%d:%02d:%02d", $hours, $mins, $secs);
    } else {
        return sprintf("%d:%02d", $mins, $secs);
    }
}

1;
