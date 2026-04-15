package Plugins::yandex::MP4Demux;

use strict;
use warnings;
use bytes;

sub new {
    my ($class, %args) = @_;
    my $log = Slim::Utils::Log::logger('plugin.yandex');
    my $codec = $args{codec} || 'flac';
    my $self = {
        log            => $log,
        codec          => $codec,
        buffer         => '',
        buf_pos        => 0,     # read offset into buffer — avoid O(n) substr shifts
        state          => 'BOX',
        moov_data      => '',
        moov_size      => 0,
        moof_data      => '',
        moof_size      => 0,
        mdat_remaining => 0,

        # fMP4 support
        is_fmp4        => 0,

        # FLAC specific
        flac_header    => undef,

        # AAC specific
        aac_asc        => undef,
        aac_sizes      => [],
        aac_frame_idx  => 0,
        aac_frame_pos  => 0,

        # General
        header_parsed  => 0,
        out_buffer     => '',
    };
    bless $self, $class;
    return $self;
}

sub process {
    my ($self, $chunk) = @_;
    my $log = $self->{log};
    $self->{buffer} .= $chunk if defined $chunk;

    my $buf = \$self->{buffer};  # scalar ref — avoids repeated hash lookup in hot loop

    while (1) {
        my $avail = length($$buf) - $self->{buf_pos};
        last if $avail <= 0;

        my $state = $self->{state};

        if ($state eq 'BOX') {
            last if $avail < 8;

            my $pos = $self->{buf_pos};
            my ($size, $type) = unpack('Na4', substr($$buf, $pos, 8));
            my $hdr = 8;

            if ($size == 1) {
                last if $avail < 16;
                my ($hi, $lo) = unpack('NN', substr($$buf, $pos + 8, 8));
                $size = $hi * 4294967296 + $lo;
                $hdr  = 16;
            } elsif ($size == 0) {
                # size==0 means "extends to end of file" — treat as remaining avail
                $size = $avail;
            }

            last if $size < $hdr;

            if ($type eq 'moov') {
                $self->{state}     = 'MOOV';
                $self->{moov_size} = $size;
                $self->{moov_data} = '';
            } elsif ($type eq 'moof') {
                $self->{state}     = 'MOOF';
                $self->{moof_size} = $size;
                $self->{moof_data} = '';
            } elsif ($type eq 'mdat') {
                my $hdr_size     = ($hdr == 16) ? 16 : 8;
                my $payload_size = $size > $hdr_size ? $size - $hdr_size : 2**31;
                $self->{buf_pos} += $hdr_size;
                my $avail_after  = $avail - $hdr_size;

                # Detect nested fMP4 inside outer mdat.
                # Yandex structure: [outer moov (stub stsz, no mvex)] [outer mdat containing full inner fMP4]
                if ($self->{codec} ne 'flac' && !$self->{is_fmp4}) {
                    if ($avail_after >= 8) {
                        my (undef, $inner_type) = unpack('Na4', substr($$buf, $self->{buf_pos}, 8));
                        if ($inner_type =~ /^(?:ftyp|styp|moov|moof|free|sidx|emsg)$/) {
                            $log->info("YANDEX: MP4Demux: nested fMP4 in outer mdat (first_box='$inner_type')");
                            _reset_for_inner_mp4($self);
                            next;
                        }
                    } else {
                        # Buffer too small to peek — defer nested check to MDAT state
                        $self->{_check_nested} = 1;
                    }
                }

                $self->{state}          = 'MDAT';
                $self->{mdat_remaining} = $payload_size;

                # For fMP4: reset frame index (sizes already set by last moof)
                if ($self->{is_fmp4} && $self->{codec} ne 'flac') {
                    $self->{aac_frame_idx} = 0;
                    $self->{aac_frame_pos} = 0;
                }
            } else {
                last if $avail < $size;
                $self->{buf_pos} += $size;
            }

        } elsif ($state eq 'MOOV') {
            my $needed = $self->{moov_size} - length($self->{moov_data});
            my $take   = $avail < $needed ? $avail : $needed;
            $self->{moov_data} .= substr($$buf, $self->{buf_pos}, $take);
            $self->{buf_pos}   += $take;

            if (length($self->{moov_data}) == $self->{moov_size}) {
                $self->_parse_moov();
                $self->{header_parsed} = 1;
                $self->{state} = 'BOX';
            } else {
                last;
            }

        } elsif ($state eq 'MOOF') {
            my $needed = $self->{moof_size} - length($self->{moof_data});
            my $take   = $avail < $needed ? $avail : $needed;
            $self->{moof_data} .= substr($$buf, $self->{buf_pos}, $take);
            $self->{buf_pos}   += $take;

            if (length($self->{moof_data}) == $self->{moof_size}) {
                my $sizes = $self->_parse_moof();
                if (defined $sizes && @$sizes) {
                    $self->{aac_sizes}     = $sizes;
                    $self->{aac_frame_idx} = 0;
                    $self->{aac_frame_pos} = 0;
                } else {
                    $log->warn("YANDEX: MP4Demux: moof: no sample sizes found in trun");
                }
                $self->{moof_data} = '';
                $self->{state}     = 'BOX';
            } else {
                last;
            }

        } elsif ($state eq 'MDAT') {
            unless ($self->{header_parsed}) {
                if ($avail > 8 * 1024 * 1024) {
                    $log->error("YANDEX: MP4Demux: buffer exceeded 8MB waiting for moov");
                    $self->{state} = 'DONE';
                }
                last;
            }

            if ($self->{codec} eq 'flac') {
                if ($self->{flac_header} && $self->{flac_header} ne 'SENT') {
                    $self->{out_buffer} .= $self->{flac_header};
                    $self->{flac_header} = 'SENT';
                }
                if ($self->{mdat_remaining} > 0 && $avail > 0) {
                    my $take = $avail < $self->{mdat_remaining} ? $avail : $self->{mdat_remaining};
                    $self->{out_buffer}     .= substr($$buf, $self->{buf_pos}, $take);
                    $self->{buf_pos}        += $take;
                    $self->{mdat_remaining} -= $take;
                }
            } else {
                # AAC path

                # Deferred nested fMP4 check (when buffer had < 8 bytes at mdat entry)
                if ($self->{_check_nested}) {
                    last if $avail < 8;
                    $self->{_check_nested} = 0;
                    my (undef, $inner_type) = unpack('Na4', substr($$buf, $self->{buf_pos}, 8));
                    if ($inner_type =~ /^(?:ftyp|styp|moov|moof|free|sidx|emsg)$/) {
                        $log->info("YANDEX: MP4Demux: nested fMP4 in outer mdat [deferred] (first_box='$inner_type')");
                        _reset_for_inner_mp4($self);
                        next;
                    }
                }

                if ($self->{aac_frame_idx} >= scalar(@{$self->{aac_sizes}})) {
                    # No more frames in table — drain remaining mdat bytes
                    if ($self->{mdat_remaining} > 0 && $avail > 0) {
                        my $take = $avail < $self->{mdat_remaining} ? $avail : $self->{mdat_remaining};
                        $self->{buf_pos}        += $take;
                        $self->{mdat_remaining} -= $take;
                    }
                } else {
                    my $frame_size = $self->{aac_sizes}->[$self->{aac_frame_idx}];

                    if ($avail > 0) {
                        if ($self->{aac_frame_pos} == 0) {
                            $self->{out_buffer} .= _make_adts_header($self->{aac_asc}, $frame_size);
                        }

                        my $bytes_needed = $frame_size - $self->{aac_frame_pos};
                        my $take = $avail < $bytes_needed ? $avail : $bytes_needed;
                        $take = $self->{mdat_remaining} if $take > $self->{mdat_remaining};

                        if ($take > 0) {
                            $self->{out_buffer}     .= substr($$buf, $self->{buf_pos}, $take);
                            $self->{buf_pos}        += $take;
                            $self->{aac_frame_pos}  += $take;
                            $self->{mdat_remaining} -= $take;
                        }

                        if ($self->{aac_frame_pos} >= $frame_size) {
                            $self->{aac_frame_idx}++;
                            $self->{aac_frame_pos} = 0;
                            next;
                        }
                    }
                }
            }

            if ($self->{mdat_remaining} <= 0) {
                $self->{state} = 'BOX';
            } else {
                last;
            }

        } elsif ($state eq 'DONE') {
            last;
        }
    }

    # Compact: drop consumed bytes in one shot instead of per-iteration shifts.
    # This is O(remaining) once per process() call vs O(n²) with repeated substr removals.
    if ($self->{buf_pos} > 0) {
        substr($$buf, 0, $self->{buf_pos}, '');
        $self->{buf_pos} = 0;
    }

    my $ret = $self->{out_buffer};
    $self->{out_buffer} = '';
    return $ret;
}

