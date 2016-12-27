package Net::Async::Github::RateLimit;

use strict;
use warnings;

use Net::Async::Github::RateLimit::Core;

sub new {
	my ($class, %args) = @_;
	$args{core} = Net::Async::Github::RateLimit::Core->new(%{ delete $args{resources}{core} });
	bless \%args, $class
}

sub core { shift->{core} }

1;

