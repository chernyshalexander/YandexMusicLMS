package Plugins::yandex::ClientAsync;
use strict;
use warnings;
use JSON::XS::VersionOneAndTwo;
use Slim::Utils::Log;
use Data::Dumper;
use Plugins::yandex::RequestAsync;
use Plugins::yandex::TrackShort;
use Plugins::yandex::Track;


my $log = logger('plugin.yandex');
sub new {
    my ($class, $token, %args) = @_;
    my $request = $args{request} || Plugins::yandex::RequestAsync->new(token => $token, proxy_url => $args{proxy_url});
    my $self = {
        token => $token,
        request => $request,
        me => undef,
    };
    bless $self, $class;
    return $self;
}

sub init {
    my ($self, $callback, $error_callback) = @_;
    $log->info("ClientAsync, 25");
    $log->info(Dumper($self->{request}));
    $self->{request}->get(
        'https://api.music.yandex.net/account/status',
        undef,
        sub {
            my $result = shift;
            if (exists $result->{result} && exists $result->{result}->{account}) {
                $self->{me} = $result->{result}->{account};
                $log->info("ClientAsync,33");
                $log->info(Dumper($result));
                $callback->($self);
            } else {
                $log->info("Не удалось получить данные пользователя");
                $error_callback->("Не удалось получить данные пользователя");
            }
        },
        $error_callback,
    );
}

sub users_likes_tracks {
    my ($self, $callback, $error_callback) = @_;

    my $url = 'https://api.music.yandex.net/users/' . $self->get_me->{uid} . '/likes/tracks/';

    $self->{request}->get(
        $url,
        undef,
        sub {
            my $result = shift;
            my @track_short_objects;
            if (exists $result->{result} && exists $result->{result}->{library} && exists $result->{result}->{library}->{tracks}) {
                foreach my $item (@{$result->{result}->{library}->{tracks}}) {
                    push @track_short_objects, Plugins::yandex::TrackShort->new($item,$self);
                }
            }
            $callback->(\@track_short_objects);
        },
        $error_callback,
    );
}

sub users_likes_albums {
    my ($self, $callback, $error_callback) = @_;

    my $url = 'https://api.music.yandex.net/users/' . $self->get_me->{uid} . '/likes/albums';
    
    # Send rich=true to get full album info
    my $params = { rich => 'true' };

    $self->{request}->get(
        $url,
        $params,
        sub {
            my $result = shift;
            # $log->error("LIKED ALBUMS RESULT: " . Dumper($result));
            my @albums;
            if (exists $result->{result}) {
               foreach my $item (@{$result->{result}}) {
                   # The API returns an object with a 'album' field which contains the actual album info
                   if ($item->{album}) {
                       push @albums, $item->{album};
                   }
               }
            }
            $callback->(\@albums);
        },
        $error_callback,
    );
}

sub users_likes_artists {
    my ($self, $callback, $error_callback) = @_;

    my $url = 'https://api.music.yandex.net/users/' . $self->get_me->{uid} . '/likes/artists';

    $self->{request}->get(
        $url,
        undef,
        sub {
            my $result = shift;
            # $log->error("LIKED ARTISTS RESULT: " . Dumper($result));
            my @artists;
             if (exists $result->{result}) {
               foreach my $item (@{$result->{result}}) {
                   # API returns artist objects directly in the list, not wrapped in 'artist'
                   push @artists, $item;
               }
            }
            $callback->(\@artists);
        },
        $error_callback,
    );
}

sub users_likes_playlists {
    my ($self, $callback, $error_callback) = @_;

    my $url = 'https://api.music.yandex.net/users/' . $self->get_me->{uid} . '/likes/playlists';

    $self->{request}->get(
        $url,
        undef,
        sub {
            my $result = shift;
            # $log->error("LIKED PLAYLISTS RESULT: " . Dumper($result));
            my @playlists;
             if (exists $result->{result}) {
               foreach my $item (@{$result->{result}}) {
                   # The API returns an object with a 'playlist' field
                   if ($item->{playlist}) {
                       push @playlists, $item->{playlist};
                   }
               }
            }
            $callback->(\@playlists);
        },
        $error_callback,
    );
}

sub users_playlists_list {
    my ($self, $callback, $error_callback) = @_;

    my $url = 'https://api.music.yandex.net/users/' . $self->get_me->{uid} . '/playlists/list';

    $self->{request}->get(
        $url,
        undef,
        sub {
            my $result = shift;
            # $log->error("USER PLAYLISTS RESULT: " . Dumper($result));
            my @playlists;
            if (exists $result->{result}) {
                # Direct array of playlists
                @playlists = @{$result->{result}};
            }
            $callback->(\@playlists);
        },
        $error_callback,
    );
}

