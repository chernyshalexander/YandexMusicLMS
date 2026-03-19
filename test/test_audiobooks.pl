#!/usr/bin/perl
# Purpose: Test /non-music/catalogue endpoint to understand audiobooks response structure
# Usage: perl test/test_audiobooks.pl

use strict;
use warnings;
use lib "/usr/libexec/logitechmediaserver/CPAN";
use lib "/home/chernysh/Projects/yandex";
unshift @INC, "/home/chernysh/Projects/yandex";

use test::TokenHelper;
use Plugins::yandex::ClientAsync;
use Data::Dumper;
use JSON::XS;

my $token = TokenHelper::get_token()
    or die "No token configured in test/token.txt\n";

print "Token: " . substr($token, 0, 10) . "...\n\n";

my $client = Plugins::yandex::ClientAsync->new($token);
$client->init(sub {
    print "Testing /non-music/catalogue endpoint...\n";
    print "=" x 80 . "\n";

    $client->{request}->get("https://api.music.yandex.net/non-music/catalogue", {}, sub {
        my $res = shift;

        if (!$res || !$res->{result}) {
            print "ERROR: Empty response\n";
            return;
        }

        my $result = $res->{result};

        print "Response structure keys:\n";
        foreach my $key (sort keys %$result) {
            my $value = $result->{$key};
            my $ref_type = ref($value);
            my $type = $ref_type ? $ref_type : 'scalar';

            if ($ref_type eq 'ARRAY') {
                printf "  %s (ARRAY) - %d items\n", $key, scalar(@$value);
                if (@$value && scalar(@$value) > 0) {
                    my $first = $value->[0];
                    if (ref($first) eq 'HASH') {
                        print "    First item keys: " . join(", ", sort keys %$first) . "\n";
                    } else {
                        print "    First item: $first\n";
                    }
                }
            } elsif ($ref_type eq 'HASH') {
                printf "  %s (HASH) - keys: %s\n", $key, join(", ", sort keys %$value);
            } else {
                printf "  %s (%s) - %s\n", $key, $type, substr($value, 0, 50);
            }
        }

        print "\n" . "=" x 80 . "\n";
        print "Full response structure (first 100 lines):\n";
        print "=" x 80 . "\n";

        my $json = JSON::XS->new->pretty(1)->canonical(1)->encode($res);
        my @lines = split /\n/, $json;
        foreach my $i (0 .. $#lines) {
            last if $i > 100;
            print $lines[$i] . "\n";
        }

        if (scalar(@lines) > 100) {
            print "... (" . (scalar(@lines) - 100) . " more lines)\n";
        }

        exit(0);

    }, sub {
        my $error = shift;
        print "ERROR: $error\n";
        exit(1);
    });
});

# Keep the event loop running
Slim::Networking::Select::addRead(fileno(STDIN), sub {});
Slim::Networking::Select::loop();
