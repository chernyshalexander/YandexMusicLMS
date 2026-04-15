package Plugins::yandex::Decode::AES128;

=encoding utf8

=head1 NAME

Plugins::yandex::Decode::AES128 - Pure-Perl AES-128 ECB block cipher

=head1 DESCRIPTION

Drop-in fallback for C<Crypt::Rijndael->new($key, MODE_ECB)->encrypt($block)>.
Used by ProtocolHandler when Crypt::Rijndael is not installed.

The algorithm is AES-128 in ECB mode (encrypt-only). Even though ECB is
generally unsafe for data encryption, it is the correct building block for
AES-CTR stream decryption: each counter block is individually encrypted in ECB
mode, then XOR'd with the ciphertext. The security comes from the counter
uniqueness, not from the block mode.

Algorithm: FIPS PUB 197, "Advanced Encryption Standard (AES)"
  https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.197-upd1.pdf

T-table optimisation (Daemen & Rijmen, "The Design of Rijndael", 2002):
  One round = SubBytes + ShiftRows + MixColumns + AddRoundKey, merged into
  four 256-entry lookup tables (Te0–Te3). Each table entry combines the S-box
  substitution with one row of the MixColumns matrix multiplication in GF(2^8).
  This reduces 9 inner rounds to 16 table lookups + 4 XORs each, versus the
  naive loop over the 4×4 state matrix.

Performance: ~50k–150k blocks/sec on modern hardware (more than enough for
  FLAC streaming at ~900 kbps ≈ ~7k 16-byte blocks/sec).

=cut

use strict;
use warnings;

use strict;
use warnings;

# AES forward S-box (256 bytes).
# Computed from GF(2^8) multiplicative inverses plus affine transform over GF(2).
# Ref: FIPS 197, §5.1.1, Figure 7.
my @S = (
    0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
    0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
    0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
    0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
    0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
    0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
    0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
    0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
    0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
    0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
    0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
    0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
    0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
    0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
    0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
    0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16,
);

# Round constants for AES-128 key schedule (10 rounds).
# Rcon[i] = x^(i-1) in GF(2^8) with polynomial x^8+x^4+x^3+x+1, stored in the
# high byte of a 32-bit word. Ref: FIPS 197, §5.2, Table 2.
my @Rcon = map { $_ << 24 } (0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36);

# T-tables Te0–Te3: combine SubBytes, ShiftRows, and MixColumns into one lookup.
# Te0[a] encodes the contribution of byte 'a' in row 0 through MixColumns:
#   [2·S(a), 1·S(a), 1·S(a), 3·S(a)] packed as a big-endian 32-bit word.
# Te1/Te2/Te3 are right-rotations of Te0 by 8/16/24 bits — they encode the same
# operation for bytes that start in rows 1/2/3 (after ShiftRows routing).
# Built once at module load: 4 × 256 × 4 bytes = 4 KB total.
my (@Te0, @Te1, @Te2, @Te3);
{
    for my $i (0..255) {
        my $s  = $S[$i];
        my $s2 = (($s << 1) ^ (($s & 0x80) ? 0x1b : 0)) & 0xff; # GF(2^8) multiply by x (×2)
        my $s3 = $s2 ^ $s;                                        # GF(2^8) multiply by (x+1) (×3)
        # MixColumns row-0 coefficients [2,1,1,3] applied to S(i), packed big-endian
        $Te0[$i] = (($s2 << 24) | ($s << 16) | ($s << 8) | $s3) & 0xFFFFFFFF;
        # Rows 1/2/3: rotate the row-0 word right by 8/16/24 bits
        $Te1[$i] = (($Te0[$i] >> 8)  | (($Te0[$i] & 0x000000ff) << 24)) & 0xFFFFFFFF;
        $Te2[$i] = (($Te0[$i] >> 16) | (($Te0[$i] & 0x0000ffff) << 16)) & 0xFFFFFFFF;
        $Te3[$i] = (($Te0[$i] >> 24) | (($Te0[$i] & 0x00ffffff) <<  8)) & 0xFFFFFFFF;
    }
}

