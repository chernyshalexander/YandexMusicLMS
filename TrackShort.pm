package Plugins::yandex::TrackShort;

use strict;
use warnings;
use Data::Dumper;
use File::Slurp;
use JSON;


sub new {
    my ($class, $data) = @_;
    my $self = {
        id => $data->{id},
        track_id => $data->{id},
        album_id => $data->{albumId},
        timestamp => $data->{timestamp},
        #track => $data->{track}, # частичная инфа
    };
    bless $self, $class;
    #print Dumper($self);
    return $self;
}

sub fetch_track {
    my ($self, $client) = @_;
    # print Dumper($self);
    # print Dumper($client);
    # print Dumper($self->{track_id});
    my $track_data = $client->{request}->get("https://api.music.yandex.net/tracks/" . $self->{track_id});
    #write_file('debug-tracks-data.json', encode_json($track_data));
    return Plugins::yandex::Track->new($track_data->{result}->[0]);
}

1;