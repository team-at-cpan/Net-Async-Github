package Net::Async::Github;

use strict;
use warnings;

our $VERSION = '0.001';

use parent qw(IO::Async::Notifier);

=head1 NAME

Net::Async::Github - support for L<https://github.com>'s REST API with L<IO::Async>

=head1 SYNOPSIS

 use IO::Async::Loop;
 use Net::Async::Github;
 my $loop = IO::Async::Loop->new;
 $loop->add(
  my $gh = Net::Async::Github->new(
   token => '...',
  )
 );

=head1 DESCRIPTION

This is a basic wrapper for Github's API.

=cut

use Future;
use URI;
use URI::QueryParam;
use URI::Template;
use JSON::MaybeXS;
use Time::Moment;
use Syntax::Keyword::Try;

use Ryu::Async;
use Net::Async::WebSocket::Client;

use Log::Any qw($log);

use Net::Async::Github::Repository;
use Net::Async::Github::RateLimit;

my $json = JSON::MaybeXS->new;

=head2 configure

Accepts the following optional named parameters:

=over 4

=item * C<token> - the Github API token

=item * C<endpoints> - hashref of L<RFC6570|https://tools.ietf.org/html/rfc6570>-compliant URL mappings

=item * C<http> - an HTTP client compatible with the L<Net::Async::HTTP> API

=item * C<mime_type> - the MIME type to use as the C<Accept> header for requests

=back

You probably just wanted C<token>.

=cut

sub configure {
    my ($self, %args) = @_;
    for my $k (grep exists $args{$_}, qw(token endpoints api_key http base_uri mime_type)) {
        $self->{$k} = delete $args{$k};
    }
    $self->SUPER::configure(%args);
}

=head2 reopen

Reopens the given PR.

Expects the following named parameters:

=over 4

=item * owner - which user or organisation owns this PR

=item * repo - which repo it's for

=item * id - the pull request ID

=back

Resolves to the current status.

=cut

sub reopen {
    my ($self, %args) = @_;
    die "needs $_" for grep !$args{$_}, qw(owner repo id);
    my $uri = URI->new('https://api.github.com/');
    $uri->path(
        join '/', 'repos', $args{owner}, $args{repo}, 'pulls', $args{id}
    );
    $self->request(
        PATCH => $uri,
        $json->encode({
            state => 'open',
        }),
        content_type => 'application/json',
        user => $self->api_key,
        pass => '',
        headers => {
            'Accept' => 'application/vnd.github.v3.full+json',
        },
    )
}

=head2 pr

Returns information about the given PR.

Expects the following named parameters:

=over 4

=item * owner - which user or organisation owns this PR

=item * repo - which repo it's for

=item * id - the pull request ID

=back

Resolves to the current status.

=cut

sub pr {
    my ($self, %args) = @_;
    die "needs $_" for grep !$args{$_}, qw(owner repo id);
    my $uri = URI->new('https://api.github.com/');
    $uri->path(
        join '/', 'repos', $args{owner}, $args{repo}, 'pulls', $args{id}
    );
    $self->request(
        GET => $uri,
        user => $self->api_key,
        pass => '',
        headers => {
            'Accept' => 'application/vnd.github.v3.full+json',
        },
    )
}

sub repos {
    my ($self, %args) = @_;
    $self->api_get_list(
        endpoint => 'current_user_repositories',
        class => 'Net::Async::Github::Repository',
    )
}

=head2 head

Identifies the head version for this branch.

Requires the following named parameters:

=over 4

=item * owner - which organisation or person owns the repo

=item * repo - the repository name

=item * branch - which branch to check

=back

=cut

sub head {
    my ($self, %args) = @_;
    die "needs $_" for grep !$args{$_}, qw(owner repo branch);
    die "invalid branch format" unless $args{branch} =~ m{^(\w+)/(\w+)$};
    my $uri = URI->new('https://api.github.com/');
    $uri->path(
        join '/', 'repos', $args{owner}, $args{repo}, qw(git refs heads), $args{branch}
    );
    $self->request(
        GET => $uri,
        user => $self->api_key,
        pass => '',
        headers => {
            'Accept' => 'application/vnd.github.v3.full+json',
        },
    )
}

=head2 update

=cut

sub update {
    my ($self, %args) = @_;
    die "needs $_" for grep !$args{$_}, qw(owner repo branch head);
    $self->validate_branch_name($args{branch});
    my $uri = URI->new('https://api.github.com/');
    $uri->path(
        join '/', 'repos', $args{owner}, $args{repo}, qw(merges)
    );
    $self->request(
        POST => $uri,
        $json->encode({
            head           => $args{head},
            base           => $args{branch},
            commit_message => "Merge branch 'master' into " . $args{branch},
        }),
        content_type => 'application/json',
        headers => {
            'Accept' => 'application/vnd.github.v3.full+json',
        },
    )
}

=head2 rate_limit

=cut

