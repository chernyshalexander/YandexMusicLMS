#!/usr/bin/perl
use strict; use warnings;
use FindBin;
do "$FindBin::Bin/../AES128.pm" or die "Cannot load AES128.pm: " . ($@ || $!);

my $KEY_HEX = "c947a60dec3209ca1d818810c74c7763";
my $FILE    = "$FindBin::Bin/flac-mp4";

open my $fh, "<", $FILE or die "Cannot open $FILE: $!";
binmode $fh;
read($fh, my $data, 512*1024);
close $fh;
printf "Read %d bytes\n\n", length($data);

# AES-128-CTR decrypt
my $cipher = Plugins::yandex::AES128->new(pack("H*", $KEY_HEX));
my ($dec, $len, $i) = ("", length($data), 0);
while ($i < $len) {
    my $blk  = int($i / 16);
    my $off  = $i % 16;
    my $ks   = $cipher->encrypt("\x00" x 12 . pack("N", $blk));
    my $take = 16 - $off; $take = $len - $i if $len - $i < $take;
    $dec .= substr($data, $i, $take) ^ substr($ks, $off, $take);
    $i += $take;
}

printf "First 8 bytes hex : %s\n", unpack("H16", substr($dec, 0, 8));
printf "Bytes [4..7] text  : \"%s\"\n\n", substr($dec, 4, 4);

# Scan top-level boxes
my ($pos, $total) = (0, length($dec));
my @order;
while ($pos + 8 <= $total) {
    my ($size, $type) = unpack("Na4", substr($dec, $pos, 8));
    my $hdr = 8;
    if ($size == 1) {
        last if $pos + 16 > $total;
        my ($hi, $lo) = unpack("NN", substr($dec, $pos + 8, 8));
        $size = $hi * 4_294_967_296 + $lo;
        $hdr  = 16;
    } elsif ($size == 0) {
        $size = $total - $pos;
    }
    last if $size < $hdr;
    (my $td = $type) =~ s/[^\x20-\x7e]/./g;
    printf "  offset=%-8d  size=%-12d  type=%-6s  [%s]\n",
        $pos, $size, $td,
        ($pos + $size <= $total) ? "complete" : "partial in 512KB window (full size=$size)";
    push @order, $type;
    last if $pos + $size > $total;
    $pos += $size;
}
print "\nBox order: " . join(" -> ", @order) . "\n";
my $mi = (grep { $order[$_] eq 'moov' } 0..$#order)[0] // -1;
my $di = (grep { $order[$_] eq 'mdat' } 0..$#order)[0] // -1;
if ($mi >= 0 && $di >= 0) {
    print $mi < $di ? "RESULT: moov BEFORE mdat\n" : "RESULT: mdat BEFORE moov\n";
} elsif ($mi < 0) {
    print "RESULT: moov not found in first 512KB\n";
} else {
    print "RESULT: mdat not yet reached in first 512KB\n";
}
