package Plugins::yandex::ProtocolHandler;

use strict;
use warnings;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Symbol qw(gensym); # Нужно для создания фиктивного сокета

my $log = logger('plugin.yandex');

# 1. Конструктор, создающий "фиктивный сокет"
# Это решает ошибку "Not a GLOB reference"
sub new {
    my $class = shift;
    my $args  = shift;
    my $sock = gensym(); 
    return bless $sock, $class;
}

# 2. КРИТИЧНО ВАЖНО: Сообщаем LMS, что это Аудио-поток, а не плейлист.
# Это решает ошибку сканера "Can't connect to remote server... to retrieve playlist"
sub isAudio { 1 }

# Сообщаем, что этот трек не нужно сканировать на метаданные
sub audioScanned { 1 }

# Формат контента
sub contentType { return 'mp3'; }
sub getFormatForURL { return 'mp3'; }

# 3. Основная логика подмены ссылки
sub getNextTrack {
    my ($class, $song, $successCb, $errorCb) = @_;

    my $url = $song->currentTrack()->url;
    
    $log->error("YANDEX: Trying to resolve URL: $url");

    if ($url =~ m{^yandexmusic://(.+)}) {
        my $track_id = $1;
        
        my $client = $Plugins::yandex::Plugin::ymClient;
        
        unless ($client) {
            $log->error("YANDEX: Client not initialized!");
            $errorCb->();
            return;
        }

        # Получаем прямую ссылку
        my $track = Plugins::yandex::Track->new({ id => $track_id });
        my $stream_url;
        
        eval {
            $stream_url = $track->get_stream_url($client);
        };

        if ($@) {
             $log->error("YANDEX: Error fetching stream: $@");
             $errorCb->();
             return;
        }

        if ($stream_url) {
            $log->error("YANDEX: Stream URL found: $stream_url");
            
            # Подменяем ссылку на реальную HTTPS
            $song->streamUrl($stream_url);
            
            # Говорим LMS, что все ок
            $successCb->();
        } else {
            $log->error("YANDEX: Stream URL is empty");
            $errorCb->();
        }
    } else {
        $errorCb->();
    }
}

# --- Заглушки для имитации поведения сокета (чтобы плеер не падал) ---

sub blocking { 0 }
sub connected { 1 }
sub sysread { return 0; } # Возвращаем 0, так как данных мы не даем, мы только редиректим
sub opened { 1 }
sub close { 1 }

# --- Разрешения ---

sub canDoAction {
    my ($class, $client, $url, $action) = @_;
    return 1 if ($action eq 'pause' || $action eq 'stop' || $action eq 'rew' || $action eq 'fwd');
    return 0;
}

sub isRemote { 1 }
sub canSeek { 1 }

1;