sub _reset_for_inner_mp4 {
    my $self = shift;
    $self->{header_parsed} = 0;
    $self->{moov_data}     = '';
    $self->{moov_size}     = 0;
    $self->{moof_data}     = '';
    $self->{moof_size}     = 0;
    $self->{is_fmp4}       = 0;
    $self->{aac_asc}       = undef;
    $self->{aac_sizes}     = [];
    $self->{aac_frame_idx} = 0;
    $self->{aac_frame_pos} = 0;
    $self->{mdat_remaining}= 0;
    $self->{_check_nested} = 0;
    $self->{state}         = 'BOX';
}

sub _parse_moov {
    my $self = shift;
    my $log = $self->{log};
    my $data_ref = \$self->{moov_data};
    my $err;

    # Detect fMP4 via mvex box
    my ($mvex_off) = _find_box($data_ref, 8, length($$data_ref), 'mvex');
    if (defined $mvex_off) {
        $self->{is_fmp4} = 1;
        $log->info("YANDEX: MP4Demux: fMP4 detected (mvex present)");
    }

    if ($self->{codec} eq 'flac') {
        my ($stbl_off, $stbl_size) = _find_stbl_for_codec($data_ref, 0, length($$data_ref), ['fLaC', 'flac', 'fla1'], \$err);
        if (defined $stbl_off) {
            my $meta_blocks = _extract_flac_metadata($data_ref, $stbl_off, $stbl_off + $stbl_size, \$err);
            if (defined $meta_blocks) {
                $self->{flac_header} = "fLaC" . $meta_blocks;
            }
        }
    } else {
        my ($stbl_off, $stbl_size) = _find_stbl_for_codec($data_ref, 0, length($$data_ref), ['mp4a'], \$err, $log);
        if (defined $stbl_off) {
            my $asc = _extract_aac_asc($data_ref, $stbl_off, $stbl_off + $stbl_size, \$err);
            if (defined $asc) {
                $self->{aac_asc} = $asc;
                $log->info("YANDEX: MP4Demux: AAC ASC: " . unpack("H*", $asc));

                if (!$self->{is_fmp4}) {
                    # For regular MP4, get sizes from stsz/stz2
                    my $sizes = _extract_stsz($data_ref, $stbl_off, $stbl_off + $stbl_size, \$err, $log);
                    $self->{aac_sizes} = $sizes if defined $sizes;
                }
            }
        }
    }
}

