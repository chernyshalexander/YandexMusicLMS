#!/usr/bin/perl
# Purpose: Testing Yandex Music landing3 (blocks/waves) async requests
# Usage: perl test/test_landing_async.pl

use strict;
use warnings;
use Data::Dumper;
use lib '/home/chernysh/Projects/yandex';
use JSON::PP;

# We use AnyEvent to run the async http request
use AnyEvent;
use Plugins::yandex::RequestAsync;

my $token = do { open my $fh, "<", "test/token.txt" or die "Please create test/token.txt with your Yandex Music token\n"; local $/; my $t = <$fh>; $t =~ s/\s+//g; $t };

my $request = Plugins::yandex::RequestAsync->new(
    token => $token,
);

my $cv = AnyEvent->condvar;

print "Fetching landing3 blocks...\n";
$request->get(
    'https://api.music.yandex.net/landing3',
    { blocks => 'mixes-waves,waves' },
    sub {
        my $json = shift;
        # print Dumper($json);
        if ($json->{result} && $json->{result}->{blocks}) {
            foreach my $block (@{$json->{result}->{blocks}}) {
                my $b_type = $block->{type} // 'unknown';
                my $b_title = $block->{title} // 'No Title';
                print "\n--- Block: $b_type ($b_title) ---\n";
                
                my $entities = $block->{entities} // [];
                foreach my $e (@$entities) {
                    my $e_data = $e->{data} // {};
                    my $e_type = $e_data->{type} // 'unknown';
                    
                    if ($e_type eq 'station' || $e_data->{station}) {
                        my $st = $e_data->{station} // $e_data;
                        my $st_id = $st->{id} // {};
                        my $tag = $st_id->{tag} // 'no-tag';
                        my $type = $st_id->{type} // 'no-type';
                        my $name = $st->{name} // 'Unnamed Station';
                        print "  -> Station: [$type:$tag] - $name\n";
                    } else {
                        my $name = $e_data->{title} // $e_data->{name} // 'Unnamed';
                        print "  -> Entity: $e_type - $name\n";
                    }
                }
            }
        } else {
            print "No blocks found in result or error.\n";
            print Dumper($json);
        }
        $cv->send;
    },
    sub {
        my $error = shift;
        print "Error: $error\n";
        $cv->send;
    }
);

$cv->recv;
