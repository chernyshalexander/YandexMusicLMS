#!/usr/bin/perl
# Test hypothesis: reshuffle produces different wave list

use strict;
use warnings;
use utf8;

use JSON;
use Data::Dumper;

# Read token
my $token_file = '/home/chernysh/Projects/yandex/test/token.txt';
my $token = do {
    open my $fh, '<', $token_file or die "Cannot read $token_file: $!";
    chomp(my $t = <$fh>);
    close $fh;
    $t;
};

die "No token found\n" unless $token;

print "=" x 70 . "\n";
print "TEST: Vibe Wheel Reshuffle - Different Waves?\n";
print "=" x 70 . "\n\n";

# ============================================================================
# STEP 1: Get wheel for default case (user:onyourwave)
# ============================================================================

print "STEP 1: Fetch wheel for DEFAULT case (user:onyourwave)\n";
print "-" x 70 . "\n";

my $default_wheel = fetch_wheel('user:onyourwave', $token);

if (!$default_wheel) {
    die "Failed to fetch default wheel\n";
}

print "Got wheel with " . scalar(@{ $default_wheel->{items} }) . " items\n";

my ($default_waves, $default_reshuffle_seeds) = extract_waves_and_reshuffle($default_wheel);

print "  Waves (regular): " . scalar(@$default_waves) . "\n";
foreach my $wave (@$default_waves) {
    printf("    - %s (seeds: %s)\n", $wave->{name}, join(', ', @{ $wave->{seeds} }));
}

if ($default_reshuffle_seeds) {
    print "  Reshuffle seeds: " . join(', ', @$default_reshuffle_seeds) . "\n";
} else {
    die "ERROR: No reshuffle found in default wheel\n";
}

print "\n";

# ============================================================================
# STEP 2: Perform reshuffle (call wheel with reshuffle seeds)
# ============================================================================

print "STEP 2: Perform RESHUFFLE\n";
print "-" x 70 . "\n";

print "Using reshuffle seeds: " . join(', ', @$default_reshuffle_seeds) . "\n\n";

my $reshuffle_wheel = fetch_wheel_with_seeds($default_reshuffle_seeds, $token);

if (!$reshuffle_wheel) {
    die "Failed to fetch reshuffle wheel\n";
}

print "Got wheel with " . scalar(@{ $reshuffle_wheel->{items} }) . " items\n";

my ($reshuffle_waves, $new_reshuffle_seeds) = extract_waves_and_reshuffle($reshuffle_wheel);

print "  Waves (regular): " . scalar(@$reshuffle_waves) . "\n";
foreach my $wave (@$reshuffle_waves) {
    printf("    - %s (seeds: %s)\n", $wave->{name}, join(', ', @{ $wave->{seeds} }));
}

if ($new_reshuffle_seeds) {
    print "  New reshuffle seeds: " . join(', ', @$new_reshuffle_seeds) . "\n";
} else {
    print "  (No new reshuffle found)\n";
}

print "\n";

# ============================================================================
# STEP 3: Compare lists
# ============================================================================

print "STEP 3: COMPARISON\n";
print "-" x 70 . "\n";

my $waves_are_different = compare_wave_lists($default_waves, $reshuffle_waves);

if ($waves_are_different) {
    print "✓ SUCCESS: Reshuffle produces DIFFERENT wave list!\n";
    print "  Default had " . scalar(@$default_waves) . " waves\n";
    print "  Reshuffle has " . scalar(@$reshuffle_waves) . " waves\n\n";

    print "  Waves that disappeared:\n";
    my %reshuffle_names = map { $_->{name} => 1 } @$reshuffle_waves;
    foreach my $wave (@$default_waves) {
        if (!$reshuffle_names{$wave->{name}}) {
            printf("    - %s\n", $wave->{name});
        }
    }

    print "\n  Waves that appeared:\n";
    my %default_names = map { $_->{name} => 1 } @$default_waves;
    foreach my $wave (@$reshuffle_waves) {
        if (!$default_names{$wave->{name}}) {
            printf("    - %s\n", $wave->{name});
        }
    }
} else {
    print "✗ HYPOTHESIS REJECTED: Wave lists are the SAME\n";
    print "  This suggests reshuffle might not change the list,\n";
    print "  or we need to analyze the data differently.\n";
}

print "\n";

# ============================================================================
# CONCLUSION
# ============================================================================

print "=" x 70 . "\n";
print "CONCLUSION:\n";
if ($waves_are_different) {
    print "Reshuffle DOES produce different waves.\n";
    print "Live menu update on reshuffle is feasible!\n";
} else {
    print "Reshuffle does NOT produce different waves.\n";
    print "Waves may be generated dynamically during playback.\n";
}
print "=" x 70 . "\n";

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

sub fetch_wheel {
    my ($seeds_str, $token) = @_;

    my $url = "https://api.music.yandex.net/rotor/wheel/new?seeds=$seeds_str";
    my $cmd = qq(curl -s -X GET "$url" ) .
              qq(-H "Authorization: OAuth $token");

    my $response = `$cmd`;

    if (!$response) {
        print "ERROR: Empty response from API\n";
        return undef;
    }

    my $data = eval { JSON::XS->new->decode($response) };
    if ($@) {
        print "ERROR: Failed to parse JSON: $@\n";
        print "Response: $response\n";
        return undef;
    }

    if ($data->{error}) {
        print "ERROR: API error: $data->{error}\n";
        return undef;
    }

    return $data->{result};
}

sub fetch_wheel_with_seeds {
    my ($seeds_arr, $token) = @_;

    my $seeds_str = join(',', @$seeds_arr);
    return fetch_wheel($seeds_str, $token);
}

sub extract_waves_and_reshuffle {
    my ($wheel) = @_;

    my @waves;
    my $reshuffle_seeds;

    foreach my $item (@{ $wheel->{items} // [] }) {
        next unless $item->{type} && $item->{type} eq 'WAVE';

        my $is_reshuffle = ($item->{style} // '') eq 'CONTROL_ACCENT';
        my $wave = $item->{data}{wave} // {};
        my $seeds = $wave->{seeds} // [];

        next unless @$seeds;

        my $name = $is_reshuffle
            ? 'RESHUFFLE'
            : ($wave->{name} || $item->{id} || 'Unknown');

        if ($is_reshuffle) {
            $reshuffle_seeds = $seeds;
        } else {
            push @waves, {
                name => $name,
                seeds => $seeds,
                id => $item->{id},
            };
        }
    }

    return (\@waves, $reshuffle_seeds);
}

sub compare_wave_lists {
    my ($list1, $list2) = @_;

    return 0 unless $list1 && $list2;
    return 0 if scalar(@$list1) != scalar(@$list2);

    my %names1 = map { $_->{name} => 1 } @$list1;
    my %names2 = map { $_->{name} => 1 } @$list2;

    # Check if they have same wave names
    foreach my $name (keys %names1) {
        return 1 if !$names2{$name};  # Name in list1 but not in list2
    }

    foreach my $name (keys %names2) {
        return 1 if !$names1{$name};  # Name in list2 but not in list1
    }

    return 0;  # Same waves in both lists
}
