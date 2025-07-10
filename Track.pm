package YandexMusicLMS::Track;

use strict;
use warnings;
use Data::Dumper;
use File::Slurp;
use JSON;

sub new {
    my ($class, $data) = @_;
    my $self = {
        raw => $data,
        id => $data->{id},
        title => $data->{title},
        artists => $data->{artists},
        albums => $data->{albums},
        duration_ms => $data->{durationMs},
        available => $data->{available},
        download_info => undef,
    };
    bless $self, $class;
    return $self;
}

sub get_download_info {
    my ($self, $client) = @_;
    my $result = $client->{request}->get("https://api.music.yandex.net/tracks/" . $self->{id} . "/download-info");
    #print Dumper($result);
    write_file('debug-dw-info.json', encode_json($result));
    $self->{download_info} = $result;
}

sub download {
    my ($self, $client, $filename) = @_;

    unless ($self->{download_info}) {
        $self->get_download_info($client);
    }

    foreach my $info (@{$self->{download_info}}) {
        if ($info->{directLink}) {
            my $url = $info->{host} . "/get-mp3/" . $info->{path} . "?track-id=$self->{id}&play=false";
            #print "Скачиваем $url\n";
            my $res = $client->{request}->{ua}->get($url, ':content_file' => $filename);
            if ($res->is_success) {
                print "Сохранено как $filename\n";
                return 1;
            } else {
                die "Ошибка загрузки: " . $res->status_line;
            }
        }
    }

    die "Невозможно скачать трек — нет доступных ссылок";
}

1;