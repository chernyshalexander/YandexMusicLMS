package Plugins::yandex::Browse::Common;

=encoding utf8

=head1 NAME

Plugins::yandex::Browse::Common - Shared rendering helpers and metadata cache

=head1 DESCRIPTION

Provides two kinds of functions used by all Browse:: submodules:

=over 4

=item * B<render*> functions — convert Yandex API objects into LMS OPML item lists
and call the LMS callback with the result.

=item * B<cache_track_metadata> — normalises a Yandex track object and stores it in
the LMS cache under the C<yandex_meta_{id}> key (TTL 90 days). Always merges with
any existing entry so that bitrate and AES key set by ProtocolHandler are not lost.

=back

=cut

use strict;
use warnings;
use utf8;

use Scalar::Util qw(blessed reftype);
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);

my $log = logger('plugin.yandex');

sub format_cover_url {
    my ($uri, $size) = @_;
    return 'plugins/yandex/html/images/foundbroadcast1_svg.png' unless $uri;
    $size //= '200x200';
    $uri =~ s/%%/$size/;
    if ($uri =~ /^\/\//) {
        return 'https:' . $uri;
    } elsif ($uri !~ /^https?:\/\//) {
        return 'https://' . $uri;
    }
    return $uri;
}

# Build an LMS OPML item list from an array of Yandex track objects and call $cb.
# Covers art is resolved from several possible API fields (coverUri, ogImage,
# albums[0].coverUri) and normalised to a full https:// URL at 200×200px.
# Also calls cache_track_metadata() for every track so that getMetadataFor()
# returns instantly when LMS later asks for track info during playback.
sub renderTrackList {
    my ($tracks, $cb, $title, $container_url, $params) = @_;

    my @items;

    foreach my $track_object (@$tracks) {
         my $track_title = $track_object->{title} // 'Unknown';
         my $artist_name = 'Unknown';
         if ($track_object->{artists} && ref $track_object->{artists} eq 'ARRAY' && @{$track_object->{artists}}) {
             $artist_name = $track_object->{artists}[0]->{name};
         }

         next if !$track_object->{id} || ($track_title eq 'Unknown' && $artist_name eq 'Unknown');

         my $track_id = $track_object->{id};
         my $track_url = 'yandexmusic://' . $track_id;

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

         my $icon = format_cover_url($cover_uri, '200x200');

         my $duration_ms = $track_object->{durationMs} || $track_object->{duration_ms} || ($track_object->{raw} ? $track_object->{raw}->{durationMs} : 0);

         my $album_name = 'Unknown';
         if ($track_object->{albums} && ref $track_object->{albums} eq 'ARRAY' && @{$track_object->{albums}}) {
             $album_name = $track_object->{albums}[0]->{title};
         }

         my $client = ($params && ref $params eq 'HASH') ? $params->{client} : undef;
         my $is_basic = is_basic_display_client($client);
         my $sep = $is_basic ? " - " : " \x{2022} ";
         my $line2 = $artist_name;
         $line2 .= $sep . $album_name if $album_name && $album_name ne 'Unknown';

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

    my $icon = format_cover_url($cover_uri, '200x200');

    my $duration_ms = $track_object->{durationMs} || $track_object->{duration_ms} || ($track_object->{raw} ? $track_object->{raw}->{durationMs} : 0);

    my $album_name = 'Unknown';
    my $album_id;
    my $album_type;
    if ($track_object->{albums} && ref $track_object->{albums} eq 'ARRAY' && @{$track_object->{albums}}) {
        $album_name = $track_object->{albums}[0]->{title};
        $album_id   = $track_object->{albums}[0]->{id};
        $album_type = $track_object->{albums}[0]->{type} || $track_object->{albums}[0]->{metaType};
    }
    my $track_type = $track_object->{type} || '';
    my $is_podcast = (($album_type && $album_type =~ /podcast|audiobook/i) || ($track_type =~ /podcast|audiobook/i)) ? 1 : 0;

    my $cache = Slim::Utils::Cache->new();

    # Consolidate with existing cache (preserve bitrate, _complete, etc. like in Deezer)
    my $existing = $cache->get('yandex_meta_' . $track_id) || {};

    my $meta = {
        %$existing,                                                         # preserve all old fields
        title      => $track_title,
        artist     => $artist_name,
        album      => $album_name,
        album_id   => $album_id // $existing->{album_id},
        album_type => $album_type // $existing->{album_type},
        is_podcast => $is_podcast || $existing->{is_podcast} || 0,
        duration   => $duration_ms ? int($duration_ms / 1000) : ($existing->{duration} || 0),
        cover      => $icon,
        bitrate    => $existing->{bitrate} || 192000,                        # keep real bitrate if available
        _complete  => 1,                                                     # mark as complete (full metadata)
    };

    $cache->set('yandex_meta_' . $track_id, $meta, '90d');                 # 90 days 
    
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

        my $icon = format_cover_url($album->{coverUri}, '200x200');

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

        my $icon = format_cover_url($playlist->{cover} ? $playlist->{cover}->{uri} : undef, '200x200');

        push @items, {
            name => $playlist_title . ' (' . $owner_name . ')',
            type => 'playlist',
            url => \&Plugins::yandex::Browse::_handlePlaylist,
            passthrough => [$yandex_client, $playlist->{owner}->{uid}, $playlist->{kind}],
            image => $icon,
            play => 'yandexmusic://playlist/' . $playlist->{owner}->{uid} . '/' . $playlist->{kind},
        };
    }

}

