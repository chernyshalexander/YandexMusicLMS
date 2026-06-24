#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use Data::Dumper;
use JSON::PP;
use LWP::UserAgent;
use Encode qw(encode);

# Load token from test/token.txt
my $token_file = 'test/token.txt';
my $token;
if (-f $token_file) {
    open my $fh, '<', $token_file or die "Cannot open $token_file: $!";
    $token = <$fh>;
    chomp $token;
    close $fh;
} else {
    die "Token file not found at $token_file. Create it with your OAuth token.\n";
}

my $ua = LWP::UserAgent->new(timeout => 10);
my $base_url = 'https://api.music.yandex.net';

# Test 1: Search with type=all for "rock"
print "=" x 80 . "\n";
print "TEST 1: Search with type=all for 'rock'\n";
print "=" x 80 . "\n";

my $query = 'rock';
my $search_url_all = "$base_url/search?" . join('&',
    'text=' . $query,
    'type=all',
    'page=0',
    'nocorrect=true'
);

print "URL: $search_url_all\n\n";

my $req = HTTP::Request->new(GET => $search_url_all);
$req->header('Authorization' => "OAuth $token");

my $res = $ua->request($req);
if ($res->is_success) {
    my $data = decode_json($res->content);

    print "Keys in response: " . join(', ', sort keys %$data) . "\n\n";

    # Check if 'wave' key exists
    if (exists $data->{wave}) {
        print "✅ FOUND 'wave' key in response!\n";
        print "Wave results: " . scalar(@{$data->{wave}->{results} || []}) . " items\n";
        print "Wave total: " . ($data->{wave}->{total} || 0) . "\n\n";

        if ($data->{wave}->{results} && @{$data->{wave}->{results}}) {
            print "First wave result:\n";
            print Dumper($data->{wave}->{results}->[0]);
        }
    } else {
        print "❌ 'wave' key NOT found in response with type=all\n";
        print "Available keys: " . join(', ', sort keys %$data) . "\n";
    }

    print "\n";

} else {
    print "ERROR: " . $res->status_line . "\n";
    print $res->content . "\n";
}

# Test 2: Search with type=wave specifically
print "=" x 80 . "\n";
print "TEST 2: Search with type=wave specifically for 'rock'\n";
print "=" x 80 . "\n";

my $search_url_wave = "$base_url/search?" . join('&',
    'text=' . $query,
    'type=wave',
    'page=0',
    'nocorrect=true'
);

print "URL: $search_url_wave\n\n";

$req = HTTP::Request->new(GET => $search_url_wave);
$req->header('Authorization' => "OAuth $token");

$res = $ua->request($req);
if ($res->is_success) {
    my $data = decode_json($res->content);

    print "Keys in response: " . join(', ', sort keys %$data) . "\n\n";

    if (exists $data->{wave}) {
        print "✅ Found 'wave' in type=wave response\n";
        print "Wave results count: " . scalar(@{$data->{wave}->{results} || []}) . "\n";
        print "Wave total: " . ($data->{wave}->{total} || 0) . "\n\n";

        if ($data->{wave}->{results} && @{$data->{wave}->{results}}) {
            print "First wave:\n";
            print Dumper($data->{wave}->{results}->[0]);

            print "\n\nAll waves returned:\n";
            foreach my $i (0 .. @{$data->{wave}->{results}} - 1) {
                my $wave = $data->{wave}->{results}->[$i];
                printf "  [%d] id=%s, title=%s, type=%s\n",
                    $i,
                    $wave->{id} || 'N/A',
                    $wave->{title} || 'N/A',
                    $wave->{type} || 'N/A';
            }
        }
    } else {
        print "Response keys: " . join(', ', sort keys %$data) . "\n";
    }
} else {
    print "ERROR: " . $res->status_line . "\n";
    print $res->content . "\n";
}

print "\n" . "=" x 80 . "\n";
print "CONCLUSION\n";
print "=" x 80 . "\n";
print "Wave support: Check output above to determine if wave type is supported\n";