sub rate_limit {
    my ($self) = @_;
    $self->http_get(
        uri => $self->endpoint('rate_limit')
    )->transform(
        done => sub { Net::Async::Github::RateLimit->new(%{$_[0]}) }
    )
}

=head1 METHODS - Internal

The following methods are used internally. They're not expected to be
useful for external callers.

=head2 api_key

=cut

sub api_key { shift->{api_key} }

=head2 token

=cut

sub token { shift->{token} }

=head2 endpoints

Returns an accessor for the endpoints data. This is a hashref containing URI
templates, used by L</endpoint>.

=cut

sub endpoints {
    my ($self) = @_;
    $self->{endpoints} ||= do {
        require File::ShareDir;
        require Path::Tiny;
        $json->decode(
            Path::Tiny::path(
                'share/endpoints.json' //
                File::ShareDir::dist_file(
                    'Net-Async-Github',
                    'endpoints.json'
                )
            )->slurp_utf8
        );
    }
}

=head2 endpoint

Expands the selected URI via L<URI::Template>. Each item is defined in our C< endpoints.json >
file.

Returns a L<URI> instance.

=cut

sub endpoint {
    my ($self, $endpoint, %args) = @_;
    URI::Template->new($self->endpoints->{$endpoint . '_url'})->process(%args);
}

=head2 http

Accessor for the HTTP client object. Will load and instantiate a L<Net::Async::HTTP> instance
if necessary.

Actual HTTP implementation is not guaranteed, and the default is likely to change in future.

=cut

sub http {
    my ($self) = @_;
    $self->{http} ||= do {
        require Net::Async::HTTP;
        $self->add_child(
            my $ua = Net::Async::HTTP->new(
                fail_on_error            => 1,
                max_connections_per_host => 4,
                pipeline                 => 1,
                max_in_flight            => 4,
                decode_content           => 1,
                timeout                  => 30,
                user_agent               => 'Mozilla/4.0 (perl; Net::Async::Github; TEAM@cpan.org)',
            )
        );
        $ua
    }
}

=head2 auth_info

Returns authentication information used in the HTTP request.

=cut

sub auth_info {
    my ($self) = @_;
    if(my $key = $self->api_key) {
        return (
            user => $key,
            pass => '',
        );
    }
    if(my $token = $self->token) {
        return (
            headers => {
                Authorization => 'token ' . $token
            }
        )
    }

    die "need some form of auth, try passing a token or api_key"
}

=head2 mime_type

Returns the MIME type used for requests. Currently defined by github in
L<https://developer.github.com/v3/media/> as C<application/vnd.github.v3+json>.

=cut

