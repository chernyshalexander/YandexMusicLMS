#!/usr/bin/perl
# Цель: исследовать полную структуру entities в personal-playlists
# Использование: perl test/test_personal_playlists.pl

use strict;
use warnings;
use LWP::UserAgent;
use JSON::PP;

my $token = do {
    open my $fh, "<", "test/token.txt" or die "Создайте test/token.txt с токеном Яндекс Музыки\n";
    local $/;
    my $t = <$fh>;
    $t =~ s/\s+//g;
    $t
};

my $ua = LWP::UserAgent->new;
$ua->default_header("Authorization" => "OAuth $token");
$ua->default_header("X-Yandex-Music-Client" => "YandexMusicAndroid/24.13.1");

print "=== Тест landing3?blocks=personal-playlists — полная структура ===\n\n";

my $res = $ua->get('https://api.music.yandex.net/landing3?blocks=personal-playlists');
die "HTTP ошибка: " . $res->status_line unless $res->is_success;

my $raw = decode_json($res->decoded_content);
my $blocks = $raw->{result}{blocks} // [];

printf "Блоков: %d\n\n", scalar(@$blocks);

foreach my $block (@$blocks) {
    printf "Блок type=%s, entities=%d\n", $block->{type} // '?', scalar(@{$block->{entities} // []});

    foreach my $entity (@{$block->{entities} // []}) {
        print "\n  Entity:\n";
        _dump_hash($entity->{data}, "    ", 0);
    }
}

sub _dump_hash {
    my ($h, $indent, $depth) = @_;
    return if $depth > 4;
    if (ref $h eq 'HASH') {
        foreach my $k (sort keys %$h) {
            my $v = $h->{$k};
            if (ref $v eq 'HASH') {
                printf "%s%s:\n", $indent, $k;
                _dump_hash($v, $indent . "  ", $depth + 1);
            } elsif (ref $v eq 'ARRAY') {
                printf "%s%s: [array, %d items]\n", $indent, $k, scalar(@$v);
            } else {
                my $sv = defined $v ? $v : 'undef';
                $sv = substr($sv, 0, 60) . '...' if length($sv) > 60;
                printf "%s%s: %s\n", $indent, $k, $sv;
            }
        }
    }
}
