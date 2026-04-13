package Plugins::yandex::MP4Demux;

# Pure-Perl ISO BMFF (MP4) demuxer for FLAC-in-MP4 streams.
# Reconstructs a valid raw FLAC bitstream from a decrypted FLAC-in-MP4 blob.
# No external dependencies required.
#
# Supported structure:
#   ftyp  (skipped)
#   moov
#     trak
#       mdia → minf → stbl
#         stsd  → fLaC/flac/fla1 → dfLa  (FLAC STREAMINFO)
#         stco / co64             (chunk offsets)
#         stsz                    (sample sizes)
#         stsc                    (sample-to-chunk mapping)
#   mdat  (raw FLAC audio frames)
#
# Output: "fLaC" marker + METADATA_BLOCK(s) from dfLa + concatenated audio frames

use strict;
use warnings;

# ---------------------------------------------------------------------------
# PUBLIC API
# ---------------------------------------------------------------------------

# Demux a FLAC-in-MP4 binary blob into raw FLAC bytes.
#
# Parameters:
#   $data_ref — ref to scalar containing the full decrypted MP4 data
#   $err_ref  — optional ref to scalar; set to error string on failure
#   $out_fh   — optional filehandle to write demuxed FLAC to (instead of returning string)
#
# Returns: raw FLAC bytes on success (if $out_fh not provided), 1 on success (if $out_fh provided), undef on failure.
sub demux_flac {
    my ($data_ref, $err_ref, $out_fh) = @_;
    my $total_len = length($$data_ref);

    # --- Locate top-level moov and mdat ---
    my ($moov_off, $moov_size) = _find_box($data_ref, 0, $total_len, 'moov');
    unless (defined $moov_off) {
        _err($err_ref, "moov box not found");
        return undef;
    }
    my ($mdat_off, $mdat_size) = _find_box($data_ref, 0, $total_len, 'mdat');
    unless (defined $mdat_off) {
        _err($err_ref, "mdat box not found");
        return undef;
    }

    # --- Navigate moov → trak → mdia → minf → stbl ---
    # Try each trak until we find one with a FLAC stsd entry
    my ($stbl_off, $stbl_size) = _find_flac_stbl($data_ref, $moov_off, $moov_off + $moov_size, $err_ref);
    unless (defined $stbl_off) {
        _err($err_ref, "No FLAC sample table found in any trak");
        return undef;
    }
    my $stbl_end = $stbl_off + $stbl_size;

    # --- Extract FLAC STREAMINFO metadata block from stsd → codec → dfLa ---
    my $metadata_blocks = _extract_flac_metadata($data_ref, $stbl_off, $stbl_end, $err_ref);
    unless (defined $metadata_blocks) {
        _err($err_ref, "dfLa/STREAMINFO not found");
        return undef;
    }

    # --- Build sample (offset, size) table from stco/co64 + stsz + stsc ---
    my @samples = _build_sample_table($data_ref, $stbl_off, $stbl_end, $err_ref);
    unless (@samples) {
        _err($err_ref, "Empty or invalid sample table");
        return undef;
    }

    # --- Reconstruct raw FLAC ---
    # Format: "fLaC" marker + METADATA_BLOCK_STREAMINFO (from dfLa) + audio frames
    my $header = "fLaC" . $metadata_blocks;
    
    if ($out_fh) {
        binmode($out_fh);
        print $out_fh $header;
    }
    
    my $flac = $out_fh ? 1 : $header;
    for my $s (@samples) {
        my ($offset, $size) = @$s;
        if ($offset + $size > $total_len) {
            _err($err_ref, "Sample at offset $offset size $size exceeds file length $total_len");
            return undef;
        }
        if ($out_fh) {
            print $out_fh substr($$data_ref, $offset, $size);
        } else {
            $flac .= substr($$data_ref, $offset, $size);
        }
    }

    return $flac;
}

# ---------------------------------------------------------------------------
# PRIVATE HELPERS
# ---------------------------------------------------------------------------

sub _err {
    my ($err_ref, $msg) = @_;
    $$err_ref = $msg if $err_ref;
}

# Find the first box of given 4-char $type within [$start, $limit).
# Returns (box_offset, box_size) or () if not found.
# box_size includes the header bytes.
sub _find_box {
    my ($data_ref, $start, $limit, $type) = @_;
    my $len = length($$data_ref);
    $limit = $len if $limit > $len;

    my $pos = $start;
    while ($pos + 8 <= $limit) {
        my ($size, $btype) = unpack('Na4', substr($$data_ref, $pos, 8));
        my $hdr = 8;

        if ($size == 1) {
            # 64-bit extended size
            last if $pos + 16 > $limit;
            my ($hi, $lo) = unpack('NN', substr($$data_ref, $pos + 8, 8));
            $size = $hi * 4294967296 + $lo;
            $hdr  = 16;
        } elsif ($size == 0) {
            # Box extends to end of file/container
            $size = $limit - $pos;
        }

        # Sanity check
        last if $size < $hdr || $pos + $size > $limit + 1;

        return ($pos, $size) if $btype eq $type;

        $pos += $size;
    }
    return ();
}

