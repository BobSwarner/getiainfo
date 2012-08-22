#============================================================================
#==== Package CommonUtils ===================================================
#============================================================================

package CommonUtils;

use vars qw/@ISA @EXPORT %Settings/;

use strict;
use warnings;
use Data::Dumper;
use Carp;
use Sys::Hostname;

@ISA = 'Exporter';
@EXPORT = qw(Info Debug RunCommand TempFile %Settings ReadSettingsFile RunLocalCommand ConnectAs ReadList);

if (!$Settings{Initialized}) {
	$Settings{Initialized} = 1;
	$Settings{SETTINGSFILE} = "./getiainfo.conf";
	$Settings{DEBUG} = 0;
	$Settings{TESTING} = 0;
	$Settings{SITENAME} = "";
	$Settings{THISHOST} = hostname();
	$Settings{PACKAGES}{FILE} = "./Settings/package_list";
	$Settings{CONFIGS}{FILE} = "./Settings/config_list";
	$Settings{DBTABLES}{FILE} = "./Settings/dbtable_list";
	$Settings{CONFDBSID} = "confdb";
	$Settings{DBUSER} = "admin";
	$Settings{DBPWD} = "";
	$Settings{MODE} = "DEFAULT";
}

#---- TempFile ---------------------------------------------

sub TempFile($$)
{
	my ($server,$type) = @_;

	return "tmp.$type.$server.dat";
}

#---- Info ------------------------------------------------

sub Info($)
{
        my ($line) = @_;

        chomp $line;
        my $now = localtime;
        print "$now: $line\n";
}

#---- Debug ----------------------------------------------

sub Debug($)
{
        my ($line) = @_;

        return if (!$Settings{DEBUG});
        Info( "DEBUG: $line" );
}

#---- ReadList --------------------------------------------

sub ReadList($) {
        my ($filename) = @_;

        my @list = ();
	my $count = 0;
	my $total = 0;
        Debug "Reading $filename";
        if (!open INPUT, "<$filename") {
		croak "Error opening $filename - cannot continue";
	}
        foreach (<INPUT>) {
		$total++;
                next if (/^#/);
                next if (/^\s*$/);
                s/^\s*//;
                s/\s*$//;
                push @list, $_;
		$count++;
        }
        close INPUT;
        Debug "Reading list complete - Read $count data lines of $total total in file";
        return @list;
}

#---- RunLocalCommand -------------------------------------------------------------

sub RunLocalCommand( $ ) {
	my($cmd) = @_;

	my(@output,$ret);

	Debug( "Running: $cmd" );

	if ($Settings{TESTING}) {
		@output = ( "---  TEST MODE - NO OUTPUT  ---\n" );
		$ret = 0;
	} else {
		if (!open( CMD, "$cmd 2>&1 |")) {
			carp( "Error running |$cmd|" );
			$ret = -1;
		} else {
			@output = <CMD>;
			close CMD;
			$ret = $? >> 8;
		}
	}

	#Debug( "Command return code = $ret" );

	return $ret, @output;
}

#---- ConnectAs --------------------------------------------------------------

sub ConnectAs($) {
	my ($host) = @_;
	my $connect_as;
	
	my $user = $Settings{SERVERS}{$host};
	if ($user) {
		$connect_as = "$user\@$host";
	} else {
		$connect_as = "$host";
	}
	return $connect_as;
}

#---- RunCommand -------------------------------------------------------------

sub RunCommand( $ $ ) {
	my($server,$cmd) = @_;

	#Debug "Running |$cmd| on $server";

	my(@output,$ret,$fullcmd);
	
	my ($local) = (($server eq "localhost") or ($server eq $Settings{THISHOST}));

	if ($local) {
		$fullcmd = "$cmd";
	} else {
		my $connect_as = ConnectAs($server);
		$fullcmd = "ssh -o StrictHostKeyChecking=no -o BatchMode=yes $connect_as $cmd";
	}

	($ret,@output) = RunLocalCommand( $fullcmd );

	return $ret, @output;
}

#---- ReadSettingsFile --------------------------------------------------------------

sub ReadSettingsFile() {
	my ($settings_file) = $Settings{SETTINGSFILE};
	my ($key,$value);
	my $linenum = 0;
	my $error = 0;
	my $group = "";
	my @valid_groups = qw(SERVERS);
	my @valid_settings = qw(SITENAME DEBUG TESTING PACKAGES DBTABLES CONFIGS CONFDBSID DBUSER DBPWD MODE);
	
	Info "Reading settings from $settings_file";
	
	if (!open OPTFILE, "<$settings_file" ) {
		carp "Error opening $settings_file";
		$error = 1;
	} else {
		while (<OPTFILE>) {
			$linenum++;
			next if (/^\s*#/);  # skip comment lines
			next if (/^\s*$/);  # skip blank lines
			chomp;

			if (/^\s*(\S+)\s*:\s*$/) {
				my $temp = "\U$1"; # uppercase
				if (grep ($_ eq $temp, @valid_groups)) {
					$group = $temp;
				} else {
					carp "Invalid group in $settings_file at line number $linenum ($temp)\n";
					$error = 1;
				}
			} elsif (($key,$value) = /^\s*(\S+)\s*=\s*(.*?)\s*$/) {
					$key = "\U$key"; # converts to uppercase
					if (not grep ($_ eq $key, @valid_settings)) {
						carp "Invalid setting in $settings_file at line number $linenum ($key)\n";
						$error = 1;
					}
					$Settings{$key} = $value;
					$group = "";  # if we were in a group and now have a "setting", consider us no longer in the group
			} else {
				if (($group eq "SERVERS") and (/^\s*((\S+)@)?(\S+)\s*$/)) {
					my $host = $3;
					my $user = $2;
					$Settings{SERVERS}{$host} = $user;
				} else {
					carp "Invalid line in $settings_file at line number $linenum\n";
					$error = 1;
				}
			}
		}
		close OPTFILE;
	}
	if ($error) {
		croak "Cannot continue with errors in settings file";
	}
#	print Dumper(\%Settings);
}


1;
