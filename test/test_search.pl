#!/usr/bin/perl
# Test search endpoint

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
    print "Testing /search endpoint for audiobooks...\n";
    print "=" x 80 . "\n";

    $client->{request}->get("https://api.music.yandex.net/search?text=аудиокнига&type=album&page=0", {}, sub {
        my $res = shift;

        if (!$res) {
            print "ERROR: Empty response\n";
            return;
        }

        my $json = JSON::XS->new->pretty(1)->canonical(1)->encode($res);
        print $json;
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