# Scan all trak boxes in moov; return stbl of the first trak containing a FLAC stsd entry.
sub _find_flac_stbl {
    my ($data_ref, $moov_off, $moov_end, $err_ref) = @_;

    my $pos = $moov_off + 8;  # skip moov header
    while ($pos < $moov_end) {
        my ($trak_off, $trak_size) = _find_box($data_ref, $pos, $moov_end, 'trak');
        last unless defined $trak_off;

        # Try to get stbl from this trak
        my ($stbl_off, $stbl_size) = _stbl_from_trak($data_ref, $trak_off, $trak_off + $trak_size);
        if (defined $stbl_off) {
            # Confirm there is a FLAC stsd entry in this stbl
            if (_has_flac_stsd($data_ref, $stbl_off, $stbl_off + $stbl_size)) {
                return ($stbl_off, $stbl_size);
            }
        }

        $pos = $trak_off + $trak_size;
    }
    return ();
}

sub _stbl_from_trak {
    my ($data_ref, $trak_off, $trak_end) = @_;
    my ($mdia_off, $mdia_size) = _find_box($data_ref, $trak_off + 8, $trak_end, 'mdia');
    return () unless defined $mdia_off;
    my ($minf_off, $minf_size) = _find_box($data_ref, $mdia_off + 8, $mdia_off + $mdia_size, 'minf');
    return () unless defined $minf_off;
    my ($stbl_off, $stbl_size) = _find_box($data_ref, $minf_off + 8, $minf_off + $minf_size, 'stbl');
    return () unless defined $stbl_off;
    return ($stbl_off, $stbl_size);
}

# Returns true if stbl contains a FLAC audio sample entry (fLaC / flac / fla1).
sub _has_flac_stsd {
    my ($data_ref, $stbl_off, $stbl_end) = @_;
    my ($stsd_off, $stsd_size) = _find_box($data_ref, $stbl_off + 8, $stbl_end, 'stsd');
    return 0 unless defined $stsd_off;

    # stsd is FullBox: 4-byte (size) + 4-byte (type) + 4-byte (ver+flags) + 4-byte (count) = entries at +16
    my $entries_start = $stsd_off + 16;
    my $stsd_end      = $stsd_off + $stsd_size;

    for my $ft ('fLaC', 'flac', 'fla1') {
        my ($e_off) = _find_box($data_ref, $entries_start, $stsd_end, $ft);
        return 1 if defined $e_off;
    }
    return 0;
}

# Extract FLAC METADATA_BLOCK bytes from stsd → <FLAC entry> → dfLa.
# Returns the raw METADATA_BLOCK bytes (BLOCK_HEADER + BLOCK_DATA) ready to
# append after the "fLaC" stream marker, or undef on failure.
sub _extract_flac_metadata {
    my ($data_ref, $stbl_off, $stbl_end, $err_ref) = @_;

    my ($stsd_off, $stsd_size) = _find_box($data_ref, $stbl_off + 8, $stbl_end, 'stsd');
    return undef unless defined $stsd_off;

    # stsd FullBox: entries start at offset 16 from box start
    my $entries_start = $stsd_off + 16;
    my $stsd_end      = $stsd_off + $stsd_size;

    for my $ft ('fLaC', 'flac', 'fla1') {
        my ($entry_off, $entry_size) = _find_box($data_ref, $entries_start, $stsd_end, $ft);
        next unless defined $entry_off;

        # Audio sample entry layout (after 8-byte box header):
        #   6 bytes reserved
        #   2 bytes data_reference_index
        #   8 bytes reserved
        #   2 bytes channelCount
        #   2 bytes sampleSize
        #   2 bytes pre_defined
        #   2 bytes reserved
        #   4 bytes sampleRate (Q16.16)
        # Total audio header = 28 bytes → codec boxes start at entry_off + 8 + 28 = entry_off + 36
        my $codec_start = $entry_off + 36;
        my $entry_end   = $entry_off + $entry_size;

        # dfLa is a FullBox containing the raw FLAC METADATA_BLOCK(s)
        my ($dfla_off, $dfla_size) = _find_box($data_ref, $codec_start, $entry_end, 'dfLa');
        next unless defined $dfla_off;

        # dfLa layout:
        #   4 bytes size
        #   4 bytes 'dfLa'
        #   1 byte  version
        #   3 bytes flags
        #   ----    FLAC METADATA_BLOCK(s) start here
        my $payload_off = $dfla_off + 12;   # skip 8-byte header + 4-byte FullBox ver/flags
        my $payload_len = $dfla_size - 12;
        next if $payload_len < 4;           # need at least a 4-byte block header

        return substr($$data_ref, $payload_off, $payload_len);
    }

    _err($err_ref, "dfLa box not found in any FLAC stsd entry");
    return undef;
}

