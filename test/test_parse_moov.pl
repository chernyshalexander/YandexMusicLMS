use strict;
use warnings;
use Data::Dumper;

sub _read_descr_len {
    my ($data, $pos) = @_;
    return (0,0,0) if $pos >= length($data);
    my $tag = ord(substr($data, $pos, 1));
    my $len = 0;
    my $bytes = 0;
    for (my $i = 0; $i < 4; $i++) {
        last if $pos + 1 + $i >= length($data);
        my $b = ord(substr($data, $pos + 1 + $i, 1));
        $bytes++;
        $len = ($len << 7) | ($b & 0x7F);
        last unless ($b & 0x80);
    }
    return ($tag, $len, $bytes);
}

# Example ESDS data 
# Usually a FullBox (4 bytes size, 4 bytes 'esds', 1 byte ver, 3 bytes flags)
# Then ES_Descriptor (tag 3)
my $esds_payload = pack("C*", 
0x03, 0x80, 0x80, 0x80, 0x22, # ES_Descriptor tag 3, len 34
0x00, 0x00, 0x00, # ES_ID, flags
0x04, 0x80, 0x80, 0x80, 0x14, # DecoderConfigDescriptor tag 4, len 20
0x40, 0x15, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, # objectType, streamType, bufferSize, maxBr, avgBr
0x05, 0x80, 0x80, 0x80, 0x02, # DecoderSpecificInfo tag 5, len 2
0x11, 0x90, # AudioSpecificConfig (AOT=2 (00010), freqIndex=3 (0011), channelConfig=2 (0010)... 00010001 10010000 = 0x11 0x90
0x06, 0x80, 0x80, 0x80, 0x01, 0x02 # SLConfigDescriptor tag 6, len 1
);

my $pos = 0;
my ($tag, $len, $len_bytes) = _read_descr_len($esds_payload, $pos);
$pos += 1 + $len_bytes;
$pos += 3;

($tag, $len, $len_bytes) = _read_descr_len($esds_payload, $pos);
$pos += 1 + $len_bytes;
$pos += 13;

($tag, $len, $len_bytes) = _read_descr_len($esds_payload, $pos);
$pos += 1 + $len_bytes;
my $asc = substr($esds_payload, $pos, $len);
print "ASC: " . unpack("H*", $asc) . "\n";

sub _make_adts_hdr {
    my ($asc, $frame_length) = @_;
    my $asc_val = unpack("n", substr($asc, 0, 2));
    my $aot = ($asc_val >> 11) & 0x1F;
    my $freq = ($asc_val >> 7) & 0x0F;
    my $chan = ($asc_val >> 3) & 0x0F;
    
    my $profile = ($aot - 1) & 0x3;
    my $flen = $frame_length + 7;
    
    my $hdr = pack("C7",
        0xFF,
        0xF1,
        (($profile << 6) & 0xC0) | (($freq << 2) & 0x3C) | (($chan >> 2) & 0x01),
        (($chan & 0x03) << 6) | (($flen >> 11) & 0x03),
        ($flen >> 3) & 0xFF,
        (($flen & 0x07) << 5) | 0x1F,
        0xFC
    );
    return $hdr;
}

my $adts = _make_adts_hdr($asc, 93);
print "ADTS: " . unpack("H*", $adts) . "\n";
