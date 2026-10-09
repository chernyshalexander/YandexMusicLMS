#!/usr/bin/perl
# Test vibe wheel run flow: rotor/session/new + wheel/new with seeds and feedbacks

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib '/home/chernysh/Projects/slimserver/CPAN';
use lib '/home/chernysh/Projects/slimserver/CPAN/arch/5.38';
use lib '/home/chernysh/Projects/slimserver/CPAN/arch/5.38/x86_64-linux-thread-multi';
use lib "$Bin/..";
use lib "$Bin";

use JSON::XS;
use Data::Dumper;
use Time::HiRes qw(time);
use TokenHelper;

binmode(STDOUT, ':utf8');
binmode(STDERR, ':utf8');

my $token = TokenHelper::get_token();
die "No token found in test/token.txt\n" unless $token;

print "=" x 70 . "\n";
print "TEST: Vibe Wheel Run Flow (rotor/session/new + wheel/new)\n";
print "=" x 70 . "\n\n";

# ============================================================================
# STEP 1: Fetch initial default wheel to get wheelId and VIEW items
# ============================================================================
print "STEP 1: Fetch initial wheel (user:onyourwave)\n";
print "-" x 70 . "\n";

my $initial_wheel = call_wheel_new(['user:onyourwave'], undef, $token);
die "Failed to fetch initial wheel\n" unless $initial_wheel;

