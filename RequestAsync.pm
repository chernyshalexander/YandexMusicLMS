package Plugins::yandex::RequestAsync;

use strict;
use warnings;
use URI;
use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape_utf8);
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




sub post_form {
    my ($self, $url, $data, $callback, $error_callback) = @_;

    my $http = $self->_create_http_object(
        sub {
            my $http = shift;
            my $content = $http->content();
            my $json = eval { decode_json($content) };
            if ($@) {
                # Fallback for non-JSON response or error
                $callback->($content); 
            } else {
                $callback->($json);
            }
        },
        sub {
            my ($http, $error) = @_;
            $error_callback->($error);
        },
    );

    # Create a copy of default headers and override Content-Type
    my %headers = %{$self->{default_headers}};
    $headers{'Content-Type'} = 'application/x-www-form-urlencoded';

    # Manually encode data to x-www-form-urlencoded string
    # We need to handle array refs for keys like 'track-ids' which might appear multiple times
    # but based on python lib, it seems they just send it as standard form data.
    # Actually, Python's requests handles dictionary to form-data conversion. 
    # Let's use URI::Escape to build the query string.
    
    my @parts;
    foreach my $key (keys %$data) {
        my $val = $data->{$key};
        if (ref $val eq 'ARRAY') {
            foreach my $v (@$val) {
                 push @parts, uri_escape_utf8($key) . '=' . uri_escape_utf8($v);
            }
        } else {
            push @parts, uri_escape_utf8($key) . '=' . uri_escape_utf8($val);
        }
    }
    my $body = join('&', @parts);

    $http->post(
        $url, %headers,       
        $body,
    );
}


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