sub tracks {
    my ($self, $track_ids, $callback, $error_callback) = @_;

    my @ids = ref $track_ids eq 'ARRAY' ? @$track_ids : ($track_ids);
    # my $url = 'https://api.music.yandex.net/tracks/' . join(',', @ids); # OLD GET
    my $url = 'https://api.music.yandex.net/tracks/'; 

    my $data = {
        'track-ids' => \@ids,
        'with-positions' => 'true',
    };

    $self->{request}->post_form(
        $url,
        $data,
        sub {
            my $result = shift;
            my @tracks;
            # Result from tracks endpoint is a list of track objects directly
            my $list = $result;
            if (ref $result eq 'HASH' && exists $result->{result}) {
                $list = $result->{result};
            }

            if (ref $list eq 'ARRAY') {
                foreach my $item (@$list) {
                    push @tracks, Plugins::yandex::Track->new($item);
                }
                $callback->(\@tracks);
            } else {
                 $log->error("ClientAsync tracks: unexpected result format: " . Dumper($result));
                 $error_callback->("Unexpected result format from tracks endpoint");
            }
        },
        $error_callback,
    );
}

sub get_me {
    my ($self) = @_;
    return $self->{me};
}

sub get_album_with_tracks {
    my ($self, $album_id, $callback, $error_callback) = @_;

    my $url = 'https://api.music.yandex.net/albums/' . $album_id . '/with-tracks';

    $self->{request}->get(
        $url,
        undef,
        sub {
            my $result = shift;
            if (exists $result->{result}) {
                $callback->($result->{result});
            } else {
                $error_callback->("Failed to get album with tracks");
            }
        },
        $error_callback,
    );
}

sub get_artist_tracks {
    my ($self, $artist_id, $callback, $error_callback) = @_;
    
    my $url = 'https://api.music.yandex.net/artists/' . $artist_id . '/tracks';
    # Default page-size is 20, let's bump it a bit or handle pagination later
    # For now, let's just get the first page.
    my $params = { 'page-size' => 100 };

    $self->{request}->get(
        $url,
        $params,
        sub {
            my $result = shift;
             if (exists $result->{result} && exists $result->{result}->{tracks}) {
                $callback->($result->{result}->{tracks});
            } else {
                $error_callback->("Failed to get artist tracks");
            }
        },
        $error_callback,
    );
}

sub get_artist_albums {
    my ($self, $artist_id, $callback, $error_callback) = @_;

    my $url = 'https://api.music.yandex.net/artists/' . $artist_id . '/direct-albums';
    my $params = { 'page-size' => 100, 'sort-by' => 'year' };

    $self->{request}->get(
        $url,
        $params,
        sub {
            my $result = shift;
             if (exists $result->{result} && exists $result->{result}->{albums}) {
                $callback->($result->{result}->{albums});
            } else {
                $error_callback->("Failed to get artist albums");
            }
        },
        $error_callback,
    );
}

sub get_playlist {
    my ($self, $user_id, $kind, $callback, $error_callback) = @_;

    # Format: /users/{user_id}/playlists/{kind}
    my $url = 'https://api.music.yandex.net/users/' . $user_id . '/playlists/' . $kind;
    
    $self->{request}->get(
        $url,
        undef,
        sub {
            my $result = shift;
            if (exists $result->{result}) {
                 # The playlist object contains a 'tracks' array, but the tracks inside might be lightweight objects.
                 # Actually, Yandex usually returns 'tracks' as a list of objects with 'id' and 'album_id' or embedded 'track' object.
                 # Let's see what we get.
                $callback->($result->{result});
            } else {
                $error_callback->("Failed to get playlist");
            }
        },
        $error_callback,
    );
}

sub rotor_station_tracks {
    my ($self, $station_id, $queue, $callback, $error_callback) = @_;

    my $url = 'https://api.music.yandex.net/rotor/station/' . $station_id . '/tracks';
    my $params = { 'settings2' => 'true' };
    
    if ($queue) {
        $params->{queue} = $queue;
    }

    $self->{request}->get(
        $url,
        $params,
        sub {
            my $result = shift;
            if (exists $result->{result} && exists $result->{result}->{sequence}) {
                # The 'sequence' contains objects which have a 'track' field
                my @tracks;
                foreach my $item (@{$result->{result}->{sequence}}) {
                    next unless $item->{track};
                    push @tracks, $item->{track};
                }
                
                my $batch_id = $result->{result}->{batchId};
                
                $callback->({
                    tracks => \@tracks,
                    batch_id => $batch_id,
                });
            } else {
                $error_callback->("Failed to get station tracks");
            }
        },
        $error_callback,
    );
}

1;