# Detect clients with limited font/character support (Squeezeplay desktop,
# SqueezeOS on Touch/Radio/Controller, and older hardware players like Boom, Classic 3,
# Transporter, Receiver, etc.). These clients lack modern Unicode emojis (💿, 👤, 📜, ⚡)
# and special geometric symbols (▶ U+25B6).
sub is_basic_display_client {
    my ($client) = @_;
    return 0 unless $client && ref $client;

    # Explicit override (useful for testing or custom client capability tags)
    if (eval { $client->can('is_basic_display') }) {
        my $val = eval { $client->is_basic_display };
        return $val ? 1 : 0 if defined $val;
    }
    if (eval { reftype($client) eq 'HASH' } && defined $client->{is_basic_display}) {
        return $client->{is_basic_display} ? 1 : 0;
    }

    # Model inspection (LMS clients inherit from Slim::Player::Client which is an array-based object)
    my $model = eval { $client->can('model') ? $client->model : undef }
             || (eval { reftype($client) eq 'HASH' } ? ($client->{model} || '') : '')
             || '';

    # Exclude headless players (squeezelite) controlled by modern web/mobile apps
    return 0 if $model eq 'squeezelite';

    # SqueezePlay / Jive players: desktop squeezeplay, Touch (fab4), Radio (baby), Controller (controller/jive)
    return 1 if eval { $client->isa('Slim::Player::SqueezePlay') };
    return 1 if $model =~ /^(?:squeezeplay|fab4|baby|radio|controller|jive)$/i;

    # Hardware players with character/VFD or limited displays: Boom, Classic/SB2/SB3, Transporter, Receiver, SB1, SliMP3, SoftSqueeze
    return 1 if eval { $client->isa('Slim::Player::Boom') } ||
                eval { $client->isa('Slim::Player::Squeezebox2') } ||
                eval { $client->isa('Slim::Player::Transporter') } ||
                eval { $client->isa('Slim::Player::Receiver') } ||
                eval { $client->isa('Slim::Player::Squeezebox1') } ||
                eval { $client->isa('Slim::Player::SLIMP3') } ||
                eval { $client->isa('Slim::Player::SoftSqueeze') };
    return 1 if $model =~ /^(?:boom|squeezebox[123]|classic|transporter|receiver|slimp3|softsqueeze)$/i;

    return 0;
}

# Sanitize text for basic display clients: replace unsupported glyphs
# (▶ -> >, • -> -, ⚡ -> *, SMP emojis stripped)
sub sanitize_for_client {
    my ($client, $text) = @_;
    return $text unless defined $text && $text ne '';
    return $text unless is_basic_display_client($client);

    $text =~ s/\x{25B6}/>/g;             # ▶ to >
    $text =~ s/\x{2022}/-/g;             # • to -
    $text =~ s/\x{26A1}/*/g;             # ⚡ to *
    $text =~ s/[\x{1F000}-\x{1FAFF}]//g; # SMP emojis
    $text =~ s/\s{2,}/ /g;
    $text =~ s/^\s+//;
    $text =~ s/\s+$//;
    return $text;
}

1;
