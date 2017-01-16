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

$gh->core_rate_limit->remaining->subscribe(sub {
    printf "Have %d Github requests remaining\n", $_;
});

# List of all repos
my $repos = $gh->repos
    ->each(sub {
        printf "* %s has %d open issues and %d forks\n",
            $_->name,
            $_->open_issues_count,
            $_->forks_count;
    })
# ... and aggregate stats
    ->apply(sub {
        $_->count
            ->each(sub {
                printf "Total of %d repos found\n", $_;
            })
    }, sub {
        $_->map('open_issues_count')
            ->sum
            ->each(sub {
                printf "Total of %d open issues found\n", $_;
            })
    }, sub {
        $_->map('forks_count')
            ->sum
            ->each(sub {
                printf "Total of %d forks found\n", $_;
            })
    })
    ->await;

