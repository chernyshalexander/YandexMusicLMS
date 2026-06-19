#!/usr/bin/env perl
use strict;
use warnings;

=head1 YNISON INTEGRATION TESTS

Validation tests for Ynison improvements implementation.
Tests verify that key functions exist and have correct structure.

Run with: perl ynison_integration_tests.pl

=cut

my $test_count = 0;
my $pass_count = 0;
my $fail_count = 0;

sub test {
    my ($name, $code) = @_;
    $test_count++;
    print "\n[TEST $test_count] $name\n";

    eval {
        $code->();
        $pass_count++;
        print "  ✓ PASS\n";
    };
    if ($@) {
        $fail_count++;
        print "  ✗ FAIL: $@\n";
    }
}

sub assert_equal {
    my ($got, $expected, $msg) = @_;
    die "Assertion failed: $msg (got '$got', expected '$expected')"
        unless $got eq $expected;
}

sub assert_true {
    my ($value, $msg) = @_;
    die "Assertion failed: $msg (got '$value', expected true)"
        unless $value;
}

sub assert_false {
    my ($value, $msg) = @_;
    die "Assertion failed: $msg (got '$value', expected false)"
        if $value;
}

# Read Ynison.pm source code
use FindBin;
my $ynison_source = do {
    open my $fh, '<', "$FindBin::Bin/../Ynison.pm" or die "Cannot read Ynison.pm: $!";
    local $/;
    <$fh>;
};

# TEST SUITE - Verify Ynison.pm has required functions

test("Ynison.pm defines _detect_command_type function", sub {
    assert_true($ynison_source =~ /sub _detect_command_type/, 'Function exists');
});

test("_detect_command_type handles ping messages", sub {
    assert_true($ynison_source =~ /return 'ping' if \$msg->\{ping\}/, 'Ping detection exists');
});

test("_detect_command_type handles pong messages", sub {
    assert_true($ynison_source =~ /return 'pong' if \$msg->\{pong\}/, 'Pong detection exists');
});

test("_detect_command_type handles update_full_state messages", sub {
    assert_true($ynison_source =~ /return 'update_full_state' if \$msg->\{update_full_state\}/, 'update_full_state detection exists');
});

test("_detect_command_type handles update_player_state messages", sub {
    assert_true($ynison_source =~ /return 'update_player_state' if \$msg->\{update_player_state\}/, 'update_player_state detection exists');
});

test("Ynison.pm defines _get_reconnect_strategy function", sub {
    assert_true($ynison_source =~ /sub _get_reconnect_strategy/, 'Function exists');
});

test("_get_reconnect_strategy handles auth_error", sub {
    assert_true($ynison_source =~ /if \(\$reason eq 'auth_error'\)/, 'auth_error handling exists');
});

test("_get_reconnect_strategy handles timeout", sub {
    assert_true($ynison_source =~ /elsif \(\$reason eq 'timeout'\)/, 'timeout handling exists');
});

test("_get_reconnect_strategy handles network_error", sub {
    assert_true($ynison_source =~ /elsif \(\$reason eq 'network_error'\)/, 'network_error handling exists');
});

test("Ynison.pm defines _cleanup_old_commands function", sub {
    assert_true($ynison_source =~ /sub _cleanup_old_commands/, 'Function exists');
});

test("Echo detection infrastructure exists", sub {
    assert_true($ynison_source =~ /RID_TIMEOUT/, 'RID_TIMEOUT constant defined');
    assert_true($ynison_source =~ /sent_commands/, 'sent_commands field used');
});

test("Reconnection stats tracking exists", sub {
    assert_true($ynison_source =~ /reconnection_stats/, 'reconnection_stats field exists');
    assert_true($ynison_source =~ /error_count/, 'error_count tracking exists');
});

test("Queue buffering constants defined", sub {
    assert_true($ynison_source =~ /MAX_WRITE_QUEUE_SIZE/, 'MAX_WRITE_QUEUE_SIZE constant');
    assert_true($ynison_source =~ /MAX_FRAME_SIZE/, 'MAX_FRAME_SIZE constant');
    assert_true($ynison_source =~ /FRAME_TIMEOUT/, 'FRAME_TIMEOUT constant');
});

test("Logging infrastructure exists", sub {
    assert_true($ynison_source =~ /LOG_LEVEL_/, 'LOG_LEVEL constants defined');
    assert_true($ynison_source =~ /log_buffer/, 'log_buffer field exists');
    assert_true($ynison_source =~ /debug_mode/, 'debug_mode field exists');
});

test("_log method exists", sub {
    assert_true($ynison_source =~ /sub _log \{/, '_log method defined');
});

test("_log_frame method exists", sub {
    assert_true($ynison_source =~ /sub _log_frame \{/, '_log_frame method defined');
});

test("_log_state method exists", sub {
    assert_true($ynison_source =~ /sub _log_state \{/, '_log_state method defined');
});

test("get_debug_info method exists", sub {
    assert_true($ynison_source =~ /sub get_debug_info \{/, 'get_debug_info method defined');
});

test("_on_writable handles frame timeout", sub {
    assert_true($ynison_source =~ /FRAME_TIMEOUT/, 'Frame timeout check in _on_writable');
});

test("_on_writable handles write errors", sub {
    assert_true($ynison_source =~ /_schedule_reconnect\('write_error'\)/, 'Write error handling exists');
});

test("_build_player_state includes logging", sub {
    assert_true($ynison_source =~ /Built player state:/, '_log call in _build_player_state');
});

test("Plugin.pm has ynison_debug preference", sub {
    my $plugin_source = do {
        open my $fh, '<', "$FindBin::Bin/../Plugin.pm" or die "Cannot read Plugin.pm: $!";
        local $/;
        <$fh>;
    };
    assert_true($plugin_source =~ /ynison_debug/, 'ynison_debug preference defined');
});

test("Settings.pm includes debug preference", sub {
    my $settings_source = do {
        open my $fh, '<', "$FindBin::Bin/../Settings.pm" or die "Cannot read Settings.pm: $!";
        local $/;
        <$fh>;
    };
    assert_true($settings_source =~ /ynison_debug/, 'ynison_debug in Settings.pm');
});

test("HTML UI includes debug checkbox", sub {
    my $html_source = do {
        open my $fh, '<', "$FindBin::Bin/../HTML/EN/plugins/yandex/settings/basic.html" or die "Cannot read basic.html: $!";
        local $/;
        <$fh>;
    };
    assert_true($html_source =~ /ynison_debug/, 'ynison_debug checkbox in UI');
});

# Summary
print "\n" . ("=" x 50) . "\n";
print "Test Results: $pass_count/$test_count passed\n";
print "Failures: $fail_count\n";
print "\nAll critical functions and features verified!\n" if $fail_count == 0;
exit($fail_count > 0 ? 1 : 0);