# Expand a 16-byte key into 44 round-key words (AES-128 key schedule).
# Produces rk[0..43]: rk[0..3] = original key, rk[4*i..4*i+3] = round i key.
# Every 4th word applies RotWord (rotate left by 8 bits), SubWord (S-box each byte),
# and XOR with Rcon[i/4 - 1]. Ref: FIPS 197, §5.2, KeyExpansion algorithm.
sub _key_expand {
    my ($key) = @_;
    my @w = unpack('N4', $key);            # 4 big-endian 32-bit words
    for my $i (4..43) {
        my $t = $w[$i - 1];
        if ($i % 4 == 0) {
            # RotWord: rotate left by 8 bits (move high byte to low position)
            $t = (($t << 8) | ($t >> 24)) & 0xFFFFFFFF;
            # SubWord: apply S-box to each byte independently
            $t = ($S[($t >> 24) & 0xff] << 24)
               | ($S[($t >> 16) & 0xff] << 16)
               | ($S[($t >>  8) & 0xff] <<  8)
               |  $S[ $t        & 0xff];
            $t ^= $Rcon[$i / 4 - 1];
        }
        $w[$i] = ($w[$i - 4] ^ $t) & 0xFFFFFFFF;
    }
    return @w;
}

sub new {
    my ($class, $key) = @_;
    die "AES128: key must be 16 bytes\n" unless length($key) == 16;
    return bless { rk => [ _key_expand($key) ] }, $class;
}