# Parse moof box to extract frame sizes from trun
sub _parse_moof {
    my $self = shift;
    my $log  = $self->{log};
    my $data_ref = \$self->{moof_data};
    my $moof_end = length($$data_ref);

    # Find traf inside moof
    my ($traf_off, $traf_size) = _find_box($data_ref, 8, $moof_end, 'traf');
    unless (defined $traf_off) {
        $log->warn("YANDEX: MP4Demux: _parse_moof: no traf box found");
        return undef;
    }

    my $traf_end = $traf_off + $traf_size;

    # Parse tfhd for default_sample_size
    my $default_sample_size = 0;
    my ($tfhd_off, $tfhd_size) = _find_box($data_ref, $traf_off + 8, $traf_end, 'tfhd');
    if (defined $tfhd_off) {
        my $pos = $tfhd_off + 8;  # skip size+type
        # version (1 byte) + flags (3 bytes)
        my $flags = _read_uint24($data_ref, $pos + 1);
        $pos += 4;
        $pos += 4;  # track_ID
        $pos += 8 if $flags & 0x000001;  # base_data_offset
        $pos += 4 if $flags & 0x000002;  # sample_description_index
        $pos += 4 if $flags & 0x000008;  # default_sample_duration
        if ($flags & 0x000010) {
            $default_sample_size = unpack("N", substr($$data_ref, $pos, 4));
            $log->info("YANDEX: MP4Demux: tfhd default_sample_size=$default_sample_size");
        }
    }

    # Parse trun for per-sample sizes
    my ($trun_off, $trun_size) = _find_box($data_ref, $traf_off + 8, $traf_end, 'trun');
    unless (defined $trun_off) {
        $log->warn("YANDEX: MP4Demux: _parse_moof: no trun box found in traf");
        return undef;
    }

    my $pos = $trun_off + 8;  # skip size+type
    my $version = ord(substr($$data_ref, $pos, 1));
    my $flags   = _read_uint24($data_ref, $pos + 1);
    $pos += 4;

    my $sample_count = unpack("N", substr($$data_ref, $pos, 4));
    $pos += 4;

    $pos += 4 if $flags & 0x000001;  # data_offset
    $pos += 4 if $flags & 0x000004;  # first_sample_flags

    my $has_duration = $flags & 0x000100;
    my $has_size     = $flags & 0x000200;
    my $has_flags    = $flags & 0x000400;
    my $has_cts      = $flags & 0x000800;

    my @sizes;
    for my $i (0 .. $sample_count - 1) {
        $pos += 4 if $has_duration;
        my $sz = $default_sample_size;
        if ($has_size) {
            last if $pos + 4 > $trun_off + $trun_size;
            $sz = unpack("N", substr($$data_ref, $pos, 4));
            $pos += 4;
        }
        $pos += 4 if $has_flags;
        $pos += 4 if $has_cts;
        push @sizes, $sz;
    }

    return \@sizes;
}

