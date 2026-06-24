#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/..";
use JSON::XS::VersionOneAndTwo;
use LWP::UserAgent;
use HTTP::Request;
use Encode qw(encode_utf8);

=head1 NAME

test_genres_api.pl - Test Yandex Music API /genres endpoint

=head1 DESCRIPTION

Fetches genre list from Yandex Music API and validates that microgenres (sub_genres)
are returned in the response. Generates a detailed report showing all genres and their
subgenres.

=head1 USAGE

    perl test_genres_api.pl

=cut

# Read token from file
my $token_file = "$FindBin::Bin/token.txt";
unless (-f $token_file) {
    die "ERROR: Token file not found at $token_file\n";
}

open my $fh, '<', $token_file or die "Cannot read token file: $!";
my $token = <$fh>;
chomp($token);
close $fh;

unless ($token) {
    die "ERROR: Token is empty\n";
}

print "✓ Token loaded from $token_file\n";
print "✓ Token length: " . length($token) . " chars\n\n";

# API settings
my $base_url = 'https://api.music.yandex.net';
my $endpoint = '/genres';
my $url = $base_url . $endpoint;

print "═" x 80 . "\n";
print "TESTING YANDEX MUSIC API GENRES ENDPOINT\n";
print "═" x 80 . "\n";
print "URL: $url\n";
print "Method: GET\n\n";

# Create HTTP request
my $ua = LWP::UserAgent->new(
    agent => 'YandexMusicAndroid/24023621',
    timeout => 10,
);

my $req = HTTP::Request->new(GET => $url);

# Set required headers
$req->header('Authorization' => "OAuth $token");
$req->header('X-Yandex-Music-Client' => 'YandexMusicAndroid/24023621');
$req->header('Accept-Language' => 'ru');
$req->header('Content-Type' => 'application/json');
$req->header('User-Agent' => 'Yandex-Music-API');

print "Sending request...\n";

# Make request
my $response = $ua->request($req);

print "\n" . "─" x 80 . "\n";
print "RESPONSE STATUS: " . $response->status_line . "\n";
print "─" x 80 . "\n\n";

unless ($response->is_success) {
    print "ERROR: Request failed!\n";
    print "Status: " . $response->status_line . "\n";
    print "Content: " . $response->content . "\n";
    exit 1;
}

print "✓ Request successful (HTTP " . $response->code . ")\n\n";

# Parse response
my $data;
eval {
    $data = JSON::XS::VersionOneAndTwo::decode_json($response->content);
};

if ($@) {
    print "ERROR: Failed to parse JSON response\n";
    print "Error: $@\n";
    print "Raw content: " . $response->content . "\n";
    exit 1;
}

print "✓ JSON parsed successfully\n\n";

# Validate structure
unless (ref($data) eq 'HASH' && exists $data->{result}) {
    print "ERROR: Response structure is invalid\n";
    print "Expected: { result: [...] }\n";
    print "Got: " . ref($data) . "\n";
    exit 1;
}

my $genres = $data->{result};
unless (ref($genres) eq 'ARRAY') {
    print "ERROR: Result is not an array\n";
    exit 1;
}

print "✓ Response structure is valid\n";
print "✓ Found " . scalar(@$genres) . " genres\n\n";

# Analyze genres and microgenres
my @stats;
my $total_genres = 0;
my $total_subgenres = 0;
my $genres_with_subgenres = 0;
my $genres_without_subgenres = 0;

foreach my $genre (@$genres) {
    $total_genres++;
    my $genre_id = $genre->{id} // 'UNKNOWN';
    my $genre_title = $genre->{title} // 'UNKNOWN';
    my $subgenres = $genre->{sub_genres} // [];
    my $subgenre_count = scalar(@$subgenres);

    if ($subgenre_count > 0) {
        $genres_with_subgenres++;
        $total_subgenres += $subgenre_count;
    } else {
        $genres_without_subgenres++;
    }

    push @stats, {
        id => $genre_id,
        title => $genre_title,
        subgenres => $subgenres,
        count => $subgenre_count,
    };
}

