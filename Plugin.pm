package Plugins::yandex::Plugin;

use strict;
use utf8;
use vars qw(@ISA);
use File::Basename;
use Cwd 'abs_path';
use File::Spec;
use feature qw(fc);
use Data::Dumper;
use JSON::XS::VersionOneAndTwo;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Player::Song;
use base qw(Slim::Plugin::OPMLBased);
use URI::Escape;
use URI::Escape qw(uri_escape_utf8);
use Encode qw(encode decode);
use Encode::Guess;
use Slim::Player::ProtocolHandlers;
use warnings;
use base qw(Slim::Plugin::OPMLBased);
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use utf8;
use URI::Escape;
use URI::Escape qw(uri_escape_utf8);
use Encode::Guess;
use Plugins::yandex::ClientAsync;
use Data::Dumper;

my $log;
$log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.yandex',
    'defaultLevel' => 'DEBUG',
    'description'  => string('PLUGIN_YANDEX'),
});


my $prefs = preferences('plugin.yandex');
# Добавляем переменную для хранения экземпляра клиента
my $yandex_client_instance;


sub initPlugin {
    my $class = shift;

    $prefs->init({
        token => '',
    });


    # Регистрация протокола
    $log->error("YANDEX INIT: Registering ProtocolHandler...");
    Slim::Player::ProtocolHandlers->registerHandler('yandexmusic', 'Plugins::yandex::ProtocolHandler');

    $class->SUPER::initPlugin(
        feed   => \&handleFeed,
        tag    => 'yandex',
        menu   => 'radios',
        weight => 50,
    );

    if (main::WEBUI) {
        require Plugins::yandex::Settings;
        Plugins::yandex::Settings->new();
    }
}

sub getDisplayName { 'Yandex Music' }

sub handleFeed {
    my ($client, $cb, $args) = @_;
    
    my $token = $prefs->get('token');
    #$log->info("handleFeed: token: $token");
    unless ($token) {
        $log->error("Токен не установлен. Проверьте настройки плагина.");
        $cb->([{
            name => 'Ошибка: токен не установлен',
            type => 'text',
        }]);
        return;
    }

    my $yandex_client = Plugins::yandex::ClientAsync->new($token);
    #$log->info("yandex_client created: yandex_client token: $token");

    $yandex_client->init(
        sub {
            #my $client_async = shift;
            $yandex_client_instance = shift;

            my @items = (
                {
                    name => 'Favorite tracks',
                    type => 'link',
                    url  => \&_handleLikedTracks,
                    passthrough => [$yandex_client_instance],
                },
            );

            $cb->(\@items);
        },
        sub {
            my $error = shift;
            $log->error("Initialization error: $error");
            $cb->([{
                name => "Error: $error",
                type => 'text',
            }]);
        },
    );
}
sub _handleLikedTracks {
    my ($client, $cb, $args, $yandex_client) = @_;

    $yandex_client->users_likes_tracks(
        sub {
            my $tracks = shift; # $tracks - это массив ВСЕХ объектов TrackShort

            # 1. Берем только первые 5 треков из общего списка.
            #    splice вернет массив из первых 5 элементов и изменит исходный массив $tracks.
            my @tracks_to_process = splice(@$tracks, 0, 5);
            my @all_items;
            # Если понравившихся треков нет (или меньше 2), @tracks_to_process будет содержать то, что есть.
            my $pending_requests = scalar @tracks_to_process;

            if ($pending_requests == 0) {
                $cb->({
                    items => [],
                    title => 'Favorite tracks',
                });
                return;
            }

            # 2. Итерируемся только по этим пяти трекам
            foreach my $track_short_obj (@tracks_to_process) {
                $track_short_obj->fetch_track(
                    sub { # Callback на успех
                        my $track_object_ref = shift;
                        my $track_object = ${$track_object_ref};

                        my $title = $track_object->{title} // 'Unknown';
                        my $artist = $track_object->{artists}[0]->{name} // 'Unknown';
                        my $track_id = $track_short_obj->{id};
                        my $track_url = 'yandexmusic://' . $track_id;

                        # 3. Добавляем элемент в финальный массив
                        push @all_items, {
                            name     => $artist . ' - ' . $title,
                            type     => 'audio',
                            url      => $track_url,
                            image    => 'plugins/yandex/html/images/foundbroadcast1_svg.png',
                        };
                        $log->debug(Dumper(@all_items));
                        $pending_requests--;
                        # 4. Когда все (до 5) запросы завершены, вызываем финальный callback
                        if ($pending_requests == 0) {
                            # splice здесь больше не нужен, мы и так работали только с нужным количеством
                            $cb->({
                                items => \@all_items, # Передаем весь массив, так как в нем не более 5 элементов
                                title => 'Favorite tracks',
                            });
                        }
                    },
                    sub { # Callback на ошибку
                        my $error = shift;
                        my $track_id = $track_short_obj->{id};
                        $log->error("Error fetching track $track_id: $error");

                        $pending_requests--;
                        if ($pending_requests == 0) {
                            $cb->({
                                items => \@all_items,
                                title => 'Favorite tracks',
                            });
                        }
                    }
                );
            }
        },
        sub { # Callback на случай, если не удалось получить список лайков
            my $error = shift;
            $log->error("Error retrieving favorite tracks list: $error");
            $cb->({
                items => [{
                    name => "Error: $error",
                    type => 'text',
                }],
                title => 'Favorite tracks',
            });
        },
    );
}
# sub _handleLikedTracks {
#     my ($client, $cb, $args, $yandex_client) = @_;

