package Net::Async::Github;

use strict;
use warnings;

our $VERSION = '0.001';

use parent qw(IO::Async::Notifier);

=head1 NAME

Net::Async::Github

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

=cut

use Future;
use URI;
use URI::Template;
use JSON::MaybeXS;
use Syntax::Keyword::Try;

use File::ShareDir ();
use Log::Any qw($log);
use Path::Tiny ();

use Net::Async::Github::RateLimit;

my $json = JSON::MaybeXS->new;

=head2 configure

=cut

sub configure {
	my ($self, %args) = @_;
	for my $k (grep exists $args{$_}, qw(token)) {
		$self->{$k} = delete $args{$k};
	}
	$self->SUPER::configure(%args);
}

=head2 endpoints

=cut

sub endpoints {
	my ($self) = @_;
	$self->{endpoints} ||= $json->decode(
		Path::Tiny::path(
			'share/endpoints.json' //
			File::ShareDir::dist_file(
				'Net-Async-Github',
				'endpoints.json'
			)
		)->slurp_utf8
	);
}

=head2 endpoint

=cut

sub endpoint {
	my ($self, $endpoint, %args) = @_;
	URI::Template->new($self->endpoints->{$endpoint . '_url'})->process(%args);
}

=head2 http

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

=cut

sub auth_info {
	my ($self) = @_;
	if(my $key = $self->api_key) {
		return (
			user => $self->api_key,
			pass => '',
		);
	} elsif(my $token = $self->token) {
		return (
			headers => {
				Authorization => 'token ' . $token
			}
		)
	} else {
		die "need some form of auth, try passing a token or api_key"
	}
}

=head2 api_key

=cut

sub api_key { shift->{api_key} }

=head2 token

=cut

sub token { shift->{token} }

=head2 mime_type

=cut

sub mime_type { shift->{mime_type} //= 'application/vnd.github.v3+json' }

=head2 base_uri

=cut

sub base_uri { shift->{base_uri} //= URI->new('https://api.github.com') }

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

=head2 head

=cut

sub head {
    my ($self, %args) = @_;
    die "needs $_" for grep !$args{$_}, qw(owner repo branch);
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

=head2 http_get

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
        return { } if $resp->code == 204;
        return { } if 3 == ($resp->code / 100);
        try {
			warn "have " . $resp->as_string("\n");
            return Future->done($json->decode($resp->decoded_content))
        } catch {
            $log->errorf("JSON decoding error %s from HTTP response %s", $@, $resp->as_string("\n"));
            return Future->fail($@ => json => $resp);
        }
    })->else(sub {
        my ($err, $src, $resp, $req) = @_;
        $src //= '';
        if($src eq 'http') {
            $log->errorf("HTTP error %s, request was %s with response %s", $err, $req->as_string("\n"), $resp->as_string("\n"));
        } else {
            $log->errorf("Other failure (%s): %s", $src // 'unknown', $err);
        }
        Future->fail(@_);
    })
}

1;
