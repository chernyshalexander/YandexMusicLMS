package Plugins::yandex::RequestAsync;

use strict;
use warnings;
use URI;
use JSON;
use Slim::Utils::Log;
use Slim::Networking::SimpleAsyncHTTP;
my $log = logger('plugin.yandex');

sub new {
    my ($class, %args) = @_;

    my $self = {
        token => $args{token},
        proxy_url => $args{proxy_url},
        default_headers => {
            'User-Agent' => 'Yandex-Music-API',
            'X-Yandex-Music-Client' => 'YandexMusicAndroid/24023621',
            'Accept-Language' => 'ru',
            'Content-Type' => 'application/json',

             'Authorization' => "OAuth " . $args{token},
        },
    };

    bless $self, $class;
    return $self;
}

sub _create_http_object {
    my ($self, $callback, $error_callback) = @_;

    my $params = {
        headers => $self->{default_headers},
    };

    # if ($self->{proxy_url}) {
    #     warn "SOCKS5 не поддерживается напрямую. Используйте HTTP-прокси.";
    #     $params->{proxy} = $self->{proxy_url};
    # }

    return Slim::Networking::SimpleAsyncHTTP->new(
        $callback,
        $error_callback,
        $params,
    );
}

sub get {
    my ($self, $url, $params, $callback, $error_callback) = @_;

    my $uri = URI->new($url);
    #    $log->info("RequestAsync, 50, url:, $url");
    $uri->query_form($params) if $params;

    my $http = $self->_create_http_object(
        sub {
            my $http = shift;
            my $content = $http->content();
            my $json = eval { decode_json($content) };
            $callback->($json);
        },
        sub {
            my ($http, $error) = @_;
            $error_callback->($error);
        },
    );

    $http->get($uri, %{$self->{default_headers}},  );
}

sub post {
    my ($self, $url, $data, $callback, $error_callback) = @_;

    my $http = $self->_create_http_object(
        sub {
            my $http = shift;
            my $content = $http->content();
            my $json = eval { decode_json($content) };
            $callback->($json);
        },
        sub {
            my ($http, $error) = @_;
            $error_callback->($error);
        },
    );

    $http->post(
        $url, %{$self->{default_headers}},       
        encode_json($data),
    );
}





# --- ДОБАВИТЬ ЭТОТ НОВЫЙ МЕТОД ---
sub get_raw {
    my ($self, $url, $params, $callback, $error_callback) = @_;

    my $uri = URI->new($url);
    $uri->query_form($params) if $params;

    my $http = $self->_create_http_object(
        sub {
            my $http = shift;
            # Передаем колбэку СЫРОЕ содержимое (строку), а не декодированный JSON
            $callback->($http->content());
        },
        sub {
            my ($http, $error) = @_;
            $error_callback->($error);
        },
    );

    $http->get($uri, %{$self->{default_headers}},  );
}


1;
