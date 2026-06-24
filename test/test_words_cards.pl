#!/usr/bin/perl
# Test /words/cards endpoint
# Purpose: Explore what /words/cards returns for track IDs
# Documentation: POST /words/cards { trackIds, viewedCards }

use strict;
use warnings;
use lib "/usr/libexec/logitechmediaserver/CPAN";
use lib "/home/chernysh/Projects/yandex";
unshift @INC, "/home/chernysh/Projects/yandex";

use test::TokenHelper;
use Plugins::yandex::ClientAsync;
use Data::Dumper;
use JSON::XS;
use HTTP::Request;
use LWP::UserAgent;

my $token = TokenHelper::get_token()
    or die "No token configured in test/token.txt\n";

print "Testing /words/cards endpoint\n";
print "=" x 80 . "\n";
print "Token: " . substr($token, 0, 10) . "...\n\n";

my $client = Plugins::yandex::ClientAsync->new($token);
$client->init(sub {
    print "Connected to Yandex API\n\n";

    # Test 1: Get cards for popular tracks
    print "TEST 1: POST /words/cards with some track IDs\n";
    print "-" x 80 . "\n";

    # Use some popular track IDs
    my @track_ids = ('49620451', '33835962', '21325043');  # Popular Russian tracks
    my $payload = {
        trackIds => \@track_ids,
        viewedCards => []  # Initially no viewed cards
    };

    my $json_payload = JSON::XS->new->canonical(1)->encode($payload);
    print "Request payload: $json_payload\n";

    $client->{request}->post(
        "https://api.music.yandex.net/words/cards",
        {
            'Content-Type' => 'application/json',
            'X-Yandex-Music-Client' => 'WindowsMusicAPI/5.98',
        },
        $json_payload,
        sub {
            my $res = shift;

            if (!$res) {
                print "ERROR: Empty response\n";
                goto_test2();
                return;
            }

            print "\nRESPONSE:\n";
            my $json = JSON::XS->new->pretty(1)->canonical(1)->encode($res);
            print $json;

            # Analyze response
            print "\n\nANALYSIS:\n";
            if (ref $res eq 'HASH') {
                if (exists $res->{cards}) {
                    print "✓ Response contains 'cards' field\n";
                    print "  Number of cards: " . scalar(@{$res->{cards}}) . "\n";

                    if (scalar(@{$res->{cards}}) > 0) {
                        print "  First card keys: " . join(", ", keys %{$res->{cards}[0]}) . "\n";
                        print "  First card: " . JSON::XS->new->pretty(1)->encode($res->{cards}[0]) . "\n";
                    }
                }
                if (exists $res->{error}) {
                    print "✗ Error in response: $res->{error}\n";
                }
            }

            goto_test2();

        },
        sub {
            my $error = shift;
            print "ERROR: $error\n";
            goto_test2();
        }
    );
});

sub goto_test2 {
    print "\n\nTEST 2: POST /words/cards with viewedCards\n";
    print "-" x 80 . "\n";

    my @track_ids = ('49620451', '33835962');
    my $payload = {
        trackIds => \@track_ids,
        viewedCards => ['49620451']  # Mark first track as viewed
    };

    my $json_payload = JSON::XS->new->canonical(1)->encode($payload);
    print "Request payload: $json_payload\n";

    my $client = Plugins::yandex::ClientAsync->new(TokenHelper::get_token());
    $client->init(sub {
        $client->{request}->post(
            "https://api.music.yandex.net/words/cards",
            {
                'Content-Type' => 'application/json',
                'X-Yandex-Music-Client' => 'WindowsMusicAPI/5.98',
            },
            $json_payload,
            sub {
                my $res = shift;

                print "\nRESPONSE:\n";
                my $json = JSON::XS->new->pretty(1)->canonical(1)->encode($res);
                print $json;

                print "\n\nCOMPARISON:\n";
                print "With viewedCards filter, we should get different cards than without it\n";

                goto_test3();
            },
            sub {
                my $error = shift;
                print "ERROR: $error\n";
                goto_test3();
            }
        );
    });
}

sub goto_test3 {
    print "\n\nTEST 3: GET /rotor/wave/settings (for comparison with vibe wheel)\n";
    print "-" x 80 . "\n";
    print "Checking if /words/cards is related to Vibe Wheel or My Vibe\n";

    my $client = Plugins::yandex::ClientAsync->new(TokenHelper::get_token());
    $client->init(sub {
        $client->{request}->get(
            "https://api.music.yandex.net/rotor/wave/settings?seeds=mood:energetic",
            {},
            sub {
                my $res = shift;

                print "\nVibe Wheel Settings Response:\n";
                my $json = JSON::XS->new->pretty(1)->canonical(1)->encode($res);
                print $json;

                print "\n\nCONCLUSION:\n";
                print "Comparing /words/cards with /rotor/wave/settings...\n";
                print "- If /words/cards returns lyric-related data → song lyrics/words feature\n";
                print "- If /words/cards returns card/station data → Vibe wheel related\n";

                exit(0);
            },
            sub {
                my $error = shift;
                print "ERROR: $error\n";
                exit(1);
            }
        );
    });
}

# Keep the event loop running
Slim::Networking::Select::addRead(fileno(STDIN), sub {});
Slim::Networking::Select::loop();
