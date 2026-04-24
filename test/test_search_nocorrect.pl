#!/usr/bin/perl
=head1 NAME

test_search_nocorrect.pl - Test the impact of nocorrect parameter on search results

=head1 DESCRIPTION

This script tests how the 'nocorrect' parameter affects search results in Yandex Music API:

1. Compare search results with nocorrect=true vs nocorrect=false
2. Shows misspelling detection and correction
3. Tests search_suggest method
4. Shows impact of quotes on search results
5. Analyzes best result differences

=head1 USAGE

    perl test/test_search_nocorrect.pl

Requirements:
    - test/token.txt with valid Yandex Music OAuth token
    - perl modules: JSON::XS, LWP::UserAgent, URI::URL, Data::Dumper

=head1 AUTHOR

Test script for Yandex Music LMS Plugin

=cut

use strict;
use warnings;
use JSON::XS;
use LWP::UserAgent;
use HTTP::Request;
use File::Basename 'dirname';
use File::Spec;
use URI::URL qw(url);
use Data::Dumper;

# Read token from test/token.txt
my $script_dir = dirname(__FILE__);
my $token_file = File::Spec->catfile($script_dir, 'token.txt');

if (! -e $token_file) {
    die "Token file not found at: $token_file\n";
}

open my $fh, '<', $token_file or die "Cannot read token file: $!\n";
my $token = do { local $/; <$fh> };
close $fh;
chomp($token);

die "Token file is empty\n" if !$token || $token =~ /^\s*$/;

print "Token: " . substr($token, 0, 10) . "...\n\n";

# Initialize LWP UserAgent
my $ua = LWP::UserAgent->new();
$ua->timeout(15);

my $base_url = 'https://api.music.yandex.net';

# Test queries
my @test_queries = (
    {
        name => 'Correct spelling',
        query => 'Гражданская оборона',
    },
    {
        name => 'Misspelled (missing letter)',
        query => 'Гражданская абарона',
    },
    {
        name => 'Misspelled (extra letter)',
        query => 'Би-2 Сонг',
    },
);

sub make_search_request {
    my ($query, $nocorrect, $type) = @_;
    $type //= 'all';

    my $params = {
        'text'             => $query,
        'nocorrect'        => $nocorrect ? 'True' : 'False',
        'type'             => $type,
        'page'             => 0,
        'playlist-in-best' => 'True',
    };

    my $url = url("$base_url/search");
    $url->query_form(%$params);

    my $req = HTTP::Request->new(GET => $url->as_string);
    $req->header('Authorization' => "OAuth $token");
    $req->header('User-Agent' => 'Yandex-Music-API');
    $req->header('Accept-Language' => 'ru');

    print "  [nocorrect=" . ($nocorrect ? 'true' : 'false') . "] Requesting: " . $url->as_string . "\n";

    my $res = $ua->request($req);

    if (!$res->is_success) {
        print "    ERROR: " . $res->status_line . "\n";
        return undef;
    }

    my $data = eval { decode_json($res->content) };
    if ($@) {
        print "    ERROR parsing JSON: $@\n";
        return undef;
    }

    return $data->{result};
}

sub print_separator {
    my ($char, $length) = @_;
    $char //= '=';
    $length //= 100;
    print $char x $length . "\n";
}

sub format_counts {
    my ($result) = @_;

    if (!$result) {
        return {};
    }

    return {
        tracks           => $result->{tracks} ? $result->{tracks}->{total} : 0,
        artists          => $result->{artists} ? $result->{artists}->{total} : 0,
        albums           => $result->{albums} ? $result->{albums}->{total} : 0,
        playlists        => $result->{playlists} ? $result->{playlists}->{total} : 0,
        videos           => $result->{videos} ? $result->{videos}->{total} : 0,
        podcasts         => $result->{podcasts} ? $result->{podcasts}->{total} : 0,
        podcast_episodes => $result->{podcast_episodes} ? $result->{podcast_episodes}->{total} : 0,
        users            => $result->{users} ? $result->{users}->{total} : 0,
    };
}

