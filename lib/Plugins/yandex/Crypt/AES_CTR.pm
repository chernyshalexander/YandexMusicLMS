package Plugins::yandex::Crypt::AES_CTR;

use strict;
use Crypt::Rijndael_PP;

# Реализация режима AES-128-CTR поверх сырого AES (ECB) блока
sub new {
    my ($class, $key_hex, $nonce_hex) = @_;

    my $key = pack("H*", $key_hex);
    my $nonce = $nonce_hex ? pack("H*", $nonce_hex) : ("\0" x 16);

    # Инициализируем 100% Perl реализацию Rijndael
    my $cipher = Crypt::Rijndael_PP->new($key);

    my $self = {
        cipher  => $cipher,
        counter => $nonce,     # Текущее значение 16-байтного счетчика (nonce + counter)
        buffer  => '',         # Буфер свободных байт (остаток после XOR)
    };

    return bless $self, $class;
}

sub encrypt {
    my ($self, $data) = @_;
    my $len = length($data);
    return '' if $len == 0;

    my $cipher = $self->{cipher};
    my $result = '';

    # 1. Ensure we have enough keystream in the buffer
    while (length($self->{buffer}) < $len) {
        # Use a copy of the counter to be safe against in-place modification
        my $block_keystream = $cipher->encrypt("" . $self->{counter});
        $self->{buffer} .= $block_keystream;
        
        # 2. Increment 128-bit counter (Big Endian)
        my $c = $self->{counter};
        for (my $i = 15; $i >= 0; $i--) {
            my $byte = ord(substr($c, $i, 1));
            if ($byte == 255) {
                substr($c, $i, 1, chr(0));
            } else {
                substr($c, $i, 1, chr($byte + 1));
                last;
            }
        }
        $self->{counter} = $c;
    }

    # 3. Fast XOR of the entire input with the matching keystream block
    $result = $data ^ substr($self->{buffer}, 0, $len, '');
    
    return $result;
}

sub decrypt {
    return shift->encrypt(@_);
}

1;