# Build a list of [offset, size] pairs for every audio sample in the track.
# Uses stco/co64 (chunk offsets) + stsz (sample sizes) + stsc (samples-per-chunk).
sub _build_sample_table {
    my ($data_ref, $stbl_off, $stbl_end, $err_ref) = @_;

    # --- Chunk offsets: stco (32-bit) or co64 (64-bit) ---
    my @chunk_offsets;
    {
        my ($stco_off, $stco_size) = _find_box($data_ref, $stbl_off + 8, $stbl_end, 'stco');
        if (defined $stco_off) {
            # FullBox: 8 hdr + 4 ver/flags + 4 count = data at +16
            my $count = unpack('N', substr($$data_ref, $stco_off + 12, 4));
            @chunk_offsets = unpack("N$count", substr($$data_ref, $stco_off + 16, 4 * $count));
        } else {
            my ($co64_off, $co64_size) = _find_box($data_ref, $stbl_off + 8, $stbl_end, 'co64');
            unless (defined $co64_off) {
                _err($err_ref, "Neither stco nor co64 found");
                return ();
            }
            my $count = unpack('N', substr($$data_ref, $co64_off + 12, 4));
            for my $i (0 .. $count - 1) {
                my ($hi, $lo) = unpack('NN', substr($$data_ref, $co64_off + 16 + $i * 8, 8));
                push @chunk_offsets, $hi * 4294967296 + $lo;
            }
        }
    }

    # --- Sample sizes: stsz ---
    my @sample_sizes;
    {
        my ($stsz_off, $stsz_size) = _find_box($data_ref, $stbl_off + 8, $stbl_end, 'stsz');
        unless (defined $stsz_off) {
            _err($err_ref, "stsz box not found");
            return ();
        }
        # FullBox: 8 hdr + 4 ver/flags + 4 default_sample_size + 4 sample_count
        my ($default_size, $count) = unpack('NN', substr($$data_ref, $stsz_off + 12, 8));
        if ($default_size) {
            @sample_sizes = ($default_size) x $count;
        } else {
            @sample_sizes = unpack("N$count", substr($$data_ref, $stsz_off + 20, 4 * $count));
        }
    }

    # --- Sample-to-chunk: stsc ---
    # Each entry: (first_chunk_1based, samples_per_chunk, sample_description_index)
    my @stsc;
    {
        my ($stsc_off, $stsc_size) = _find_box($data_ref, $stbl_off + 8, $stbl_end, 'stsc');
        unless (defined $stsc_off) {
            _err($err_ref, "stsc box not found");
            return ();
        }
        my $count = unpack('N', substr($$data_ref, $stsc_off + 12, 4));
        for my $i (0 .. $count - 1) {
            my ($first_chunk, $spc) = unpack('NN', substr($$data_ref, $stsc_off + 16 + $i * 12, 8));
            push @stsc, [$first_chunk, $spc];
        }
    }

    return () unless @chunk_offsets && @sample_sizes && @stsc;

    # --- Build flat sample list ---
    my @samples;
    my $sample_idx  = 0;
    my $num_chunks  = scalar @chunk_offsets;
    my $num_samples = scalar @sample_sizes;

    for my $ci (0 .. $num_chunks - 1) {
        my $chunk_num = $ci + 1;  # stsc uses 1-based chunk numbers

        # Find samples_per_chunk for this chunk (last stsc entry where first_chunk <= chunk_num)
        my $spc = $stsc[0][1];
        for my $e (@stsc) {
            last if $e->[0] > $chunk_num;
            $spc = $e->[1];
        }

        my $byte_offset = $chunk_offsets[$ci];
        for my $s (0 .. $spc - 1) {
            last if $sample_idx >= $num_samples;
            my $sz = $sample_sizes[$sample_idx];
            push @samples, [$byte_offset, $sz];
            $byte_offset += $sz;
            $sample_idx++;
        }
    }

    return @samples;
}

1;