sub mime_type { shift->{mime_type} //= 'application/vnd.github.v3+json' }

=head2 base_uri

The L<URI> for requests. Defaults to L<https://api.github.com>.

=cut

sub base_uri { shift->{base_uri} //= URI->new('https://api.github.com') }

=head2 http_get

Performs an HTTP GET request.

=cut

sub http_get {
    my ($self, %args) = @_;
    my %auth = $self->auth_info;

    if(my $hdr = delete $auth{headers}) {
        $args{headers}{$_} //= $hdr->{$_} for keys %$hdr
    }
    $args{$_} //= $auth{$_} for keys %auth;

    $log->tracef("GET %s { %s }", ''. $args{uri}, \%args);
    $self->http->GET(
        (delete $args{uri}),
        %args
    )->then(sub {
        my ($resp) = @_;
        $log->tracef("Github response: %s", $resp->as_string("\n"));
        return Future->done(
            { },
            $resp
        ) if $resp->code == 204;
        return Future->done(
            { },
            $resp
        ) if 3 == ($resp->code / 100);
        try {
            return Future->done(
                $json->decode(
                    $resp->decoded_content
                ),
                $resp
            );
        } catch {
            $log->errorf("JSON decoding error %s from HTTP response %s", $@, $resp->as_string("\n"));
            return Future->fail($@ => json => $resp);
        }
    })->else(sub {
        my ($err, $src, $resp, $req) = @_;
        $log->warnf("Github failed with error %s on source %s", $err, $src);
        $src //= '';
        if($src eq 'http') {
            $log->errorf("HTTP error %s, request was %s with response %s", $err, $req->as_string("\n"), $resp->as_string("\n"));
        } else {
            $log->errorf("Other failure (%s): %s", $src // 'unknown', $err);
        }
        Future->fail(@_);
    })
}

sub api_get_list {
    use Variable::Disposition qw(retain_future);
    use Scalar::Util qw(refaddr);
    use Future::Utils qw(fmap0);
    use namespace::clean qw(retain_future refaddr);

    my ($self, %args) = @_;
    my $label = $args{endpoint}
    ? ('Github[' . $args{endpoint} . ']')
    : (caller 1)[3];

    die "Must be a member of a ::Loop" unless $self->loop;

    # Hoist our HTTP API call into a source of items
    my $src = $self->ryu->source(
        label => $label
    );
    my $uri = $args{endpoint}
    ? $self->endpoint(
        $args{endpoint},
        %{$args{endpoint_args}}
    ) : URI->new(
        $self->base_uri . $args{uri}
    );

    my $per_page = (delete $args{per_page}) || 10;
#    $uri->query_param(
#        limit => $per_page
#    );
    my @pending = $uri;
    my $f = (fmap0 {
        my $uri = shift;
#        $uri->query_param(
#            before => $per_page
#        );
        $self->http_get(
            uri => $uri,
        )->on_done(sub {
            my ($data, $resp) = @_;
            # Handle paging - this takes the form of zero or more Link headers like this:
            # Link: <https://api.github.com/user/repos?page=2>; rel="next"
            if(my @links = $resp->header('Link')) {
                @links = map { split /\s*,\s*/, $_ } @links;
                for my $link (@links) {
                    if($link =~ m{<([^>]+)>; rel="next"}) {
                        push @pending, $1;
                    }
                }
            }

            $src->emit(
                $args{class}->new(
                    %$_,
                    ($args{extra} ? %{$args{extra}} : ()),
                    github => $self
                )
            ) for @{ $_[0] };
        })->on_fail(sub {
            warn "fail - @_";
            $src->fail(@_)
        })->on_cancel(sub {
            warn "cancel - @_";
            $src->cancel
        });
    } foreach => \@pending)->on_done(sub {
        $src->finish;
    });

    # If our source finishes earlier than our HTTP request, then cancel the request
    $src->completed->on_ready(sub {
        return if $f->is_ready;
        $log->tracef("Finishing HTTP request early for %s since our source is no longer active", $label);
        $f->cancel
    });

    # Track active requests
    my $refaddr = Scalar::Util::refaddr($f);
    retain_future(
        $self->pending_requests->push([ {
            id  => $refaddr,
            src => $src,
            uri => $args{uri},
            future => $f,
        } ])->then(sub {
            $f->on_ready(sub {
                retain_future(
                    $self->pending_requests->extract_first_by(sub { $_->{id} == $refaddr })
                )
            });
        })
    );
    $src
}

sub pending_requests {
    shift->{pending_requests} //= do {
        require Adapter::Async::OrderedList::Array;
        Adapter::Async::OrderedList::Array->new
    }
}

=head2 validate_branch_name

Applies validation rules from L<git-check-ref-format> for a branch name.

Will raise an exception on invalid input.

=cut

sub validate_branch_name {
    my ($self, $branch) = @_;
    die "branch is undef" unless defined $branch;
    die "branch contains path component with leading ." if $branch =~ m{/\.};
    die "branch contains double ." if $branch =~ m{\.\.};
    die "branch contains invalid character(s)" if $branch =~ m{[[:cntrl:][:space:]~^:\\]};
    die "branch ends with /" if substr($branch, -1) eq '/';
    die "branch ends with .lock" if substr($branch, -5) eq '.lock';
    return 1;
}

=head2 validate_owner_name

Applies github rules for user/organisation name.

Will raise an exception on invalid input.

=cut

sub validate_owner_name {
    my ($self, $owner) = @_;
    die "owner name not defined" unless defined $owner;
    die "owner name too long" if length($owner) > 39;
    die "owner name contains invalid characters" if $owner =~ /[^a-z0-9-]/i;
    die "owner name contains double hyphens" if $owner =~ /--/;
    die "owner name contains leading hyphen" if $owner =~ /^-/;
    die "owner name contains trailing hyphen" if $owner =~ /-$/;
    return 1;
}

=head2 validate_repo_name

Applies github rules for repository name.

Will raise an exception on invalid input.

=cut

sub validate_repo_name {
    my ($self, $repo) = @_;
    die "repo name not defined" unless defined $repo;
    die "repo name contains invalid characters" if $repo =~ /[^a-z0-9-]/i;
    die "repo name too long" if length($repo) > 100;
    return 1;
}

=head2 validate_args

Convenience method to apply validation on common parameters.

=cut

sub validate_args {
    my ($self, %args) = @_;
    $self->validate_branch_name($args{branch}) if exists $args{branch};
    $self->validate_owner_name($args{owner}) if exists $args{owner};
    $self->validate_repo_name($args{repo}) if exists $args{repo};
}

sub ryu { shift->{ryu} }

sub _add_to_loop {
    my ($self, $loop) = @_;

    $self->add_child(
        $self->{ryu} = Ryu::Async->new
    );

    $self->add_child(
        $self->{ws} = Net::Async::WebSocket::Client->new(
            on_raw_frame => $self->curry::weak::on_raw_frame,
            on_frame     => sub { },
        )
    );
}

1;

=head1 AUTHOR

Tom Molesworth <TEAM@cpan.org>

=head1 LICENSE

Copyright Tom Molesworth 2015-2017. Licensed under the same terms as Perl itself.

