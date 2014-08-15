package CPANio::App;

use 5.010;
use Web::Simple;
use Plack::Response;
use Template;
use Path::Class;

# cache the various handlers
has handler => (
    is      => 'ro',
    default => sub { {} },
);

# default configuration
sub default_config {
    (   ui       => \"<html><body>\n[% content %]\n</body></html>",
        base_dir => dir(),
    );
}

sub BUILD {
    my ($self) = @_;
    my $config = $self->config;
    my $base   = dir( $config->{base_dir} );

    # generate the rest of the config from the defaults
    $config->{"${_}_dir"} //= $base->subdir($_)
        for qw( static doc templates );

    $config->{template} //= Template->new(
        INCLUDE_PATH => $config->{templates_dir},
    );
}

# the top-level dispatcher
sub dispatch_request {

    # we're a static site, so we only do GET
    sub (GET) {
        my ($self) = @_;

        # handler for static resources
        sub (/**.*) {
            my ( $self, $static, $env ) = @_;
            my $static_dir = dir( $self->config->{static_dir} );
            my $file = eval { file( $static_dir, $static )->resolve };

            # compute the response
            return if !$file;
            return Plack::Response->new(403)->finalize
                if !$static_dir->contains($file);
            return [ 200, [], $file->openr ];
        },

        # any .html will be wrapped in the default layout
        sub (.html | / | /**/) {
            response_filter {
                my ($res) = @_;

                # do not deal with streams
                return if ref $res->[2] ne 'ARRAY';

                my $tt = $self->config->{template};
                $tt->process(
                    $self->config->{ui},
                    { content => join( '', @{ $res->[2] } ) },
                    \( my $output = "" )
                ) or die $tt->error();
                $res->[2] = [$output];
                return $res;
            }
        },

        # each top-level directory is handled by a different module
        sub (/pulse/...) {
            my ( $self, $env ) = @_;
            my $app = $self->handler->{pulse} ||= do {
                require CPANio::App::Document;
                my $pulse_dir
                    = dir( $self->config->{base_dir} )->subdir('pulse');
                CPANio::App::Document->new(
                    config => { %{ $self->config }, doc_dir => $pulse_dir, }
                )->to_psgi_app;
            };
            $app->($env);
        },

        sub (/*/...) {
            my ( $self, $top, $env ) = @_;
            my $app = $self->handler->{$top} ||= do {
                eval { require "CPANio/App/\u$top.pm" }
                    or return Plack::Response->new(404)->finalize;
                "CPANio::App::\u$top"
                    ->new( config => $self->config )->to_psgi_app;
            };
            $app->($env);

        },

        # not found
        sub () { Plack::Response->new(404)->finalize }
    },

    # any other method is an error
    sub () { Plack::Response->new(405)->finalize }

}

1;
