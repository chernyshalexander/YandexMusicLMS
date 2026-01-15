package Plugins::yandex::ClientAsync;
use strict;
use warnings;
use JSON;
use Slim::Utils::Log;
use Data::Dumper;
use Plugins::yandex::RequestAsync;
use Plugins::yandex::TrackShort;
use Plugins::yandex::Track;

#our $VERSION = '0.01';
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
            foreach my $item (@{$result->{result}->{library}->{tracks}}) {
                push @track_short_objects, Plugins::yandex::TrackShort->new($item,$self);
            }
            $callback->(\@track_short_objects);
        },
        $error_callback,
    );
}

sub tracks {
    my ($self, $track_ids, $callback, $error_callback) = @_;

    my @ids = ref $track_ids eq 'ARRAY' ? @$track_ids : ($track_ids);
    my $url = 'https://api.music.yandex.net/tracks/' . join(',', @ids);

    $self->{request}->get(# тут наверное нужен post + номера треков в json
        $url,
        undef,
        sub {
            my $result = shift;
            my @tracks;
            foreach my $item (@$result) {
                push @tracks, Plugins::yandex::Track->new($item);
            }
            $callback->(\@tracks);
        },
        $error_callback,
    );
}

sub get_me {
    my ($self) = @_;
    return $self->{me};
}

1;