sub _read_uint24 {
    my ($data_ref, $pos) = @_;
    return 0 if $pos + 3 > length($$data_ref);
    my ($b0, $b1, $b2) = unpack("CCC", substr($$data_ref, $pos, 3));
    return ($b0 << 16) | ($b1 << 8) | $b2;
}

sub _make_adts_header {
    my ($asc, $frame_length) = @_;
    my ($asc_val) = unpack("n", substr($asc, 0, 2));
    my $aot  = ($asc_val >> 11) & 0x1F;
    my $freq = ($asc_val >> 7) & 0x0F;
    my $chan = ($asc_val >> 3) & 0x0F;

    my $profile = ($aot - 1) & 0x03;
    my $flen = $frame_length + 7;

    my $hdr = pack("C7",
        0xFF,
        0xF1, # Syncword + ID=0 (MPEG-4), Layer=00, ProtectionAbsent=1
        (($profile << 6) & 0xC0) | (($freq << 2) & 0x3C) | (($chan >> 2) & 0x01),
        (($chan & 0x03) << 6) | (($flen >> 11) & 0x03),
        ($flen >> 3) & 0xFF,
        (($flen & 0x07) << 5) | 0x1F,
        0xFC
    );
    return $hdr;
}

sub _find_box {
    my ($data_ref, $start, $limit, $type) = @_;
    my $len = length($$data_ref);
    $limit = $len if $limit > $len;

    my $pos = $start;
    while ($pos + 8 <= $limit) {
        my ($size, $btype) = unpack('Na4', substr($$data_ref, $pos, 8));
        my $hdr = 8;
        if ($size == 1) {
            last if $pos + 16 > $limit;
            my ($hi, $lo) = unpack('NN', substr($$data_ref, $pos + 8, 8));
            $size = $hi * 4294967296 + $lo;
            $hdr  = 16;
        } elsif ($size == 0) {
            $size = $limit - $pos;
        }
        last if $size < $hdr || $pos + $size > $limit;
        return ($pos, $size) if $btype eq $type;
        $pos += $size;
    }
    return ();
}