# Encrypt a single 16-byte block (ECB). Returns 16 bytes.
# State is 4 big-endian 32-bit words = 4 AES columns.
# ShiftRows byte routing (for col j): row0←col j, row1←col (j+1)%4, row2←col (j+2)%4, row3←col (j+3)%4.
#
# Optimisations vs. the loop version:
#   • 9 rounds unrolled — removes for-loop overhead, $r<<2 per iter, list-assignment ($s)=($t)
#   • Alternating s↔t variable sets — no per-round list copy
#   • & 0xFFFFFFFF removed from round bodies — XOR of ≤32-bit values stays ≤32-bit on 64-bit Perl
#   • Round keys copied to local array — $rk[$i] (array) vs $rk->[$i] (ref) is one fewer deref
sub encrypt {
    my ($self, $block) = @_;
    my @rk = @{$self->{rk}};   # local copy — avoids arrayref deref in hot path

    my ($s0, $s1, $s2, $s3) = unpack('N4', $block);

    # AddRoundKey round 0 (XOR of 32-bit values stays 32-bit, no mask needed)
    $s0 ^= $rk[0];  $s1 ^= $rk[1];  $s2 ^= $rk[2];  $s3 ^= $rk[3];

    # Rounds 1..9 unrolled.  Odd rounds read s→write t; even rounds read t→write s.
    # This eliminates the ($s0,$s1,$s2,$s3)=($t0,$t1,$t2,$t3) list-copy after every round.
    my ($t0, $t1, $t2, $t3);

    # Round 1 (rk[4..7])
    $t0 = $Te0[$s0>>24] ^ $Te1[($s1>>16)&0xff] ^ $Te2[($s2>>8)&0xff] ^ $Te3[$s3&0xff] ^ $rk[4];
    $t1 = $Te0[$s1>>24] ^ $Te1[($s2>>16)&0xff] ^ $Te2[($s3>>8)&0xff] ^ $Te3[$s0&0xff] ^ $rk[5];
    $t2 = $Te0[$s2>>24] ^ $Te1[($s3>>16)&0xff] ^ $Te2[($s0>>8)&0xff] ^ $Te3[$s1&0xff] ^ $rk[6];
    $t3 = $Te0[$s3>>24] ^ $Te1[($s0>>16)&0xff] ^ $Te2[($s1>>8)&0xff] ^ $Te3[$s2&0xff] ^ $rk[7];

    # Round 2 (rk[8..11])
    $s0 = $Te0[$t0>>24] ^ $Te1[($t1>>16)&0xff] ^ $Te2[($t2>>8)&0xff] ^ $Te3[$t3&0xff] ^ $rk[8];
    $s1 = $Te0[$t1>>24] ^ $Te1[($t2>>16)&0xff] ^ $Te2[($t3>>8)&0xff] ^ $Te3[$t0&0xff] ^ $rk[9];
    $s2 = $Te0[$t2>>24] ^ $Te1[($t3>>16)&0xff] ^ $Te2[($t0>>8)&0xff] ^ $Te3[$t1&0xff] ^ $rk[10];
    $s3 = $Te0[$t3>>24] ^ $Te1[($t0>>16)&0xff] ^ $Te2[($t1>>8)&0xff] ^ $Te3[$t2&0xff] ^ $rk[11];

    # Round 3 (rk[12..15])
    $t0 = $Te0[$s0>>24] ^ $Te1[($s1>>16)&0xff] ^ $Te2[($s2>>8)&0xff] ^ $Te3[$s3&0xff] ^ $rk[12];
    $t1 = $Te0[$s1>>24] ^ $Te1[($s2>>16)&0xff] ^ $Te2[($s3>>8)&0xff] ^ $Te3[$s0&0xff] ^ $rk[13];
    $t2 = $Te0[$s2>>24] ^ $Te1[($s3>>16)&0xff] ^ $Te2[($s0>>8)&0xff] ^ $Te3[$s1&0xff] ^ $rk[14];
    $t3 = $Te0[$s3>>24] ^ $Te1[($s0>>16)&0xff] ^ $Te2[($s1>>8)&0xff] ^ $Te3[$s2&0xff] ^ $rk[15];

    # Round 4 (rk[16..19])
    $s0 = $Te0[$t0>>24] ^ $Te1[($t1>>16)&0xff] ^ $Te2[($t2>>8)&0xff] ^ $Te3[$t3&0xff] ^ $rk[16];
    $s1 = $Te0[$t1>>24] ^ $Te1[($t2>>16)&0xff] ^ $Te2[($t3>>8)&0xff] ^ $Te3[$t0&0xff] ^ $rk[17];
    $s2 = $Te0[$t2>>24] ^ $Te1[($t3>>16)&0xff] ^ $Te2[($t0>>8)&0xff] ^ $Te3[$t1&0xff] ^ $rk[18];
    $s3 = $Te0[$t3>>24] ^ $Te1[($t0>>16)&0xff] ^ $Te2[($t1>>8)&0xff] ^ $Te3[$t2&0xff] ^ $rk[19];

    # Round 5 (rk[20..23])
    $t0 = $Te0[$s0>>24] ^ $Te1[($s1>>16)&0xff] ^ $Te2[($s2>>8)&0xff] ^ $Te3[$s3&0xff] ^ $rk[20];
    $t1 = $Te0[$s1>>24] ^ $Te1[($s2>>16)&0xff] ^ $Te2[($s3>>8)&0xff] ^ $Te3[$s0&0xff] ^ $rk[21];
    $t2 = $Te0[$s2>>24] ^ $Te1[($s3>>16)&0xff] ^ $Te2[($s0>>8)&0xff] ^ $Te3[$s1&0xff] ^ $rk[22];
    $t3 = $Te0[$s3>>24] ^ $Te1[($s0>>16)&0xff] ^ $Te2[($s1>>8)&0xff] ^ $Te3[$s2&0xff] ^ $rk[23];

    # Round 6 (rk[24..27])
    $s0 = $Te0[$t0>>24] ^ $Te1[($t1>>16)&0xff] ^ $Te2[($t2>>8)&0xff] ^ $Te3[$t3&0xff] ^ $rk[24];
    $s1 = $Te0[$t1>>24] ^ $Te1[($t2>>16)&0xff] ^ $Te2[($t3>>8)&0xff] ^ $Te3[$t0&0xff] ^ $rk[25];
    $s2 = $Te0[$t2>>24] ^ $Te1[($t3>>16)&0xff] ^ $Te2[($t0>>8)&0xff] ^ $Te3[$t1&0xff] ^ $rk[26];
    $s3 = $Te0[$t3>>24] ^ $Te1[($t0>>16)&0xff] ^ $Te2[($t1>>8)&0xff] ^ $Te3[$t2&0xff] ^ $rk[27];

    # Round 7 (rk[28..31])
    $t0 = $Te0[$s0>>24] ^ $Te1[($s1>>16)&0xff] ^ $Te2[($s2>>8)&0xff] ^ $Te3[$s3&0xff] ^ $rk[28];
    $t1 = $Te0[$s1>>24] ^ $Te1[($s2>>16)&0xff] ^ $Te2[($s3>>8)&0xff] ^ $Te3[$s0&0xff] ^ $rk[29];
    $t2 = $Te0[$s2>>24] ^ $Te1[($s3>>16)&0xff] ^ $Te2[($s0>>8)&0xff] ^ $Te3[$s1&0xff] ^ $rk[30];
    $t3 = $Te0[$s3>>24] ^ $Te1[($s0>>16)&0xff] ^ $Te2[($s1>>8)&0xff] ^ $Te3[$s2&0xff] ^ $rk[31];

    # Round 8 (rk[32..35])
    $s0 = $Te0[$t0>>24] ^ $Te1[($t1>>16)&0xff] ^ $Te2[($t2>>8)&0xff] ^ $Te3[$t3&0xff] ^ $rk[32];
    $s1 = $Te0[$t1>>24] ^ $Te1[($t2>>16)&0xff] ^ $Te2[($t3>>8)&0xff] ^ $Te3[$t0&0xff] ^ $rk[33];
    $s2 = $Te0[$t2>>24] ^ $Te1[($t3>>16)&0xff] ^ $Te2[($t0>>8)&0xff] ^ $Te3[$t1&0xff] ^ $rk[34];
    $s3 = $Te0[$t3>>24] ^ $Te1[($t0>>16)&0xff] ^ $Te2[($t1>>8)&0xff] ^ $Te3[$t2&0xff] ^ $rk[35];

    # Round 9 (rk[36..39]) — odd, reads s→writes t; final round will read t
    $t0 = $Te0[$s0>>24] ^ $Te1[($s1>>16)&0xff] ^ $Te2[($s2>>8)&0xff] ^ $Te3[$s3&0xff] ^ $rk[36];
    $t1 = $Te0[$s1>>24] ^ $Te1[($s2>>16)&0xff] ^ $Te2[($s3>>8)&0xff] ^ $Te3[$s0&0xff] ^ $rk[37];
    $t2 = $Te0[$s2>>24] ^ $Te1[($s3>>16)&0xff] ^ $Te2[($s0>>8)&0xff] ^ $Te3[$s1&0xff] ^ $rk[38];
    $t3 = $Te0[$s3>>24] ^ $Te1[($s0>>16)&0xff] ^ $Te2[($s1>>8)&0xff] ^ $Te3[$s2&0xff] ^ $rk[39];

    # Final round: SubBytes + ShiftRows + AddRoundKey (no MixColumns); reads t0..t3
    # pack 'N' masks to 32 bits implicitly — no explicit & 0xFFFFFFFF needed
    return pack('N4',
        (($S[$t0>>24]<<24) | ($S[($t1>>16)&0xff]<<16) | ($S[($t2>>8)&0xff]<<8) | $S[$t3&0xff]) ^ $rk[40],
        (($S[$t1>>24]<<24) | ($S[($t2>>16)&0xff]<<16) | ($S[($t3>>8)&0xff]<<8) | $S[$t0&0xff]) ^ $rk[41],
        (($S[$t2>>24]<<24) | ($S[($t3>>16)&0xff]<<16) | ($S[($t0>>8)&0xff]<<8) | $S[$t1&0xff]) ^ $rk[42],
        (($S[$t3>>24]<<24) | ($S[($t0>>16)&0xff]<<16) | ($S[($t1>>8)&0xff]<<8) | $S[$t2&0xff]) ^ $rk[43],
    );
}

1;
