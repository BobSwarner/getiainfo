#!/bin/perl

# Gather information on IA and organizes it into an Excel spreadsheet
# It will highlight the difference between systems
#
# pkginfo will collect information on IA specific packages for record keeping and comparisons
#
# Bob Swarner NCR 1/25/2012

use strict;
use warnings;
use Net::Ping;

use lib "./Packages";

use MySpreadsheet qw(WriteXLS);
use CommonUtils;
use PkgInfo;
use ConfigFiles;
use DBTables;

use POSIX qw(strftime);
use Data::Dumper;
use Getopt::Std;

my (%OPTS,%Modes);

$Modes{'pkginfo'} = {
	'class' => PkgInfo->new(),
	'execute' => '0',
};
$Modes{'conffiles'} = {
	'class' => ConfigFiles->new(),
	'execute' => '0',
};
$Modes{'dbtables'} = {
	'class' => DBTables->new(),
	'execute' => '0',
};

#---- TestConnections -----------------------------------------

sub TestConnections() {
	my $error = 0;
	
	my $p = Net::Ping->new('tcp',2);
        $p->{'port_num'} = 22;
	foreach my $server (keys %{$Settings{SERVERS}}) {
		if ($p->ping($server)) {
			my $connect_as = ConnectAs($server);
			Debug "Testing $server";
			my ($ret,@output) = RunCommand( $server, 'uname -n' );
			if ($ret != 0) {
				Info "ERROR: Cannot ssh to $server";
				$error = 1;
			} else {
				Info "Connection to $server is ok.";
			}
		} else {
			Info "ERROR: System $server does not respond to a ping";
			$error = 1;			
		}
	}
	return $error;
}

#---- SetSiteName -----------------------------------------------------

# If the site name has not yet been entered, prompt for it

sub SetSiteName() {
	while ($Settings{SITENAME} eq "") {
		print "Customer or Site name: ";
		$Settings{SITENAME} = <STDIN>;
		chomp $Settings{SITENAME};
	}
}

#==== MAIN ================================================

# setup a list of known modes and description
my $MODES = "";
foreach my $mode (sort keys %Modes) {
	$MODES = $MODES."	      $mode: $Modes{$mode}{class}->{DESCRIPTION}\n";
}

my $Usage = <<"EOUSAGE";

Usage: getiainfo.pl [-vhC] [-s site-settings] [-p packages] [-c configs] [-t dbtables] [-n "Site Name"] [-m <mode>[,<mode>]]
	-d: prints debugging messages
	-h: prints this messages and exits
	-s: site settings - including list of servers (required but defaults to $Settings{SETTINGSFILE})	
	-p: sets the file to use as list of packages (defaults to $Settings{PACKAGES}{FILE})	
	-t: sets the file to use as list of DB tables (defaults to $Settings{DBTABLES}{FILE})	
	-c: sets the file to use as list of config files (defaults to $Settings{CONFIGS}{FILE})	
        -C: tests ability to connect to each server in the server list and exits
	-n: set the site name for file naming.  Will prompt if not entered or in the settings file.
	-m: running mode.  Available modes are:
$MODES
EOUSAGE
# non-published options:
# -T - testing mode: Does not run commands - use local files to fake the interaction

if (!getopts('hds:p:t:c:n:Tm:C', \%OPTS)) {
	printf STDERR $Usage;
	exit 1;
}

if ($OPTS{h}) {
	print $Usage;
	exit 0;
}

$Settings{SETTINGSFILE} = $OPTS{s} if ($OPTS{s});
ReadSettingsFile();

$Settings{DEBUG} = $OPTS{d} if ($OPTS{d});
Debug "Debug messages are on.";
$Settings{TESTING} = $OPTS{T} if ($OPTS{T});
Debug "Testing mode is on.";
$Settings{MODE} = $OPTS{m} if ($OPTS{m});
Debug "Mode is $Settings{MODE}";

$Settings{PACKAGES}{FILE} = $OPTS{p} if ($OPTS{p});
$Settings{CONFIGS}{FILE} = $OPTS{c} if ($OPTS{c});
$Settings{DBTABLES}{FILE} = $OPTS{t} if ($OPTS{t});

# Run the Connection test if requested, then exit

if ($OPTS{C}) {
	my $ret = TestConnections();
	exit $ret;
}

# decipher mode if entered on command line
if ($Settings{MODE} ne "DEFAULT") {
	foreach my $mode (split /,/, $Settings{MODE}) {
		Debug "Enabling mode $mode";
		if (defined $Modes{$mode}) {
			$Modes{$mode}{execute} = 1;   # Set this mode to execute
		} else {
			Info "ERROR: $mode in not a valid mode.";
			print $Usage;
			exit 1;
		}
	}
} else {
	# no mode entered - set everything to their default
	foreach my $mode (keys %Modes) {
		$Modes{$mode}{execute} = 1;
	}
}

# Set Customer/site name
if ($OPTS{n}) {
	$Settings{SITENAME} = $OPTS{n};
	Debug "Site Name = $Settings{SITENAME}\n";
}

# Set current date/time
my $nowstring = strftime "%Y.%m.%d-%H.%M", localtime;

# First, initialize any mode we are planning to execute
foreach my $mode (sort keys %Modes) {
	if ($Modes{$mode}{execute}) {
		$Modes{$mode}{class}->Initialize();
	}
}

# Process each mode we know about and execute the routine if requested
SetSiteName();
foreach my $mode (sort keys %Modes) {
	if ($Modes{$mode}{execute}) {
		Info $Modes{$mode}{class}->{DESCRIPTION};
		my $tag = $Modes{$mode}{class}->{FILETAG};
		my $xls = "$Settings{SITENAME}-${nowstring}-${tag}.xls";
		Debug "XLS file name = $xls";
		my %datahash = ();
		$Modes{$mode}{class}->CollectData(\%datahash);
		Info "Writing XLS to $xls";
		$datahash{CONFIG}{FileName} = $xls;
		WriteXLS(\%datahash);
	}
}
#print Dumper(\%Settings);
Info "Finished";
