package Plugins::yandex::ProtocolHandler;

use strict;
use warnings;
use Slim::Utils::Log;
use base qw(Slim::Player::Protocols::HTTPS);
use JSON::XS::VersionOneAndTwo;

# !!! ГЛАВНОЕ ИСПРАВЛЕНИЕ: Явно загружаем наш модуль !!!
require Plugins::yandex::Track;

my $log = logger('plugin.yandex');

# --- 1. КОНСТРУКТОР (как в Qobuz) ---
sub new {
    my $class  = shift;
    my $args   = shift;

    my $client    = $args->{client};
    my $song      = $args->{song};
    
    # Берем URL, который должен быть уже установлен в getNextTrack
    my $streamUrl = $song->streamUrl() || return;

    $log->error("YANDEX: Handler new() called for REAL streamUrl: $streamUrl");

    my $sock = $class->SUPER::new( {
        url     => $streamUrl,
        song    => $song,
        client  => $client,
    } ) || return;

    # Устанавливаем тип контента, как в Deezer
    ${*$sock}{contentType} = 'audio/mpeg';

    return $sock;
}

# --- 2. isDirect (как в Qobuz) ---
sub isDirect { 1 }

# --- 3. scanUrl (как в Qobuz и Deezer) ---
sub scanUrl {
    my ($class, $url, $args) = @_;
    $args->{cb}->( $args->{song}->currentTrack() );
}

# --- 4. getNextTrack (ПЕРЕПИСЫВАЕМ НА АСИНХРОННЫЙ ВЫЗОВ) ---
sub getNextTrack {
    my ($class, $song, $successCb, $errorCb) = @_;

    my $url = $song->currentTrack()->url;
    $log->error("YANDEX: getNextTrack called for: $url");

    my $track_id = $url;
    unless ($url =~ /yandexmusic:\/\/(?:track\/)?(\d+)/) {
        $log->error("YANDEX: Can't parse ID from URL: $url");
        $errorCb->('Invalid URL format');
        return;
    }
    $track_id = $1;

    # Создаем объект трека. Теперь он должен создаться без ошибок.
    my $track = Plugins::yandex::Track->new({ id => $track_id });

    # !!! ГЛАВНОЕ: Вызываем АСИНХРОННЫЙ метод из Track.pm !!!
    $track->get_direct_url(sub {
        my ($final_url, $error) = @_;

        if ($final_url) {
            $log->error("YANDEX: ASYNC URL resolved: $final_url");
            
            # Устанавливаем реальную ссылку в объект песни
            $song->streamUrl($final_url);
            
            # Сообщаем об успехе
            $successCb->();
        } else {
            $log->error("YANDEX: ASYNC URL resolution failed: $error");
            # Сообщаем об ошибке
            $errorCb->($error);
        }
    });
}

# --- 5. Остальные методы (без изменений) ---
sub getFormatForURL { 'mp3' }
sub isRemote { 1 }
sub isAudio { 1 }
sub canSeek { 1 }

sub getMetadata {
    my ($class, $client, $url) = @_;
    # ... ваш код ...
}

sub canDoAction {
    my ($class, $client, $url, $action) = @_;
    return 1 if $action =~ /^(pause|stop|seek|rew|fwd)$/;
    return 0;
}

1;