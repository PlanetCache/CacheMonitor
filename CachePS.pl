#!/usr/bin/perl

use strict;

my $env = $ARGV[0];
my $pid = $ARGV[1];

print "Username:";
my $username = <STDIN>;
print "\nPassword:";
my $password = <STDIN>;

my $val = `csession $env <<done
$username
$password

THIS^%SS
h
done`;