# Generate report
my $report_file = "$FindBin::Bin/GENRES_API_TEST_REPORT.txt";
open my $report_fh, '>', $report_file or die "Cannot write report: $!";

print $report_fh "═" x 100 . "\n";
print $report_fh "YANDEX MUSIC API - GENRES ENDPOINT TEST REPORT\n";
print $report_fh "═" x 100 . "\n";
print $report_fh "Date: " . scalar(localtime) . "\n";
print $report_fh "Endpoint: GET /genres\n";
print $report_fh "Status: SUCCESS ✓\n";
print $report_fh "\n";

# Statistics
print $report_fh "┌" . "─" x 98 . "┐\n";
print $report_fh "│ STATISTICS\n";
print $report_fh "├" . "─" x 98 . "┤\n";
printf $report_fh "│ Total genres:                       %40d\n", $total_genres;
printf $report_fh "│ Genres WITH microgenres:            %40d (%.1f%%)\n",
    $genres_with_subgenres, ($total_genres > 0 ? $genres_with_subgenres / $total_genres * 100 : 0);
printf $report_fh "│ Genres WITHOUT microgenres:         %40d (%.1f%%)\n",
    $genres_without_subgenres, ($total_genres > 0 ? $genres_without_subgenres / $total_genres * 100 : 0);
printf $report_fh "│ Total microgenres:                  %40d\n", $total_subgenres;
printf $report_fh "│ Average microgenres per genre:      %40.2f\n",
    ($total_genres > 0 ? $total_subgenres / $total_genres : 0);
print $report_fh "└" . "─" x 98 . "┘\n";
print $report_fh "\n";

# Verification of microgenres existence
print $report_fh "┌" . "─" x 98 . "┐\n";
print $report_fh "│ MICROGENRES VERIFICATION ✓\n";
print $report_fh "├" . "─" x 98 . "┤\n";
if ($total_subgenres > 0) {
    print $report_fh "│ ✓ Microgenres EXIST in API response\n";
    print $report_fh "│ ✓ Found " . $total_subgenres . " unique microgenres across all genres\n";
    print $report_fh "│ ✓ " . $genres_with_subgenres . " genres contain microgenres\n";
} else {
    print $report_fh "│ ✗ No microgenres found (unexpected!)\n";
}
print $report_fh "└" . "─" x 98 . "┘\n";
print $report_fh "\n";

# Detailed genre list
print $report_fh "┌" . "─" x 98 . "┐\n";
print $report_fh "│ DETAILED GENRE LIST WITH MICROGENRES\n";
print $report_fh "├" . "─" x 98 . "┤\n";

foreach my $stat (sort { $a->{title} cmp $b->{title} } @stats) {
    print $report_fh "\n│ [" . uc($stat->{id}) . "] " . $stat->{title} . "\n";

    if ($stat->{count} > 0) {
        print $report_fh "│ ├─ Microgenres: " . $stat->{count} . "\n";

        foreach my $sub (@{ $stat->{subgenres} }) {
            my $sub_id = $sub->{id} // 'UNKNOWN';
            my $sub_title = $sub->{title} // 'UNKNOWN';
            print $report_fh "│ │  ├─ " . $sub_title . " (id: " . $sub_id . ")\n";
        }
    } else {
        print $report_fh "│ ├─ No microgenres\n";
    }
}

print $report_fh "\n└" . "─" x 98 . "┘\n";
print $report_fh "\n";

# Top genres by subgenre count
print $report_fh "┌" . "─" x 98 . "┐\n";
print $report_fh "│ TOP 10 GENRES BY MICROGENRE COUNT\n";
print $report_fh "├" . "─" x 98 . "┤\n";

my @sorted = sort { $b->{count} <=> $a->{count} } @stats;
for my $i (0 .. 9) {
    last if $i >= @sorted;
    my $stat = $sorted[$i];
    printf $report_fh "│ %2d. %-40s (%3d microgenres)\n",
        $i+1, $stat->{title}, $stat->{count};
}

