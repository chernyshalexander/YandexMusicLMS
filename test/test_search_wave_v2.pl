#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use Data::Dumper;
use JSON::PP;
use LWP::UserAgent;

# Load token from test/token.txt
my $token_file = 'test/token.txt';
my $token;
if (-f $token_file) {
    open my $fh, '<', $token_file or die "Cannot open $token_file: $!";
    $token = <$fh>;
    chomp $token;
    close $fh;
} else {
    die "Token file not found at $token_file\n";
}

my $ua = LWP::UserAgent->new(timeout => 10);
my $base_url = 'https://api.music.yandex.net';

print "=" x 80 . "\n";
print "TEST: Search with type=all for 'rock' - Inspect result structure\n";
print "=" x 80 . "\n";

my $query = 'rock';
my $search_url = "$base_url/search?text=$query&type=all&page=0&nocorrect=true";

my $req = HTTP::Request->new(GET => $search_url);
$req->header('Authorization' => "OAuth $token");

my $res = $ua->request($req);
if ($res->is_success) {
    my $data = decode_json($res->content);

    print "Top-level keys: " . join(', ', sort keys %$data) . "\n\n";

    if (exists $data->{result}) {
        print "Result type: " . ref($data->{result}) . "\n";
        print "Result keys: " . join(', ', sort keys %{$data->{result}}) . "\n\n";

        my $result = $data->{result};
        foreach my $type (qw(tracks albums artists playlists podcasts wave vibes)) {
            if (exists $result->{$type}) {
                my $type_data = $result->{$type};
                my $count = ref($type_data) eq 'HASH' && exists $type_data->{results}
                    ? scalar(@{$type_data->{results}})
                    : (ref($type_data) eq 'ARRAY' ? scalar(@$type_data) : 'unknown');
                print "✓ $type: exists (count: $count)\n";

                # Show structure for first result of each type
                if (ref($type_data) eq 'HASH' && $type_data->{results} && @{$type_data->{results}}) {
                    print "  First result keys: " . join(', ', keys %{$type_data->{results}->[0]}) . "\n";
                }
            } else {
                print "✗ $type: NOT found\n";
            }
        }

        print "\n\nFull result structure:\n";
        print Dumper($result);
    }
} else {
    print "ERROR: " . $res->status_line . "\n";
    print $res->content . "\n";
}
