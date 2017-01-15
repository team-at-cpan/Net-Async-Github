#!/usr/bin/env perl
use strict;
use warnings;
use feature qw(say);

use IO::Async::Loop;
use Net::Async::Github;
use Time::Duration;

use Log::Any::Adapter qw(Stdout), log_level => 'info';

my $token = shift or die "need a token";
my $loop = IO::Async::Loop->new;
$loop->add(
	my $gh = Net::Async::Github->new(
		token => $token,
	)
);

my $repos = $gh->repos
    ->each(sub {
        printf "* %s has %d open issues and %d forks\n", $_->name, $_->open_issues_count, $_->forks_count;
    })
    ->count
    ->each(sub {
        printf "Total of %d repos found\n", $_;
    })
    ->await;