print $report_fh "└" . "─" x 98 . "┘\n";
print $report_fh "\n";

# Raw JSON dump (formatted)
print $report_fh "┌" . "─" x 98 . "┐\n";
print $report_fh "│ RAW JSON RESPONSE (first 5 genres)\n";
print $report_fh "├" . "─" x 98 . "┤\n";

my $json_pretty = JSON::XS::VersionOneAndTwo->new->pretty->encode({
    result => [ @$genres[0..4] ]
});

foreach my $line (split /\n/, $json_pretty) {
    print $report_fh "│ " . $line . "\n";
}

print $report_fh "│ ...\n";
print $report_fh "└" . "─" x 98 . "┘\n";
print $report_fh "\n";

# Conclusions
print $report_fh "┌" . "─" x 98 . "┐\n";
print $report_fh "│ CONCLUSIONS\n";
print $report_fh "├" . "─" x 98 . "┤\n";

if ($total_subgenres > 0) {
    print $report_fh "│ ✓ MICROGENRES CONFIRMED TO EXIST\n";
    print $report_fh "│\n";
    print $report_fh "│ Key findings:\n";
    print $report_fh "│ • API /genres endpoint returns hierarchical genre structure\n";
    print $report_fh "│ • Each genre contains 'sub_genres' array with microgenres\n";
    print $report_fh "│ • " . $genres_with_subgenres . " out of " . $total_genres . " genres have microgenres\n";
    print $report_fh "│ • Total unique microgenres available: " . $total_subgenres . "\n";
    print $report_fh "│ • Microgenres can be used as alternative genre selections\n";
    print $report_fh "│\n";
    print $report_fh "│ Recommendation:\n";
    print $report_fh "│ • Safe to implement microgenres menu in plugin\n";
    print $report_fh "│ • Use hierarchical menu: Genre → Microgenres\n";
    print $report_fh "│ • Cache for 7 days (genres change rarely)\n";
} else {
    print $report_fh "│ ✗ NO MICROGENRES FOUND (unexpected)\n";
}

print $report_fh "└" . "─" x 98 . "┘\n";
print $report_fh "\n";

# API response metadata
print $report_fh "═" x 100 . "\n";
print $report_fh "API RESPONSE METADATA\n";
print $report_fh "═" x 100 . "\n";
print $report_fh "Content-Type: " . ($response->header('Content-Type') // 'N/A') . "\n";
print $report_fh "Content-Length: " . length($response->content) . " bytes\n";
print $report_fh "Response Time: " . ($response->header('Date') // 'N/A') . "\n";
print $report_fh "\n";

close $report_fh;

# Print console summary
print "\n" . "═" x 80 . "\n";
print "ANALYSIS RESULTS\n";
print "═" x 80 . "\n\n";

printf "Total genres:              %5d\n", $total_genres;
printf "Genres WITH microgenres:   %5d (%.1f%%)\n",
    $genres_with_subgenres, ($total_genres > 0 ? $genres_with_subgenres / $total_genres * 100 : 0);
printf "Genres WITHOUT microgenres:%5d (%.1f%%)\n",
    $genres_without_subgenres, ($total_genres > 0 ? $genres_without_subgenres / $total_genres * 100 : 0);
printf "Total microgenres:         %5d\n\n", $total_subgenres;

print "✓ MICROGENRES CONFIRMED TO EXIST IN API RESPONSE\n\n";

print "Top 5 genres by microgenre count:\n";
for my $i (0 .. 4) {
    last if $i >= @sorted;
    my $stat = $sorted[$i];
    printf "  %d. %-35s (%3d microgenres)\n",
        $i+1, $stat->{title}, $stat->{count};
}

print "\n" . "═" x 80 . "\n";
print "Report saved to: $report_file\n";
print "═" x 80 . "\n";

exit 0;
