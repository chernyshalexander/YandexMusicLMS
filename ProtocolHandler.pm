package Plugins::yandex::ProtocolHandler;

use strict;
use warnings;
use Slim::Utils::Log;
use Slim::Utils::Cache;
use base qw(Slim::Player::Protocols::HTTPS);
use JSON::XS::VersionOneAndTwo;

# !!! ГЛАВНОЕ ИСПРАВЛЕНИЕ: Явно загружаем наш модуль !!!
require Plugins::yandex::Track;
require Plugins::yandex::Plugin; # <--- ДОБАВИТЬ ЭТОТ REQUIRE

my $log = logger('plugin.yandex');

# --- 1. КОНСТРУКТОР 
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
        seekdata => $args->{seekdata}, # Pass seekdata for range requests
    } ) || return;

    # Устанавливаем тип контента
    ${*$sock}{contentType} = 'audio/mpeg';

    # Пробуем установить параметры потока явно, чтобы LMS знал, что это не бесконечный поток
    # и отображал прогресс бар.
    # Пробуем установить параметры потока явно, чтобы LMS знал, что это не бесконечный поток
    # и отображал прогресс бар.
    if ($client) {
         my $duration = $song->duration || 0;
         my $artist = 'Unknown';
         my $title = 'Unknown';

         # Используем оригинальный URL трека (yandexmusic://...) для поиска в кеше
         my $original_url = $song->currentTrack ? $song->currentTrack->url : $streamUrl;
         
         if (!$duration && $original_url =~ /yandexmusic:\/\/(\d+)/) {
             my $track_id = $1;
             my $cache = Slim::Utils::Cache->new();
             my $meta = $cache->get('yandex_meta_' . $track_id);
             
             if ($meta && $meta->{duration}) {
                 $duration = $meta->{duration};
                 $artist = $meta->{artist} if $meta->{artist};
                 $title = $meta->{title} if $meta->{title};
                 $log->info("YANDEX: Found cached metadata for $track_id: Duration=$duration");
             } else {
                 $log->warn("YANDEX: Metadata cache miss for $track_id");
             }
         }

         $log->warn("YANDEX: Setting duration $duration and isLive=0 for song " . ($song->currentTrack ? $song->currentTrack->url : 'unknown'));

         # Устанавливаем на переданном объекте $song (это объект Slim::Player::Song)
         $song->isLive(0);
         $song->duration($duration);
         
         # Также обновляем мету через Slim::Music::Info, чтобы UI подхватил
         if ($song->currentTrack) {
             Slim::Music::Info::setDuration($song->currentTrack, $duration);
         }
    }

    return $sock;
}

# --- 2. isDirect 
sub isDirect { 1 }

# --- 3. scanUrl 
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

    # --- ИЗМЕНЕНИЕ: Получаем экземпляр клиента из Plugin ---
    my $yandex_client = Plugins::yandex::Plugin->getClient();

    unless ($yandex_client) {
        $log->error("YANDEX: Could not get Yandex client instance. Plugin might not be initialized.");
        $errorCb->('Plugin not initialized');
        return;
    }

    # Создаем объект трека. Теперь он должен создаться без ошибок.
    my $track = Plugins::yandex::Track->new({ id => $track_id },$yandex_client);

    # !!! Вызываем АСИНХРОННЫЙ метод из Track.pm !!!
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
    
    # Пытаемся найти в кеше
    if ($url =~ /yandexmusic:\/\/(\d+)/) {
        my $track_id = $1;
        my $cache = Slim::Utils::Cache->new();
        if (my $cached_meta = $cache->get('yandex_meta_' . $track_id)) {
            $log->info("YANDEX: Returning cached metadata for $url");
            return {
                title    => $cached_meta->{title},
                artist   => $cached_meta->{artist},
                duration => $cached_meta->{duration},
                cover    => $cached_meta->{cover},
                icon     => $cached_meta->{cover},
                bitrate  => 192000,
                type     => 'mp3',
            };
        }
    }

    # Если в кеше нет, возвращаем undef/пусто, чтобы LMS использовал то, что есть в плейлисте
    return {};
}

sub getIcon {
    my ($class, $url) = @_;
    
    if ($url =~ /yandexmusic:\/\/(\d+)/) {
        my $track_id = $1;
        my $cache = Slim::Utils::Cache->new();
        if (my $cached_meta = $cache->get('yandex_meta_' . $track_id)) {
            return $cached_meta->{cover} if $cached_meta->{cover};
        }
    }
    
    return 'plugins/yandex/html/images/yandex.png';
}

sub canDoAction {
    my ($class, $client, $url, $action) = @_;
    return 1 if $action =~ /^(pause|stop|seek|rew|fwd)$/;
    return 0;
}

1;