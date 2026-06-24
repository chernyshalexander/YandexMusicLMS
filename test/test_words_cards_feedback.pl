#!/usr/bin/perl
# Test /words/cards/feedback endpoint
# Purpose: Explore feedback mechanism for word cards
# Documentation: PUT /words/cards/feedback { feedback }

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

print "Testing /words/cards/feedback endpoint\n";
print "=" x 80 . "\n";
print "Token: " . substr($token, 0, 10) . "...\n\n";

my $client = Plugins::yandex::ClientAsync->new($token);
$client->init(sub {
    print "Connected to Yandex API\n\n";

    # First, get some cards to know their structure
    print "STEP 1: Get cards first\n";
    print "-" x 80 . "\n";

    my @track_ids = ('49620451', '33835962', '21325043');
    my $payload = {
        trackIds => \@track_ids,
        viewedCards => []
    };

    my $json_payload = JSON::XS->new->canonical(1)->encode($payload);

    $client->{request}->post(
        "https://api.music.yandex.net/words/cards",
        {
            'Content-Type' => 'application/json',
            'X-Yandex-Music-Client' => 'WindowsMusicAPI/5.98',
        },
        $json_payload,
        sub {
            my $cards_res = shift;

            if (!$cards_res) {
                print "ERROR: No cards response\n";
                exit(1);
            }

            print "Got cards response:\n";
            my $json = JSON::XS->new->pretty(1)->canonical(1)->encode($cards_res);
            print $json;

            # Now test feedback
            print "\n\nSTEP 2: Send feedback for cards\n";
            print "-" x 80 . "\n";

            # Try different feedback formats
            my @feedback_tests = (
                {
                    name => "Like feedback",
                    data => {
                        feedback => {
                            trackId => '49620451',
                            action => 'like'
                        }
                    }
                },
                {
                    name => "Dislike feedback",
                    data => {
                        feedback => {
                            trackId => '33835962',
                            action => 'dislike'
                        }
                    }
                },
                {
                    name => "Skip feedback",
                    data => {
                        feedback => {
                            trackId => '21325043',
                            action => 'skip'
                        }
                    }
                },
                {
                    name => "View feedback (mark as viewed)",
                    data => {
                        feedback => {
                            trackId => '49620451',
                            action => 'view'
                        }
                    }
                },
                {
                    name => "Array of feedbacks",
                    data => {
                        feedback => [
                            { trackId => '49620451', action => 'like' },
                            { trackId => '33835962', action => 'dislike' }
                        ]
                    }
                }
            );

            my $test_index = 0;
            test_feedback($test_index);

            sub test_feedback {
                my $idx = shift;
                return finish_testing() if $idx >= scalar(@feedback_tests);

                my $test = $feedback_tests[$idx];
                print "TEST " . ($idx + 1) . ": " . $test->{name} . "\n";
                print "-" x 40 . "\n";

                my $fb_payload = JSON::XS->new->canonical(1)->encode($test->{data});
                print "Feedback payload: $fb_payload\n";

                my $test_client = Plugins::yandex::ClientAsync->new(TokenHelper::get_token());
                $test_client->init(sub {
                    $test_client->{request}->request(
                        'PUT',
                        "https://api.music.yandex.net/words/cards/feedback",
                        {
                            'Content-Type' => 'application/json',
                            'X-Yandex-Music-Client' => 'WindowsMusicAPI/5.98',
                        },
                        $fb_payload,
                        sub {
                            my $res = shift;

                            if ($res) {
                                print "RESPONSE: " . JSON::XS->new->pretty(1)->canonical(1)->encode($res) . "\n";
                            } else {
                                print "RESPONSE: Empty/Success\n";
                            }

                            print "\n";
                            test_feedback($idx + 1);
                        },
                        sub {
                            my $error = shift;
                            print "ERROR: $error\n\n";
                            test_feedback($idx + 1);
                        }
                    );
                });
            }

            sub finish_testing {
                print "\n\nFINAL ANALYSIS:\n";
                print "=" x 80 . "\n";
                print "The /words/cards/feedback endpoint appears to be for tracking user interactions\n";
                print "with word cards (showing likes, dislikes, views, etc.)\n";
                print "\nPossible purposes:\n";
                print "1. Feedback for personalized word/lyric cards in player\n";
                print "2. Tracking user preferences for music discovery\n";
                print "3. Supporting 'Learn Lyrics' or similar feature\n";
                exit(0);
            }
        },
        sub {
            my $error = shift;
            print "ERROR getting cards: $error\n";
            exit(1);
        }
    );
});

# Keep the event loop running
Slim::Networking::Select::addRead(fileno(STDIN), sub {});
Slim::Networking::Select::loop();
