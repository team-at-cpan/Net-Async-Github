#!/usr/bin/env perl
use strict;
use warnings;

use Template;
use JSON::MaybeXS;
use Path::Tiny;

use List::Util qw(uniq);

my ($base) = @ARGV;
die "need a base" unless $base;
my $json = JSON::MaybeXS->new;
my $in = $json->decode(path('api.json')->slurp_utf8);

my $tt = Template->new;

for my $def (@{$in->{packages}}) {
	$def->{base} = $base;
    for(@{$def->{method_list}}) {
        ($_->{method_name} = $_->{name}) =~ s/([A-Z]+)/_\L$1/g ;
        if(($_->{type} // '') eq 'timestamp') {
            $_->{as} = 'Time::Moment';
            delete $_->{type};
        }
    }
	$def->{use_list} = [
	   	uniq map $_->{as},
	   		grep exists $_->{as}, @{$def->{method_list}}
	];

	$tt->process(\<<'EOF'
package Net::Async::[% base %]::[% package %];

use strict;
use warnings;

# VERSION

use parent qw(Net::Async::Github::Common);

=head1 NAME

Net::Async::[% base %]::[% package %]

=head1 DESCRIPTION

Autogenerated module.

=cut

[% IF use_list.size -%]
[%  FOREACH module IN use_list -%]
use [% module %] ();
[%  END -%]

[% END -%]
=head1 METHODS

=cut

[% FOREACH method IN method_list -%]
=head2 [% method.method_name %]

Provides an accessor for C<[% method.name %]>.

=cut

sub [% method.method_name %] {
[% IF method.as -%]
    $_[0]->{[% method.name %]} =
[%  SWITCH method.as -%]
[%   CASE 'Time::Moment' -%]
    (defined($_[0]->{[% method.name %]}) && length($_[0]->{[% method.name %]}) ? Time::Moment->from_string($_[0]->{[% method.name %]}) : undef)
[%   CASE -%]
     [% method.as %]->new($_[0]->{[% method.name %]})
[%  END -%]
        unless ref $_[0]->{[% method.name %]};
[% END -%]
    shift->{[% method.name %]}
[% SWITCH method.type -%]
[% CASE 'boolean' -%]
    ? 1 : 0
[% CASE -%]
[% END -%]
}

[% END -%]
1;

EOF
	, $def, 'lib/Net/Async/' . $base . '/' . $def->{package} . '.pm') or die $tt->error;
}


