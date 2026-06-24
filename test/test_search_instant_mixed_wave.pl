#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use Data::Dumper;
use JSON::PP;
use LWP::UserAgent;
use URI::Escape;

my $token_file = 'test/token.txt';
my $token;
if (-f $token_file) {
    open my $fh, '<', $token_file or die "Cannot open $token_file: $!";
    $token = <$fh>;
    chomp $token;
    close $fh;
} else {
    die "Token file not found\n";
}

my $ua = LWP::UserAgent->new(timeout => 10);
my $base_url = 'https://api.music.yandex.ru';

# Test 1: /search/instant/mixed with type=all (no wave)
print "=" x 80 . "\n";
print "TEST 1: /search/instant/mixed with mixed types (including wave)\n";
print "=" x 80 . "\n";

my $query = 'rock';
my $types = 'album,artist,playlist,track,wave,podcast,podcast_episode,clip,concert';

my $url = "$base_url/search/instant/mixed?" . join('&',
    'text=' . uri_escape($query, q{^A-Za-z0-9\-._~}),
    'type=' . uri_escape($types, q{^A-Za-z0-9\-._~}),
    'page=0',
    'pageSize=36',
    'withLikesCount=true',
    'withBestResults=true'
);

print "URL: $base_url/search/instant/mixed?text=$query&type=$types&...\n\n";

my $req = HTTP::Request->new(GET => $url);
$req->header('Authorization' => "OAuth $token");

my $res = $ua->request($req);
if ($res->is_success) {
    my $data = decode_json($res->content);

    print "Response keys: " . join(', ', sort keys %$data) . "\n\n";

    # Check for different content types
    foreach my $type (qw(tracks albums artists playlists podcasts waves clips concerts podcast_episodes)) {
        if (exists $data->{$type}) {
            my $count = 0;
            if (ref($data->{$type}) eq 'ARRAY') {
                $count = scalar(@{$data->{$type}});
            } elsif (ref($data->{$type}) eq 'HASH' && exists $data->{$type}->{results}) {
                $count = scalar(@{$data->{$type}->{results}});
            }
            print "✓ $type: $count items\n";

            # Show details for waves if found
            if ($type eq 'waves' && $count > 0) {
                print "  WAVE structure:\n";
                my $first_wave = ref($data->{$type}) eq 'ARRAY'
                    ? $data->{$type}->[0]
                    : $data->{$type}->{results}->[0];
                print "  Keys: " . join(', ', keys %$first_wave) . "\n";
                if ($first_wave->{id}) { print "  Example ID: $first_wave->{id}\n"; }
                if ($first_wave->{title}) { print "  Example Title: $first_wave->{title}\n"; }
            }
        } else {
            print "✗ $type: NOT found\n";
        }
    }

    print "\n";

} else {
    print "ERROR: " . $res->status_line . "\n";
    print $res->content . "\n";
}

# Test 2: With filter=waves
print "=" x 80 . "\n";
print "TEST 2: /search/instant/mixed with filter=waves\n";
print "=" x 80 . "\n";

$url = "$base_url/search/instant/mixed?" . join('&',
    'text=' . uri_escape($query, q{^A-Za-z0-9\-._~}),
    'type=' . uri_escape($types, q{^A-Za-z0-9\-._~}),
    'page=0',
    'pageSize=36',
    'filter=waves',
    'withLikesCount=true',
    'withBestResults=false'
);

print "URL: (with filter=waves)\n\n";

$req = HTTP::Request->new(GET => $url);
$req->header('Authorization' => "OAuth $token");

$res = $ua->request($req);
if ($res->is_success) {
    my $data = decode_json($res->content);

    if (exists $data->{waves}) {
        print "✓ Found 'waves' key with filter\n";
        print "  Count: " . (ref($data->{waves}) eq 'ARRAY' ? scalar(@{$data->{waves}}) : 'unknown') . "\n";

        if (ref($data->{waves}) eq 'ARRAY' && @{$data->{waves}}) {
            my $first = $data->{waves}->[0];
            print "\nFirst wave details:\n";
            print Dumper($first);
        }
    }
} else {
    print "ERROR: " . $res->status_line . "\n";
}

print "=" x 80 . "\n";
print "CONCLUSION\n";
print "=" x 80 . "\n";
print "Use /search/instant/mixed endpoint with type parameter including 'wave'\n";
