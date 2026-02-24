package Plugins::yandex::TrackShort;

use strict;
use warnings;
use Data::Dumper;
use File::Slurp;
use JSON::XS::VersionOneAndTwo;
use Slim::Utils::Log;

my $log = logger('plugin.yandex');
sub new {
    my ($class, $data, $client) = @_;
    my $self = {
        id => $data->{id},
        track_id => $data->{id},
        album_id => $data->{albumId},
        timestamp => $data->{timestamp},
        #track => $data->{track}, # частичная инфа
        client     => $client,
    };
    bless $self, $class;
    #print Dumper($self);
    return $self;
}


sub fetch_track {
    my ($self, $callback, $error_callback) = @_;
    my $track_id = $self->{id};
    my $url = 'https://api.music.yandex.net/tracks/' . $track_id;
    #$log->info(Dumper($self->{request}));
    $self->{client}->{request}->get(
        $url,
        undef,
        sub {
            my $result = shift;
            if (exists $result->{result} && exists $result->{result}->[0]) {

                my $track_object =  Plugins::yandex::Track->new($result->{result}->[0], $self->{client});
                $callback->(\$track_object);
            }
            else {
                $error_callback->("Не удалось получить данные");
            }
        },
        $error_callback,
    );
}
1;