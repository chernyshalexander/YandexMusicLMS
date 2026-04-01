package Plugins::yandex::Browse::Common;

use strict;
use warnings;
use utf8;

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);

my $log = logger('plugin.yandex');

# Shared Rendering Functions

sub renderTrackList {
    my ($tracks, $cb, $title, $container_url, $params) = @_;

    my @items;
    
    foreach my $track_object (@$tracks) {
         my $track_title = $track_object->{title} // 'Unknown';
         my $artist_name = 'Unknown';
         if ($track_object->{artists} && ref $track_object->{artists} eq 'ARRAY' && @{$track_object->{artists}}) {
             $artist_name = $track_object->{artists}[0]->{name};
         }

         my $track_id = $track_object->{id};
         my $track_url = 'yandexmusic://' . $track_id;
         
         my $icon = 'plugins/yandex/html/images/foundbroadcast1_svg.png';
         
         my $cover_uri;
         if ($track_object->{coverUri}) {
             $cover_uri = $track_object->{coverUri};
         } elsif ($track_object->{raw} && $track_object->{raw}->{coverUri}) {
             $cover_uri = $track_object->{raw}->{coverUri};
         } elsif ($track_object->{ogImage}) {
             $cover_uri = $track_object->{ogImage};
         } elsif ($track_object->{albums} && ref $track_object->{albums} eq 'ARRAY' && $track_object->{albums}[0]->{coverUri}) {
             $cover_uri = $track_object->{albums}[0]->{coverUri};
         }
         
         if ($cover_uri) {
             $icon = $cover_uri;
             $icon =~ s/%%/200x200/;
             $icon = "https://$icon";
         }

         my $duration_ms = $track_object->{durationMs} || $track_object->{duration_ms} || ($track_object->{raw} ? $track_object->{raw}->{durationMs} : 0);

         my $album_name = 'Unknown';
         if ($track_object->{albums} && ref $track_object->{albums} eq 'ARRAY' && @{$track_object->{albums}}) {
             $album_name = $track_object->{albums}[0]->{title};
         }

         my $line2 = $artist_name;
         $line2 .= " \x{2022} " . $album_name if $album_name && $album_name ne 'Unknown';

         push @items, {
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

         cache_track_metadata($track_object);
    }

    my $result = {
        items => \@items,
        title => $title,
    };
    
    if ($params) {
        $result->{offset} = $params->{offset} if defined $params->{offset};
        $result->{total}  = $params->{total} if defined $params->{total};
    }

    $cb->($result);
}

sub cache_track_metadata {
    my ($track_object) = @_;
    my $track_id = $track_object->{id};
    return unless $track_id;

    my $track_title = $track_object->{title} // 'Unknown';
    my $artist_name = 'Unknown';
    if ($track_object->{artists} && ref $track_object->{artists} eq 'ARRAY' && @{$track_object->{artists}}) {
        $artist_name = $track_object->{artists}[0]->{name};
    }

    my $icon = 'plugins/yandex/html/images/foundbroadcast1_svg.png';
    my $cover_uri;
    if ($track_object->{coverUri}) {
        $cover_uri = $track_object->{coverUri};
    } elsif ($track_object->{raw} && $track_object->{raw}->{coverUri}) {
        $cover_uri = $track_object->{raw}->{coverUri};
    } elsif ($track_object->{ogImage}) {
        $cover_uri = $track_object->{ogImage};
    } elsif ($track_object->{albums} && ref $track_object->{albums} eq 'ARRAY' && @{$track_object->{albums}} && $track_object->{albums}[0]->{coverUri}) {
        $cover_uri = $track_object->{albums}[0]->{coverUri};
    }
    
    if ($cover_uri) {
        $icon = $cover_uri;
        $icon =~ s/%%/200x200/;
        $icon = "https://$icon";
    }

    my $duration_ms = $track_object->{durationMs} || $track_object->{duration_ms} || ($track_object->{raw} ? $track_object->{raw}->{durationMs} : 0);

    my $album_name = 'Unknown';
    if ($track_object->{albums} && ref $track_object->{albums} eq 'ARRAY' && @{$track_object->{albums}}) {
        $album_name = $track_object->{albums}[0]->{title};
    }

    my $cache = Slim::Utils::Cache->new();

    # Consolidate with existing cache (preserve bitrate, _complete, etc. like in Deezer)
    my $existing = $cache->get('yandex_meta_' . $track_id) || {};

    my $meta = {
        %$existing,                                                         # preserve all old fields
        title    => $track_title,
        artist   => $artist_name,
        album    => $album_name,
        duration => $duration_ms ? int($duration_ms / 1000) : 0,
        cover    => $icon,
        bitrate  => $existing->{bitrate} || 192000,                        # keep real bitrate if available
        _complete => 1,                                                     # mark as complete (full metadata)
    };

    $cache->set('yandex_meta_' . $track_id, $meta, '90d');                 # 90 days like Deezer
    
    return $meta;
}

sub renderAlbumList {
    my ($yandex_client, $albums, $cb, $title) = @_;

    my @items;

    foreach my $album (@$albums) {
        next unless $album;

        my $album_id = $album->{id};
        my $album_title = $album->{title} // 'Unknown';
        my $artist_name = 'Unknown';

        if ($album->{artists} && ref $album->{artists} eq 'ARRAY' && @{$album->{artists}}) {
            $artist_name = $album->{artists}[0]->{name};
        }

        my $icon = 'plugins/yandex/html/images/foundbroadcast1_svg.png';
        if ($album->{coverUri}) {
            $icon = $album->{coverUri};
            $icon =~ s/%%/200x200/;
            $icon = "https://$icon";
        }

        push @items, {
            name  => $album_title . ' (' . $artist_name . ')',
            type  => 'album',
            url   => \&Plugins::yandex::Browse::_handleAlbum,
            passthrough => [$yandex_client, $album_id],
            image => $icon,
            play  => 'yandexmusic://album/' . $album_id,
        };
    }

    $cb->({
        items => \@items,
        title => $title,
    });
}

sub renderPlaylistList {
    my ($yandex_client, $playlists, $cb, $title) = @_;

    my @items;

    foreach my $playlist (@$playlists) {
        next unless $playlist;

        my $playlist_title = $playlist->{title} // 'Unknown';
        my $owner_name = 'Unknown';

        if ($playlist->{owner} && $playlist->{owner}->{name}) {
            $owner_name = $playlist->{owner}->{name};
        }

        my $icon = 'plugins/yandex/html/images/foundbroadcast1_svg.png';
        if ($playlist->{cover} && $playlist->{cover}->{uri}) {
            $icon = $playlist->{cover}->{uri};
            $icon =~ s/%%/200x200/;
            $icon = "https://$icon";
        }

        push @items, {
            name => $playlist_title . ' (' . $owner_name . ')',
            type => 'playlist',
            url => \&Plugins::yandex::Browse::_handlePlaylist,
            passthrough => [$yandex_client, $playlist->{owner}->{uid}, $playlist->{kind}],
            image => $icon,
            play => 'yandexmusic://playlist/' . $playlist->{owner}->{uid} . '/' . $playlist->{kind},
        };
    }

    $cb->({
        items => \@items,
        title => $title,
    });
}

1;