sub _find_stbl_for_codec {
    my ($data_ref, $moov_off, $moov_end, $codecs, $err_ref, $log) = @_;

    my $pos = $moov_off + 8;
    my $trak_idx = 0;
    while ($pos < $moov_end) {
        my ($trak_off, $trak_size) = _find_box($data_ref, $pos, $moov_end, 'trak');
        last unless defined $trak_off;
        $trak_idx++;

        my ($mdia_off, $mdia_size) = _find_box($data_ref, $trak_off + 8, $trak_off + $trak_size, 'mdia');
        if (defined $mdia_off) {
            # Only accept tracks with handler type 'soun' (audio)
            my ($hdlr_off, $hdlr_size) = _find_box($data_ref, $mdia_off + 8, $mdia_off + $mdia_size, 'hdlr');
            if (defined $hdlr_off) {
                my $hdlr_type = substr($$data_ref, $hdlr_off + 16, 4);
                next unless $hdlr_type eq 'soun';
            }

            my ($minf_off, $minf_size) = _find_box($data_ref, $mdia_off + 8, $mdia_off + $mdia_size, 'minf');
            if (defined $minf_off) {
                my ($stbl_off, $stbl_size) = _find_box($data_ref, $minf_off + 8, $minf_off + $minf_size, 'stbl');
                if (defined $stbl_off) {
                    my ($stsd_off, $stsd_size) = _find_box($data_ref, $stbl_off + 8, $stbl_off + $stbl_size, 'stsd');
                    if (defined $stsd_off) {
                        my $entries_start = $stsd_off + 16;
                        my $stsd_end = $stsd_off + $stsd_size;
                        for my $c (@$codecs) {
                            my ($e_off) = _find_box($data_ref, $entries_start, $stsd_end, $c);
                            if (defined $e_off) {
                                return ($stbl_off, $stbl_size);
                            }
                        }
                    }
                }
            }
        }
        $pos = $trak_off + $trak_size;
    }
    return ();
}

sub _extract_flac_metadata {
    my ($data_ref, $stbl_off, $stbl_end, $err_ref) = @_;
    my ($stsd_off, $stsd_size) = _find_box($data_ref, $stbl_off + 8, $stbl_end, 'stsd');
    return undef unless defined $stsd_off;

    my $entries_start = $stsd_off + 16;
    my $stsd_end      = $stsd_off + $stsd_size;

    for my $ft ('fLaC', 'flac', 'fla1') {
        my ($entry_off, $entry_size) = _find_box($data_ref, $entries_start, $stsd_end, $ft);
        next unless defined $entry_off;

        my $codec_start = $entry_off + 36;
        my $entry_end   = $entry_off + $entry_size;

        my ($dfla_off, $dfla_size) = _find_box($data_ref, $codec_start, $entry_end, 'dfLa');
        next unless defined $dfla_off;

        my $payload_off = $dfla_off + 12;
        my $payload_len = $dfla_size - 12;
        next if $payload_len < 4;

        return substr($$data_ref, $payload_off, $payload_len);
    }
    return undef;
}

sub _read_descr_len {
    my ($data_ref, $pos) = @_;
    return (0, 0, 0) if $pos >= length($$data_ref);
    my $tag = ord(substr($$data_ref, $pos, 1));
    my $len = 0;
    my $bytes = 0;
    for (my $i = 0; $i < 4; $i++) {
        last if $pos + 1 + $i >= length($$data_ref);
        my $b = ord(substr($$data_ref, $pos + 1 + $i, 1));
        $bytes++;
        $len = ($len << 7) | ($b & 0x7F);
        last unless ($b & 0x80);
    }
    return ($tag, $len, $bytes);
}

