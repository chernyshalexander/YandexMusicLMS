package TokenHelper;

use strict;
use warnings;
use Cwd 'dirname';
use File::Spec;

=head1 NAME

TokenHelper - Helper module for reading test tokens from test/token.txt

=head1 SYNOPSIS

    use lib "/home/chernysh/Projects/yandex";
    use test::TokenHelper;

    my $token = TokenHelper::get_token();
    die "No token configured in test/token.txt\n" unless $token;

=head1 DESCRIPTION

This module provides a helper function to read the Yandex Music API token
from the test/token.txt file. This ensures tokens are never hardcoded in
test scripts.

The token.txt file is included in .gitignore to prevent accidentally
committing tokens to the repository.

=cut

sub get_token {
    my $script_dir = dirname(__FILE__);
    my $token_file = File::Spec->catfile($script_dir, 'token.txt');

    if (! -e $token_file) {
        warn "Token file not found at: $token_file\n";
        return undef;
    }

    open my $fh, '<', $token_file or do {
        warn "Cannot read token file: $!\n";
        return undef;
    };

    my $token = do { local $/; <$fh> };
    close $fh;

    chomp($token);

    if (!$token || $token =~ /^\s*$/) {
        warn "Token file is empty\n";
        return undef;
    }

    return $token;
}

1;