#     $yandex_client->users_likes_tracks(
#         sub {
#             my $tracks = shift; # $tracks - это массив объектов TrackShort

#             my @all_items;
#             my $pending_requests = scalar @$tracks;

#             if ($pending_requests == 0) {
#                 $cb->({
#                     items => [],
#                     title => 'Favorite tracks',
#                 });
#                 return;
#             }

#             foreach my $track_short_obj (@$tracks) {
#                 # Вызываем fetch_track у объекта TrackShort.
#                 # Он сам знает свой ID и как сделать запрос через клиента.
#                 $track_short_obj->fetch_track(
#                     sub { # Callback на успех
#                         my $track_object_ref = shift;
#                         my $track_object = ${$track_object_ref};

#                         my $title = $track_object->{title} // 'Unknown';
#                         my $artist = $track_object->{artists}[0]->{name} // 'Unknown';
#                         my $track_id = $track_short_obj->{id}; # ID можно взять из исходного объекта
#                         my $track_url = 'yandexmusic://' . $track_id;

#                         push @all_items, {
#                             name     => $artist . ' - ' . $title,
#                             type     => 'audio',
#                             url      => $track_url,
#                             image    => 'plugins/yandex/html/images/foundbroadcast1_svg.png',
#                         };

#                         $pending_requests--;
#                         if ($pending_requests == 0) {
#                             my @subset = splice(@all_items, 0, 5);
#                             $cb->({
#                                 items => \@subset,
#                                 title => 'Favorite tracks',
#                             });
#                         }
#                     },
#                     sub { # Callback на ошибку
#                         my $error = shift;
#                         my $track_id = $track_short_obj->{id};
#                         $log->error("Error fetching track $track_id: $error");

#                         $pending_requests--;
#                         if ($pending_requests == 0) {
#                             my @subset = splice(@all_items, 0, 5);
#                             $cb->({
#                                 items => \@subset,
#                                 title => 'Favorite tracks',
#                             });
#                         }
#                     }
#                 );
#             }
#         },
#         sub { # Callback на случай, если не удалось получить список лайков
#             my $error = shift;
#             $log->error("Error retrieving favorite tracks list: $error");
#             $cb->({
#                 items => [{
#                     name => "Error: $error",
#                     type => 'text',
#                 }],
#                 title => 'Favorite tracks',
#             });
#         },
#     );
# }
#  метод для доступа к клиенту из других модулей
sub getClient {
    return $yandex_client_instance;
}
1;
