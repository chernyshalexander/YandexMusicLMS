#!/usr/bin/perl
# Test Yandex search API: actual page sizes, total counts, and pagination behavior

use strict;
use warnings;
use lib '/usr/share/squeezeboxserver/CPAN';
use lib '/usr/share/squeezeboxserver/CPAN/arch/5.38';
use lib '/usr/share/squeezeboxserver/CPAN/arch/5.38/x86_64-linux-thread-multi';
use JSON::XS;
use LWP::UserAgent;
use HTTP::Request;
use File::Basename 'dirname';
use File::Spec;
use URI::URL qw(url);

my $script_dir = dirname(__FILE__);
my $token_file = File::Spec->catfile($script_dir, 'token.txt');
open my $fh, '<', $token_file or die "Cannot read token file: $!\n";
my $token = do { local $/; <$fh> };
close $fh;
chomp($token);

my $ua = LWP::UserAgent->new(timeout => 15);

sub search {
    my ($query, $type, $page, $page_size) = @_;
    $page //= 0;

    my %params = (
        'text'             => $query,
        'type'             => $type,
        'page'             => $page,
        'nocorrect'        => 'False',
        'playlist-in-best' => 'True',
    );
    $params{'page-size'} = $page_size if defined $page_size;

    my $u = url("https://api.music.yandex.net/search");
    $u->query_form(%params);

    my $req = HTTP::Request->new(GET => $u->as_string);
    $req->header('Authorization' => "OAuth $token");
    $req->header('User-Agent' => 'Yandex-Music-API');

    my $res = $ua->request($req);
    return undef unless $res->is_success;

    my $data = eval { decode_json($res->content) };
    return $data ? $data->{result} : undef;
}

my $QUERY = 'deep purple';

print "=" x 70 . "\n";
print "Yandex Search Pagination Test: '$QUERY'\n";
print "=" x 70 . "\n\n";

# --- Test 1: Default behavior (no page-size param) ---
print "=== TEST 1: Default page-size (no param sent) ===\n\n";

for my $type (qw(artist album track playlist)) {
    my $result = search($QUERY, $type, 0, undef);
    my $key = $type . 's';
    my $data = $result->{$key};

    my $total   = $data ? ($data->{total}   // 'n/a') : 'no data';
    my $perPage = $data ? ($data->{perPage} // 'n/a') : 'no data';
    my $count   = $data && $data->{results} ? scalar(@{$data->{results}}) : 0;

    printf "%-10s  total=%-5s  perPage=%-5s  returned=%d\n",
        $type, $total, $perPage, $count;
}

# --- Test 2: Different page-size values ---
print "\n=== TEST 2: Effect of page-size param on 'artist' type ===\n\n";

for my $ps (undef, 5, 10, 20, 50, 100) {
    my $label = defined $ps ? $ps : 'none';
    my $result = search($QUERY, 'artist', 0, $ps);
    my $data = $result->{artists};

    my $total   = $data ? ($data->{total}   // 'n/a') : 'ERROR';
    my $perPage = $data ? ($data->{perPage} // 'n/a') : 'ERROR';
    my $count   = $data && $data->{results} ? scalar(@{$data->{results}}) : 0;

    printf "page-size=%-6s  total=%-5s  perPage=%-5s  returned=%d\n",
        $label, $total, $perPage, $count;
}

# --- Test 3: Pagination pages for 'artist' ---
print "\n=== TEST 3: Pages 0,1,2 for 'artist' (default page-size) ===\n\n";

for my $page (0, 1, 2, 3) {
    my $result = search($QUERY, 'artist', $page, undef);
    my $data = $result->{artists};

    my $total = $data ? ($data->{total} // 'n/a') : 'ERROR';
    my $count = $data && $data->{results} ? scalar(@{$data->{results}}) : 0;

    my @names;
    if ($data && $data->{results}) {
        @names = map { $_->{name} // '???' } @{$data->{results}};
    }

    printf "page=%d  total=%-5s  returned=%-3d  names: %s\n",
        $page, $total, $count, join(', ', @names) || '(none)';
}

# --- Test 4: Same for 'album' ---
print "\n=== TEST 4: Pages 0,1 for 'album' (default page-size) ===\n\n";

for my $page (0, 1) {
    my $result = search($QUERY, 'album', $page, undef);
    my $data = $result->{albums};

    my $total = $data ? ($data->{total} // 'n/a') : 'ERROR';
    my $count = $data && $data->{results} ? scalar(@{$data->{results}}) : 0;

    my @names;
    if ($data && $data->{results}) {
        @names = map { $_->{title} // '???' } @{$data->{results}};
    }

    printf "page=%d  total=%-5s  returned=%-3d  first title: %s\n",
        $page, $total, $count, $names[0] // '(none)';
}

# --- Test 5: Same for 'track' ---
print "\n=== TEST 5: Pages 0,1 for 'track' (default page-size) ===\n\n";

for my $page (0, 1) {
    my $result = search($QUERY, 'track', $page, undef);
    my $data = $result->{tracks};

    my $total = $data ? ($data->{total} // 'n/a') : 'ERROR';
    my $count = $data && $data->{results} ? scalar(@{$data->{results}}) : 0;

    printf "page=%d  total=%-5s  returned=%d\n",
        $page, $total, $count;
}

print "\n" . "=" x 70 . "\n";
print "Done.\n";
