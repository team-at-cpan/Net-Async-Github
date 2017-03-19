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

open my $missing, '>:encoding(UTF-8)', 'missing.lst' or die $!;
# List of all repos
my $user = shift;
my $repos = $gh->repos($user ? (owner => $user) : ())
    ->filter(sub { $_->{owner}{login} eq 'regentmarkets' })
    ->each(sub {
        printf "* %s has %d open issues and %d forks\n",
            $_->name,
            $_->open_issues_count,
            $_->forks_count;
            use Data::Dumper;
            print Dumper($_->owner);
        printf ">>> %s/%s\n", $_->owner->{login}, $_->name;
        $missing->print($_->name . "\n") unless -d '/home/git/regentmarkets/' . $_->name;
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
# also get branch info
    ->apply(sub {
        $_->flat_map('branches')
            ->each(sub {
                printf "found branch called %s\n", $_->name
            })
    })
    ->await;

