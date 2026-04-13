package Plugins::yandex::StreamingDemux;

# Pure-Perl stateful streaming MP4 (ISO BMFF) to FLAC demuxer.
# Extracts FLAC audio frames from a decrypted MP4 stream on-the-fly.

use strict;
use warnings;
use bytes;

my $log = Slim::Utils::Log->logger('plugin.yandex');

sub new {
    my ($class, %args) = @_;
    my $self = {
        buffer      => '',       # raw input buffer
        state       => 'BOX',    # BOX, MOOV, MDAT, DONE
        moov_data   => '',       # collected moov atom
        moov_size   => 0,
        mdat_pos    => 0,        # current relative position within mdat
        samples     => [],       # [offset_in_file, size]
        next_sample => 0,        # index into samples
        flac_header => undef,    # "fLaC" + STREAMINFO
        out_buffer  => '',       # demuxed output waiting to be read
    };
    bless $self, $class;
    return $self;
}

# Process an input chunk and return available demuxed FLAC bytes.
sub process {
    my ($self, $chunk) = @_;
    $self->{buffer} .= $chunk if defined $chunk;

    while (length($self->{buffer}) > 0) {
        if ($self->{state} eq 'BOX') {
            last if length($self->{buffer}) < 8;
            my ($size, $type) = unpack('Na4', substr($self->{buffer}, 0, 8));
            
            if ($size == 1) { # 64-bit size
                last if length($self->{buffer}) < 16;
                my ($hi, $lo) = unpack('NN', substr($self->{buffer}, 8, 8));
                $size = $hi * 4294967296 + $lo;
            }

            if ($type eq 'ftyp') {
                substr($self->{buffer}, 0, $size) = ''; # skip
            } elsif ($type eq 'moov') {
                $self->{state}     = 'MOOV';
                $self->{moov_size} = $size;
                # don't remove header yet, will collect in MOOV state
            } elsif ($type eq 'mdat') {
                if (!$self->{flac_header}) {
                    $log->warn("StreamingDemux: mdat found before moov - buffering might be needed");
                }
                $self->{state} = 'MDAT';
                my $hdr_size = (unpack('N', substr($self->{buffer}, 0, 4)) == 1) ? 16 : 8;
                $self->{mdat_remaining} = $size - $hdr_size;
                substr($self->{buffer}, 0, $hdr_size) = ''; # skip mdat header
            } else {
                # Skip unknown boxes
                if (length($self->{buffer}) >= $size) {
                    substr($self->{buffer}, 0, $size) = '';
                } else {
                    last; # wait for more data to skip
                }
            }
        } elsif ($self->{state} eq 'MOOV') {
            my $needed = $self->{moov_size} - length($self->{moov_data});
            my $take   = length($self->{buffer}) > $needed ? $needed : length($self->{buffer});
            $self->{moov_data} .= substr($self->{buffer}, 0, $take, '');
            
            if (length($self->{moov_data}) == $self->{moov_size}) {
                $self->_parse_moov();
                $self->{state} = 'BOX';
            } else {
                last;
            }
        } elsif ($self->{state} eq 'MDAT') {
            if ($self->{flac_header}) {
                if ($self->{flac_header} ne 'SENT') {
                    $self->{out_buffer} .= $self->{flac_header};
                    $self->{flac_header} = 'SENT';
                    $log->info("StreamingDemux: Sent FLAC header");
                }
                
                my $available = length($self->{buffer});
                if ($available > 0) {
                    my $take = ($available > $self->{mdat_remaining}) ? $self->{mdat_remaining} : $available;
                    $self->{out_buffer} .= substr($self->{buffer}, 0, $take, '');
                    $self->{mdat_remaining} -= $take;
                }

                if ($self->{mdat_remaining} <= 0) {
                    $log->info("StreamingDemux: Finished mdat box");
                    $self->{state} = 'BOX';
                } else {
                    last;
                }
            } else {
                # mdat before moov - must buffer until moov
                if (length($self->{buffer}) > 5*1024*1024) {
                    $log->error("StreamingDemux: mdat before moov and buffer exceeded 5MB. Giving up.");
                    $self->{state} = 'DONE';
                }
                last;
            }
        }
    }

    my $ret = $self->{out_buffer};
    $self->{out_buffer} = '';
    return $ret;
}

sub _parse_moov {
    my $self = shift;
    require Plugins::yandex::MP4Demux;
    
    # We can reuse MP4Demux logic by passing a reference to our collected moov + dummy layout
    # Or just implement the bare minimum here.
    
    # Actually, MP4Demux::demux_flac needs mdat too.
    # Let's extract what we need: STREAMINFO and sample table.
    
    my $data_ref = \$self->{moov_data};
    my $err;
    
    # Locate stbl
    my ($stbl_off, $stbl_size) = Plugins::yandex::MP4Demux::_find_flac_stbl($data_ref, 0, length($$data_ref), \$err);
    if ($stbl_off) {
        $self->{flac_header} = Plugins::yandex::MP4Demux::_extract_flac_metadata($data_ref, $stbl_off, $stbl_off + $stbl_size, \$err);
        if ($self->{flac_header}) {
            $self->{flac_header} = "fLaC" . $self->{flac_header};
        }
        
        # sample table
        my @samples = Plugins::yandex::MP4Demux::_build_sample_table($data_ref, $stbl_off, $stbl_off + $stbl_size, \$err);
        $self->{samples} = \@samples;
        
        # We need to know where mdat is in the file to calculate relative offsets
        # If moov was before mdat, we'll know mdat's file offset soon.
    }
}

1;
