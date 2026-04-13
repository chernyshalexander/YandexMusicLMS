package Plugins::yandex::MP4Demux;

# Pure-Perl stateful streaming ISO BMFF (MP4) to FLAC demuxer.
# Extracts FLAC audio frames from a decrypted FLAC-in-MP4 stream on-the-fly.
#
# Assumptions (confirmed for Yandex FLAC-in-MP4):
#   - Box order: ftyp → uuid → moov → mdat  (moov always before mdat)
#   - moov is small (~13 KB), fully buffered before audio starts
#   - mdat contains contiguous FLAC audio frames — no gaps, no interleaving
#   - Output: "fLaC" + METADATA_BLOCK(s) from dfLa, then all mdat bytes verbatim
#
# Public API:
#   $demux = Plugins::yandex::MP4Demux->new()
#   $flac_bytes = $demux->process($chunk)   # feed decrypted MP4 bytes; returns FLAC bytes (may be '')
#   $flac_bytes = $demux->process(undef)    # signal EOF (no-op; FLAC frames need no flush)

use strict;
use warnings;
use bytes;

my $log = Slim::Utils::Log->logger('plugin.yandex');

# ---------------------------------------------------------------------------
# PUBLIC API
# ---------------------------------------------------------------------------

sub new {
    my ($class, %args) = @_;
    my $self = {
        buffer         => '',    # raw input buffer (decrypted MP4 bytes)
        state          => 'BOX', # BOX | MOOV | MDAT | DONE
        moov_data      => '',    # accumulated moov box bytes
        moov_size      => 0,
        mdat_remaining => 0,     # bytes left to copy from current mdat box
        flac_header    => undef, # "fLaC" + METADATA_BLOCK(s), undef until parsed
        out_buffer     => '',    # demuxed FLAC output waiting to be consumed
    };
    bless $self, $class;
    return $self;
}

# Feed a chunk of decrypted MP4 bytes; returns available FLAC bytes (may be empty string).
sub process {
    my ($self, $chunk) = @_;
    $self->{buffer} .= $chunk if defined $chunk;

    while (length($self->{buffer}) > 0) {
        my $state = $self->{state};

        if ($state eq 'BOX') {
            # Need at least 8 bytes to read box header
            last if length($self->{buffer}) < 8;

            my ($size, $type) = unpack('Na4', substr($self->{buffer}, 0, 8));
            my $hdr = 8;

            if ($size == 1) {
                # 64-bit extended size
                last if length($self->{buffer}) < 16;
                my ($hi, $lo) = unpack('NN', substr($self->{buffer}, 8, 8));
                $size = $hi * 4294967296 + $lo;
                $hdr  = 16;
            } elsif ($size == 0) {
                # Box extends to end of stream — treat all remaining buffer as this box
                $size = length($self->{buffer});
            }

            last if $size < $hdr;  # corrupt box

            if ($type eq 'moov') {
                $self->{state}     = 'MOOV';
                $self->{moov_size} = $size;
                # Collect moov_size bytes (including header) in MOOV state

            } elsif ($type eq 'mdat') {
                if (!$self->{flac_header}) {
                    $log->warn("MP4Demux: mdat encountered before moov was parsed");
                }
                my $hdr_size = ($hdr == 16) ? 16 : 8;
                $self->{state}          = 'MDAT';
                $self->{mdat_remaining} = $size - $hdr_size;
                substr($self->{buffer}, 0, $hdr_size) = '';  # consume mdat header

            } else {
                # Skip unknown/irrelevant box (ftyp, uuid, free, skip, …)
                last if length($self->{buffer}) < $size;  # wait for more data
                substr($self->{buffer}, 0, $size) = '';
            }

        } elsif ($state eq 'MOOV') {
            my $needed = $self->{moov_size} - length($self->{moov_data});
            my $take   = length($self->{buffer}) < $needed ? length($self->{buffer}) : $needed;
            $self->{moov_data} .= substr($self->{buffer}, 0, $take, '');

            if (length($self->{moov_data}) == $self->{moov_size}) {
                $self->_parse_moov();
                $self->{state} = 'BOX';
            } else {
                last;  # need more data
            }

        } elsif ($state eq 'MDAT') {
            unless ($self->{flac_header}) {
                # mdat before moov — buffer and wait (should not happen for Yandex streams)
                if (length($self->{buffer}) > 8 * 1024 * 1024) {
                    $log->error("MP4Demux: buffer exceeded 8MB waiting for moov — giving up");
                    $self->{state} = 'DONE';
                }
                last;
            }

            # Emit FLAC stream header once
            if ($self->{flac_header} ne 'SENT') {
                $self->{out_buffer} .= $self->{flac_header};
                $self->{flac_header} = 'SENT';
                $log->info("MP4Demux: emitting FLAC header (" . length($self->{out_buffer}) . " bytes)");
            }

            # Copy mdat audio bytes directly to output
            if ($self->{mdat_remaining} > 0 && length($self->{buffer}) > 0) {
                my $take = length($self->{buffer}) < $self->{mdat_remaining}
                         ? length($self->{buffer}) : $self->{mdat_remaining};
                $self->{out_buffer}     .= substr($self->{buffer}, 0, $take, '');
                $self->{mdat_remaining} -= $take;
            }

            if ($self->{mdat_remaining} <= 0) {
                $log->info("MP4Demux: mdat exhausted, returning to BOX scan");
                $self->{state} = 'BOX';
            } else {
                last;  # need more data
            }

        } elsif ($state eq 'DONE') {
            last;
        }
    }

    my $ret = $self->{out_buffer};
    $self->{out_buffer} = '';
    return $ret;
}

# ---------------------------------------------------------------------------
# PRIVATE HELPERS
# ---------------------------------------------------------------------------

# Parse the fully-buffered moov box to extract the FLAC stream header.
sub _parse_moov {
    my $self = shift;

    my $data_ref = \$self->{moov_data};
    my $err;

    # Find stbl box that belongs to the FLAC audio track
    my ($stbl_off, $stbl_size) = _find_flac_stbl(
        $data_ref, 0, length($$data_ref), \$err
    );

    unless (defined $stbl_off) {
        $log->error("MP4Demux: _find_flac_stbl failed: " . ($err || 'unknown error'));
        return;
    }

    # Extract FLAC METADATA_BLOCK(s) from dfLa box inside stsd
    my $meta_blocks = _extract_flac_metadata(
        $data_ref, $stbl_off, $stbl_off + $stbl_size, \$err
    );

    unless (defined $meta_blocks) {
        $log->error("MP4Demux: _extract_flac_metadata failed: " . ($err || 'unknown error'));
        return;
    }

    $self->{flac_header} = "fLaC" . $meta_blocks;
    $log->info("MP4Demux: FLAC header ready, metadata " . length($meta_blocks) . " bytes");
}

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
        last if $size < $hdr || $pos + $size > $limit;

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

        my ($stbl_off, $stbl_size) = _stbl_from_trak($data_ref, $trak_off, $trak_off + $trak_size);
        if (defined $stbl_off) {
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

    # stsd is FullBox: 4-byte size + 4-byte type + 4-byte ver/flags + 4-byte count = entries at +16
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

1;
