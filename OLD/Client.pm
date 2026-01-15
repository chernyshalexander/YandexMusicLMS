package Plugins::yandex::Client;

use strict;
use warnings;
use JSON;
use File::Slurp

our $VERSION = '0.01';

sub new {
    my ($class, $token, %args) = @_;
    my $request = $args{request} || Plugins::yandex::Request->new(token => $token, proxy_url => $args{proxy_url});

    my $self = {
        token => $token,
        request => $request,
        me => undef,
    };

    bless $self, $class;
    return $self;
}

sub init {
    my ($self) = @_;
    my $result = $self->{request}->get('https://api.music.yandex.net/account/status ');

    #write_file('debug-user.json', encode_json($result));
    if (exists $result->{result} && exists $result->{result}->{account}) {
        $self->{me} = $result->{result}->{account}; # ← Правильное место с login
    } else {
        die "Не удалось получить данные пользователя";
    }

    return $self;
}

sub users_likes_tracks {
    my ($self) = @_;
    my $url='https://api.music.yandex.net/users/'. $self->get_me()->{uid}. '/likes/tracks/';
    
    my $result = $self->{request}->get($url);
    #write_file('debug-tracks.json', encode_json($result));
    my @track_short_objects;
    foreach my $item (@{$result->{result}->{library}->{tracks}}) {
        push @track_short_objects, Plugins::yandex::TrackShort->new($item);
    }

    return \@track_short_objects;
}

sub tracks {
    my ($self, $track_ids) = @_;
    my @ids = ref $track_ids eq 'ARRAY' ? @$track_ids : ($track_ids);
    my $url = 'https://api.music.yandex.net/tracks/ ' . join(',', @ids);
    my $result = $self->{request}->get($url);

    my @tracks;
    foreach my $item (@$result) {
        push @tracks, Plugins::yandex::Track->new($item);
    }

    return \@tracks;
}

sub get_me {
    my ($self) = @_;
    return $self->{me};
}

1;