my $initial_wheel_id = $initial_wheel->{wheelId} // 'UNKNOWN';
print "Initial wheelId: $initial_wheel_id\n";
print "Items count: " . scalar(@{ $initial_wheel->{items} // [] }) . "\n";

my @view_feedbacks;
my $pos = 0;
foreach my $item (@{ $initial_wheel->{items} // [] }) {
    my $item_pos = $pos++;
    next unless $item->{type} && $item->{type} eq 'WAVE';
    my $wave = $item->{data}{wave} // {};
    my $seeds = $wave->{seeds} // [];
    next unless @$seeds;

    my $item_id = $item->{id} || $seeds->[0];
    push @view_feedbacks, {
        wheelId   => $initial_wheel_id,
        timestamp => int(time() * 1000),
        eventType => 'VIEW',
        item      => { type => 'WAVE', id => $item_id },
        position  => $item_pos,
    };
    printf("  [%d] %s (id: %s, seeds: %s)\n", $item_pos, $wave->{name} || 'unnamed', $item_id, join(',', @$seeds));
}
print "Accumulated " . scalar(@view_feedbacks) . " VIEW feedbacks\n\n";

# ============================================================================
# STEP 2: Start wave session (POST rotor/session/new)
# ============================================================================
my $target_seed = 'diversity:discover';
print "STEP 2: Start wave session on seed [$target_seed]\n";
print "-" x 70 . "\n";

my $session_res = call_rotor_session_new([$target_seed], $token);
if ($session_res && $session_res->{radioSessionId}) {
    print "✓ Successfully created rotor session:\n";
    print "  radioSessionId: " . $session_res->{radioSessionId} . "\n";
    print "  batchId: " . ($session_res->{batchId} // 'none') . "\n";
    my $tracks_count = scalar(@{ $session_res->{sequence} // [] });
    print "  Tracks in sequence: $tracks_count\n";
    if ($tracks_count > 0) {
        my $t = $session_res->{sequence}[0]{track};
        printf("  First track: %s - %s (id: %s)\n",
            join(', ', map { $_->{name} } @{ $t->{artists} // [] }),
            $t->{title} // 'unknown',
            $t->{id} // 'none'
        );
    }
} else {
    warn "Warning: rotor_session_new returned error or unexpected structure\n";
}
print "\n";

# ============================================================================
# STEP 3: Rebuild wheel around launched wave (POST wheel/new with same seed + feedbacks)
# ============================================================================
print "STEP 3: Rebuild wheel around launched wave (seed: $target_seed)\n";
print "-" x 70 . "\n";

# Add CLICK feedback for target seed
my @all_feedbacks = @view_feedbacks;
push @all_feedbacks, {
    wheelId   => $initial_wheel_id,
    timestamp => int(time() * 1000),
    eventType => 'CLICK',
    item      => { type => 'WAVE', id => $target_seed },
    position  => 0,
};

print "Sending wheel/new with " . scalar(@all_feedbacks) . " feedbacks...\n";
my $rebuilt_wheel = call_wheel_new([$target_seed], \@all_feedbacks, $token);
die "Failed to fetch rebuilt wheel\n" unless $rebuilt_wheel;

my $rebuilt_wheel_id = $rebuilt_wheel->{wheelId} // 'UNKNOWN';
print "Rebuilt wheelId: $rebuilt_wheel_id\n";
print "Items count: " . scalar(@{ $rebuilt_wheel->{items} // [] }) . "\n";

my @rebuilt_waves;
foreach my $item (@{ $rebuilt_wheel->{items} // [] }) {
    next unless $item->{type} && $item->{type} eq 'WAVE';
    my $wave = $item->{data}{wave} // {};
    my $seeds = $wave->{seeds} // [];
    push @rebuilt_waves, {
        name  => $wave->{name} || $item->{id} || 'unnamed',
        seeds => $seeds,
        id    => $item->{id},
    };
    printf("  - %s (id: %s, seeds: %s)\n", $wave->{name} || 'unnamed', $item->{id} // '', join(',', @$seeds));
}

print "\n";
print "=" x 70 . "\n";
print "VERIFICATION RESULTS:\n";
print "-" x 70 . "\n";

if ($initial_wheel_id ne $rebuilt_wheel_id) {
    print "✓ SUCCESS: wheelId changed ($initial_wheel_id -> $rebuilt_wheel_id)\n";
} else {
    print "- INFO: wheelId stayed the same ($initial_wheel_id)\n";
}

if (@rebuilt_waves > 0) {
    print "✓ SUCCESS: Rebuilt wheel returned " . scalar(@rebuilt_waves) . " wave items\n";
} else {
    print "✗ ERROR: No wave items found in rebuilt wheel\n";
}

print "=" x 70 . "\n";

# ============================================================================
# API HELPERS (curl-based for standalone test runner)
# ============================================================================

sub call_wheel_new {
    my ($seeds, $feedbacks, $auth_token) = @_;

    my $url = 'https://api.music.yandex.net/wheel/new?language=ru';
    my $body = {
        context => {
            type => 'WAVE',
            data => {
                seeds => $seeds,
            },
        },
    };
    $body->{feedbacks} = $feedbacks if $feedbacks && @$feedbacks;

    my $json_payload = JSON::XS->new->utf8->encode($body);
    my $payload_escaped = $json_payload;
    $payload_escaped =~ s/'/'\\''/g;

    my $cmd = "curl -s -X POST '$url' " .
              "-H 'Authorization: OAuth $auth_token' " .
              "-H 'Content-Type: application/json' " .
              "-H 'X-Yandex-Music-Client: YandexMusicAndroid/24026472' " .
              "-d '$payload_escaped'";

    my $res = `$cmd`;
    return eval { JSON::XS->new->utf8->decode($res) };
}

sub call_rotor_session_new {
    my ($seeds, $auth_token) = @_;

    my $url = 'https://api.music.yandex.net/rotor/session/new';
    my $body = {
        seeds                   => $seeds,
        queue                   => [],
        includeTracksInResponse => \1,
        includeWaveModel        => \1,
        interactive             => \1,
    };

    my $json_payload = JSON::XS->new->utf8->encode($body);
    my $payload_escaped = $json_payload;
    $payload_escaped =~ s/'/'\\''/g;

    my $cmd = "curl -s -X POST '$url' " .
              "-H 'Authorization: OAuth $auth_token' " .
              "-H 'Content-Type: application/json' " .
              "-H 'X-Yandex-Music-Client: YandexMusicAndroid/24026472' " .
              "-d '$payload_escaped'";

    my $res = `$cmd`;
    my $parsed = eval { JSON::XS->new->utf8->decode($res) };
    return $parsed ? ($parsed->{result} // $parsed) : undef;
}
