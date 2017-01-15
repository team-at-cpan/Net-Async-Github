package Net::Async::Github::Common;
use strict;
use warnings;

=head2 new

Instantiates.

=cut

sub new {
	my $self = bless { @_[1..$#_] }, $_[0];
	die "no ->github provided" unless $self->github;
	$self
}

sub github { shift->{github} }

1;

