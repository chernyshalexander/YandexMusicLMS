package Plugins::yandex::ProtocolHandler;

use strict;
use warnings;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

# 1. ОБЯЗАТЕЛЬНО: Подгружаем и наследуем HTTP.
# Это нужно, чтобы когда мы подменим ссылку на https, LMS знал, как её играть.
require Slim::Player::Protocols::HTTP;
use base qw(Slim::Player::Protocols::HTTP);

my $log = logger('plugin.yandex');

# --- Свойства ---

sub isRemote { 1 }     
sub isAudio { 1 }      
sub audioScanned { 1 } 
sub contentType { 'mp3' }
sub getFormatForURL { 'mp3' }
sub canSeek { 1 }

# --- 2. СКАНИРОВАНИЕ (Заглушка) ---
# LMS вызывает это ПЕРЕД проигрыванием.
# Если мы тут попытаемся сделать HTTP запрос к yandexmusic://, все упадет.
# Поэтому просто возвращаем фиктивные данные.
sub scanUrl {
    my ($class, $url, $args) = @_;
    $log->info("YANDEX: scanUrl request: $url");
    
    return {
        type    => 'mp3',
        bitrate => 192000, # Говорим LMS, что это mp3 192kbps
        length  => 0,      # Длительность пока неизвестна
    };
}

# --- 3. МЕТАДАННЫЕ ---
# Чтобы на экране было красиво
sub getMetadata {
    my ($class, $client, $url) = @_;

    my $id = $url;
    $id =~ s/^yandexmusic:\/\///;
    $id =~ s/^track\///;

    my $meta = {
        title    => "Yandex Track $id",
        artist   => "Yandex Music",
        type     => 'mp3',
        bitrate  => '192k',
    };
    
    # Быстро достаем инфу из кэша клиента (если есть)
    if (defined $Plugins::yandex::Plugin::ymClient) {
        eval {
             # Здесь можно использовать быстрый метод получения инфы
             # Но главное, чтобы он не вешал интерфейс
             my $info = $Plugins::yandex::Plugin::ymClient->get_tracks_info([$id]);
             if ($info && $info->[0]) {
                 my $t = $info->[0];
                 $meta->{title} = $t->{title};
                 $meta->{artist} = $t->{artists}->[0]->{name};
                 $meta->{duration} = int($t->{durationMs} / 1000);
                 if ($t->{coverUri}) {
                     my $c = $t->{coverUri}; $c =~ s/%%/200x200/;
                     $meta->{cover} = 'https://' . $c;
                 }
             }
        };
    }
    return $meta;
}

# --- 4. РЕЗОЛВИНГ (Самое важное) ---
# Мы используем getNextTrack вместо getStreamUrl.
# Задача этого метода: превратить yandexmusic://... в https://...
# И сказать LMS: "Я всё сделал, теперь играй новую ссылку".

sub getNextTrack {
    my ($class, $song, $successCb, $errorCb) = @_;

    my $url = $song->currentTrack()->url;
    $log->info("YANDEX: getNextTrack called for: $url");

    # 1. Парсим ID
    my $track_id = $url;
    if ($url =~ /yandexmusic:\/\/(?:track\/)?(\d+)/) {
        $track_id = $1;
    } else {
        $log->error("YANDEX: Can't parse ID");
        $errorCb->(); return;
    }

    my $ym_client = $Plugins::yandex::Plugin::ymClient;
    unless ($ym_client) {
        $log->error("YANDEX: Client not ready");
        $errorCb->(); return;
    }

    # 2. Получаем реальную ссылку
    my $stream_url;
    eval {
        my $track = Plugins::yandex::Track->new({ id => $track_id });
        $stream_url = $track->get_stream_url($ym_client);
    };

    if ($stream_url) {
        $log->info("YANDEX: URL resolved: $stream_url");
        
        # 3. ПОДМЕНА ССЫЛКИ!
        # Мы заменяем виртуальную ссылку на прямую HTTPS
        $song->streamUrl($stream_url);
        
        # 4. УСПЕХ
        # Вызываем callback. LMS увидит, что ссылка в $song изменилась на https://
        # И передаст управление стандартному модулю Slim::Player::Protocols::HTTP
        $successCb->();
    } else {
        $log->error("YANDEX: Failed to get URL");
        $errorCb->();
    }
}

# getStreamUrl нам больше не нужен, удаляем его, чтобы не путать LMS.

# --- Разрешения ---
sub canDoAction {
    my ($class, $client, $url, $action) = @_;
    return 1 if $action =~ /^(pause|stop|seek|rew|fwd)$/;
    return 0;
}

1;