sub _extract_aac_asc {
    my ($data_ref, $stbl_off, $stbl_end, $err_ref) = @_;
    my ($stsd_off, $stsd_size) = _find_box($data_ref, $stbl_off + 8, $stbl_end, 'stsd');
    return undef unless defined $stsd_off;

    my ($entry_off, $entry_size) = _find_box($data_ref, $stsd_off + 16, $stsd_off + $stsd_size, 'mp4a');
    return undef unless defined $entry_off;

    my $esds_start = $entry_off + 36;
    my ($esds_off, $esds_size) = _find_box($data_ref, $esds_start, $entry_off + $entry_size, 'esds');
    return undef unless defined $esds_off;

    my $pos = $esds_off + 12;
    my ($tag, $len, $len_bytes) = _read_descr_len($data_ref, $pos);
    return undef unless $tag == 0x03;
    $pos += 1 + $len_bytes;
    $pos += 3;

    ($tag, $len, $len_bytes) = _read_descr_len($data_ref, $pos);
    return undef unless $tag == 0x04;
    $pos += 1 + $len_bytes;
    $pos += 13;

    ($tag, $len, $len_bytes) = _read_descr_len($data_ref, $pos);
    return undef unless $tag == 0x05;
    $pos += 1 + $len_bytes;

    return substr($$data_ref, $pos, $len);
}

sub _extract_stsz {
    my ($data_ref, $stbl_off, $stbl_end, $err_ref, $log) = @_;

    # Try standard stsz first
    my ($stsz_off, $stsz_size) = _find_box($data_ref, $stbl_off + 8, $stbl_end, 'stsz');
    if (defined $stsz_off) {
        my $pos = $stsz_off + 12;
        return undef if $pos + 8 > $stsz_off + $stsz_size;

        my ($sample_size, $sample_count) = unpack("NN", substr($$data_ref, $pos, 8));
        $pos += 8;

        my @sizes;
        if ($sample_size == 0) {
            return undef if $pos + ($sample_count * 4) > $stsz_off + $stsz_size;
            @sizes = unpack("N*", substr($$data_ref, $pos, $sample_count * 4));
        } else {
            @sizes = ($sample_size) x $sample_count;
        }
        return \@sizes;
    }

    # Fallback: try stz2 (Compact Sample Size Box)
    my ($stz2_off, $stz2_size) = _find_box($data_ref, $stbl_off + 8, $stbl_end, 'stz2');
    if (defined $stz2_off) {
        my $pos = $stz2_off + 8;   # skip size+type
        $pos += 4;                  # skip version+flags
        # reserved (3 bytes) + field_size (1 byte)
        my $field_size = ord(substr($$data_ref, $pos + 3, 1));
        $pos += 4;
        my $sample_count = unpack("N", substr($$data_ref, $pos, 4));
        $pos += 4;

        my @sizes;
        if ($field_size == 4) {
            for my $i (0 .. $sample_count - 1) {
                last if $pos >= $stz2_off + $stz2_size;
                my $byte = ord(substr($$data_ref, $pos, 1));
                if ($i % 2 == 0) {
                    push @sizes, ($byte >> 4) & 0x0F;
                } else {
                    push @sizes, $byte & 0x0F;
                    $pos++;
                }
            }
        } elsif ($field_size == 8) {
            @sizes = map { ord(substr($$data_ref, $pos + $_, 1)) } (0 .. $sample_count - 1);
        } elsif ($field_size == 16) {
            @sizes = unpack("n*", substr($$data_ref, $pos, $sample_count * 2));
        }
        return \@sizes if @sizes;
    }

    $log->warn("YANDEX: MP4Demux: neither stsz nor stz2 found in stbl") if $log;
    return undef;
}

1;