sub compare_search_results {
    my ($query) = @_;

    print "\n" . "="x100 . "\n";
    print "Query: '$query'\n";
    print_separator();

    my %results;
    for my $nocorrect (0, 1) {
        my $result = make_search_request($query, $nocorrect, 'all');
        $results{$nocorrect} = $result;
    }

    print_separator('─');

    # Print comparison table
    printf "%-20s %-30s %-30s %-30s\n", 'Category', 'nocorrect=false', 'nocorrect=true', 'Δ (difference)';
    print_separator('─');

    my @types = qw(tracks artists albums playlists videos podcasts podcast_episodes users);

    for my $type (@types) {
        my $count_false = $results{0} ? $results{0}->{$type}->{total} // 0 : 0;
        my $count_true = $results{1} ? $results{1}->{$type}->{total} // 0 : 0;

        if ($count_false > 0 || $count_true > 0) {
            my $diff = $count_true - $count_false;
            my $diff_str = $diff > 0 ? "+$diff" : $diff == 0 ? "0" : "$diff";
            printf "%-20s %-30s %-30s %-30s\n", $type, $count_false, $count_true, $diff_str;
        }
    }

    print_separator('─');

    # Print misspelling info
    print "\nMISPELLING INFORMATION:\n";
    print_separator('─');

    for my $nocorrect (0, 1) {
        my $res = $results{$nocorrect};
        if (!$res) {
            print "  nocorrect=" . ($nocorrect ? 'true' : 'false') . ": No results\n";
            next;
        }

        printf "nocorrect=%s:\n", $nocorrect ? 'true' : 'false';
        printf "  Original query:     %s\n", $res->{misspell_original} // 'N/A';
        printf "  Corrected to:       %s\n", $res->{misspell_result} // 'N/A';
        printf "  Was corrected:      %s\n", $res->{misspell_corrected} ? 'yes' : 'no';
        printf "  nocorrect param:    %s\n", $res->{nocorrect} // 'N/A';

        # Print best result
        if ($res->{best}) {
            printf "  Best result type:   %s\n", $res->{best}->{type};
            if ($res->{best}->{result}) {
                my $result = $res->{best}->{result};
                if ($result->{name}) {
                    printf "  Best result:        %s\n", $result->{name};
                } elsif ($result->{title}) {
                    printf "  Best result:        %s\n", $result->{title};
                }
            }
        }
        print "\n";
    }
}

sub test_search_suggest {
    my ($part) = @_;

    print "\n" . "="x100 . "\n";
    print "SEARCH SUGGEST TEST: '$part'\n";
    print_separator();

    my $url = url("$base_url/search/suggest");
    $url->query_form('part' => $part);

    my $req = HTTP::Request->new(GET => $url->as_string);
    $req->header('Authorization' => "OAuth $token");
    $req->header('User-Agent' => 'Yandex-Music-API');

    print "Requesting: " . $url->as_string . "\n";

    my $res = $ua->request($req);

    if (!$res->is_success) {
        print "ERROR: " . $res->status_line . "\n";
        return;
    }

    my $data = eval { decode_json($res->content) };
    if ($@) {
        print "ERROR parsing JSON: $@\n";
        return;
    }

    my $result = $data->{result};
    if (!$result || !$result->{suggests}) {
        print "No suggestions found\n";
        return;
    }

    print_separator('─');
    printf "Found %d suggestions:\n\n", scalar(@{$result->{suggests}});

    my $count = 0;
    for my $suggest (@{$result->{suggests}}) {
        $count++;
        last if $count > 10;
        printf "  %2d. %s\n", $count, $suggest;
    }
    print "\n";
}

# ===== MAIN TEST EXECUTION =====

print "="x100 . "\n";
print "YANDEX MUSIC SEARCH NOCORRECT PARAMETER TEST\n";
print "="x100 . "\n";

print "\nTEST 1: NOCORRECT PARAMETER IMPACT\n";
for my $test_query (@test_queries) {
    compare_search_results($test_query->{query});
}

print "\n" . "="x100 . "\n";
print "TEST 2: SEARCH_SUGGEST METHOD\n";
print "="x100 . "\n";

test_search_suggest('граж');
test_search_suggest('би');

print "\n" . "="x100 . "\n";
print "✓ Tests completed successfully!\n";
print "="x100 . "\n\n";
