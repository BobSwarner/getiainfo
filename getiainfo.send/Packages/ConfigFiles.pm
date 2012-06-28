#============================================================================
#==== Package ConfigFiles ===================================================
#============================================================================

package ConfigFiles;

use vars qw/@ISA @EXPORT/;

use strict;
use warnings;

use CommonUtils;

use Data::Dumper;
use Storable qw(store retrieve);

our (%CONFIG);

#@ISA = 'Exporter';
#@EXPORT = qw(GetAllConfigInfo);

my @ConfigList = ();

#---- IsRunningParamd -------------------------------------------

sub IsRunningParamd() {
	my $return = 0;
	if (!$Settings{TESTING}) {
		open PS, "ps -e -o comm 2>/dev/null|" or die "Error running ps command\n";
		while (<PS>) {
			$return = 1 if (/iaparamd/);
		}
		close PS;
	}
	Debug "IsRunningParamd() returning $return";
	return $return;
}

#---- GetGlobalSetInfo --------------------------------------------------------

sub GetGlobalSetInfo() {
	my (@list);
	
	# Get Global set info from iaparamc
	my ($ret,@input) = RunLocalCommand ("iaparamc ARCHIVE ListGlobalSets" );
	if ($ret) {
		Info "FATAL: Error running iaparamc for global";
		exit 1;
	}
	foreach (@input) {
		next if (/^[\s\0x00]*$/);
		chomp;
		@list = split;
		if ((scalar @list) != 2) {
			Info "WARNING: Invalid line from iaparamc (global) [$_]";
		}
		my $id = $list[0];
		my $file = $list[1];
		if ($CONFIG{FILE}{$file}) {
			$CONFIG{FILE}{$file}{GLOBALSET}{ID} = $id;
			$CONFIG{FILE}{$file}{GLOBALSET}{EXISTS} = 1;
			#Debug "Global set $file = $id";
		} else {
			Info "WARNING: Unknown file in iaparamd global sets = <$file>.";			
		}		
	}
}

#---- GetLocalSetInfo --------------------------------------------------------

sub GetLocalSetInfo() {
	# Get local set info from iaparamc
	my ($ret,@input) = RunLocalCommand ("iaparamc ARCHIVE ListLocalSets" );
	if ($ret) {
		Info "FATAL: Error running iaparamc for local";
		exit 1;
	}
	foreach (@input) {
		next if (/^[\s\0x00]*$/);
		chomp;
		my ($host,$id,$file,@comment) = split;
		if ($CONFIG{FILE}{$file}) {
			$CONFIG{FILE}{$file}{LOCALSET}{$host}{ID} = $id;
			$CONFIG{FILE}{$file}{LOCALSET}{$host}{EXISTS} = 1;
			#Debug "Local set $file on $host = $id";
		} else {
			Info "WARNING: Unknown file in iaparamd local sets = <$file>.";			
		}			
	}
}

#---- ProcessKeyPair ------------------------------------------------------------

sub ProcessKeyPair($$) {
	my ($dataref,$line) = @_;

	$line =~ s/\0//g; # remove null character
	$line =~ s/\/\/.*$//g; # remove comments
	return if ($line =~ /^\s*$/); # ignore blank lines
	my ($key,$val) = split /:/, $line, 2;
	$key =~ s/^\s*//;  # remove starting whitespace if any
	$key =~ s/\s*$//;  # remove ending whitespace if any
	if (defined $val) {
		$val =~ s/^\s+//;  # remove starting whitespace if any
		$val =~ s/\s+$//;  # remove ending whitespace if any
	} else {
		$val = "";
	}
	$dataref->{$key} = $val;
}

#---- CheckSum ------------------------------------------------------

sub CheckSum($) {
	my ($dataref) = @_;

	my $alldata = "";
	foreach my $key (sort keys %{$dataref}) {
		my $val = $dataref->{$key};
		$alldata = $alldata."$key=$val\n";
	}
	my $sum = unpack("%32C*",$alldata) % 65535;
	return $sum;
}
	
#---- GetSetData ----------------------------------------------------------

#returns a checksum of the data

sub GetSetData($$$) {
	my ($dataref,$file,$id) = @_;
	
	my ($ret,@input) = RunLocalCommand ("iaparamc ARCHIVE ExportSet /$Settings{THISHOST}/$file/$id" );
	if ($ret) {
		Info "FATAL: Error running: iaparamc ARCHIVE ExportSet /$Settings{THISHOST}/$file/$id";
		exit 1;
	}
	foreach (@input) {
		ProcessKeyPair($dataref,$_);
	}	 
	my $sum = CheckSum($dataref);
	return $sum;
}

#---- AddDataColumn ------------------------------------------------------

sub AddDataColumn($$$) {
	my ($sheetref,$column,$dataref) = @_;
	
	foreach my $key (keys %{$dataref}) {
		$sheetref->{ROW}{$key}{DATA}{$column}{VALUE} = $dataref->{$key};
	}
}

#---- GetFileFromServer -----------------------------------------------------------

sub GetFileFromServer($$$) {
	my ($serverref,$server,$path) = @_;

	my ($ret,@input) = RunCommand( $server, "cat $path" );
	if ($ret == 0) {
		foreach (@input) {
			ProcessKeyPair(\%{$serverref->{DATA}},$_);
		}	 
		$serverref->{EXISTS} = 1;
		$serverref->{CHECKSUM} = CheckSum(\%{$serverref->{DATA}});
	}		
}

#---- ProcessServerConfigInfo -----------------------------------------------

sub ProcessServerConfigInfo($) {
	my ($server) = @_;

    Debug "Collecting configuration info from $server";

	my (%fileinfo);
	foreach my $file (keys %{ $CONFIG{FILE}}) {
		my $dir = $CONFIG{FILE}{$file}{LOCALFILE}{DIR};
		my $fullpath = "$dir/$file";
		GetFileFromServer(\%{$fileinfo{$file}},$server,$fullpath);
	}
	#print Dumper( \%fileinfo );
	
	# Save information to temp file for later processing
    my $outfile = TempFile($server,"confinfo");
    Debug "Storing data for $server in $outfile";
    my $result = eval { store( \%fileinfo, $outfile ) };
	if( $@ ) {
		warn "Serious error from Storable: $@" ;
	} elsif( not defined $result ) {
		warn "I/O error from Storable: $!";
	}
	
    Debug "Configuration info from $server complete";
}

#---- CollectLocalFileInformation------------------------------

sub CollectLocalFileInformation() {
	Info "Collecting configuration file information from each server";
	
	# Fork off one subprocess for each server to get the data in parallel
	my @pidlist;
	foreach my $server (keys %{$Settings{SERVERS}}) {
		my $pid = fork();
		if ($pid) {
			# parent
			Debug "Forked PID $pid\n";
			push(@pidlist, $pid);
		} elsif ($pid == 0) {
			# child
		    ProcessServerConfigInfo( $server );
			exit(0);
		} else {
			die "couldn’t fork: $!\n";
		}
	}
	
	# Wait for each subprocess to finish
	foreach (@pidlist) {
		waitpid($_, 0);
	}
	
	# Retrieve the data from each server from the appropriate file
	# and put into a single hash
	foreach my $server (keys %{$Settings{SERVERS}}) {
		my $infile = TempFile($server,"confinfo");
	    if (-r $infile) {
			my $tmpinfo = eval { retrieve( $infile ) };
			if( $@ ) {
			    warn "Serious error from Storable: $@";
			} elsif( not defined $tmpinfo ) {
				warn "I/O error from Storable: $!";
			}
			# Remove the temporary file for this server
			if (unlink($infile) == 1) {
				Debug "$infile was removed.";
			} else {
			    Info "WARNING: File $infile could not be deleted.";
			}
		
			foreach my $file (keys %{$tmpinfo}) {
				if ($tmpinfo->{$file}{EXISTS}) {
					$CONFIG{FILE}{$file}{LOCALFILE}{$server} = $tmpinfo->{$file};
				}
			}
		}
	}
}
	
#---- SetConfigInfo ---------------------------------------------------

sub SetConfigInfo() {
	foreach (@ConfigList) {
		if (!/^\//) {
			Info "WARNING: Invalid config file entry ($_). Ignoring.";
		} else {
			my @list = split /\//;
			my $file = pop @list;
			my $dir = join '/',@list;
			#Debug "Config File = $file / Dir = $dir";
			$CONFIG{FILE}{$file}{LOCALFILE}{DIR} = $dir;
		}
	}
	
	# Find all sources of files.  
	
	$CONFIG{IAPARAMD}{RUNNING} = IsRunningParamd();
	if ($CONFIG{IAPARAMD}{RUNNING}) {
		Info "Collecting configuration information from parameter daemon";

		GetGlobalSetInfo();
		GetLocalSetInfo();

		# fetch the data associated with each Set ID identified
		foreach my $file (keys %{ $CONFIG{FILE}}) {
			#get global dataset if it exists for this file
			if ($CONFIG{FILE}{$file}{GLOBALSET}{EXISTS}) {
				my $sum = GetSetData( \%{$CONFIG{FILE}{$file}{GLOBALSET}{DATA}}, $file, $CONFIG{FILE}{$file}{GLOBALSET}{ID} );
				$CONFIG{FILE}{$file}{GLOBALSET}{CHECKSUM} = $sum;
				
			}
			
			# get the local dataset for each host it exists for on this file
			foreach my $host (keys %{ $CONFIG{FILE}{$file}{LOCALSET} }) {
				my $sum = GetSetData( \%{$CONFIG{FILE}{$file}{LOCALSET}{$host}{DATA}}, $file, $CONFIG{FILE}{$file}{LOCALSET}{$host}{ID} );
				$CONFIG{FILE}{$file}{LOCALSET}{$host}{CHECKSUM} = $sum;
			}
		}
	}

	# Find and process file stored on individual servers
	CollectLocalFileInformation();
}

#---- CollectData ------------------------------------

sub CollectData($$) {
	my ($self,$fullhash) = @_;
	my ($source,$sum,$EnterData,$column,$id);
	
	# Collect all configuration file information 
	SetConfigInfo();
	
	# Take all of the collected configuration information and put it in a hash
	# ready to output to the spreadsheet
	
	my $confinfo = \%{$fullhash->{DATA}};
	foreach my $file (keys %{ $CONFIG{FILE}}) {
		foreach my $server (keys %{$Settings{SERVERS}}) {
			$EnterData = 1;
			if ($CONFIG{FILE}{$file}{LOCALFILE}{$server}{EXISTS}) {
				my $hashref = \%{$CONFIG{FILE}{$file}{LOCALFILE}{$server}};
				$sum = $hashref->{CHECKSUM};
				$source = "Local File";
				my $column = "Local file on $server";
				AddDataColumn( \%{$confinfo->{$file}}, $column, \%{$hashref->{DATA}} );
			} elsif ($CONFIG{FILE}{$file}{LOCALSET}{$server}{EXISTS}) {
				my $hashref = \%{$CONFIG{FILE}{$file}{LOCALSET}{$server}};
				my $id = $hashref->{ID};
				$sum = $hashref->{CHECKSUM};
				$source = "Local Set $id";
				my $column = "Local set ($id) for $server";
				AddDataColumn( \%{$confinfo->{$file}}, $column, \%{$hashref->{DATA}} );
			} elsif ($CONFIG{FILE}{$file}{GLOBALSET}{EXISTS}) {
				my $hashref = \%{$CONFIG{FILE}{$file}{GLOBALSET}};
				my $id = $hashref->{ID};
				$sum = $hashref->{CHECKSUM};
				$source = "Global Set $id";
				my $column = "Global set ($id)";
				AddDataColumn( \%{$confinfo->{$file}}, $column, \%{$hashref->{DATA}} );
			} else {
				$EnterData = 0;
			}
			if ($EnterData) {
				$confinfo->{"0. SOURCE"}{ROW}{$file}{DATA}{$server}{VALUE} = $source;
				$confinfo->{"0. SOURCE"}{ROW}{$file}{COMMENT} = $CONFIG{FILE}{$file}{LOCALFILE}{DIR};
				$confinfo->{"1. CHECKSUM"}{ROW}{$file}{DATA}{$server}{VALUE} = $sum;
			}
		}
	}
}

#---- Initialize ----------------------------------------------

sub Initialize() {
        my $self = shift;
	
	@ConfigList = ReadList( $Settings{CONFIGS}{FILE} );
}

#---- new ------------------------------------------------------

sub new {
        my $proto = shift;
        my $class = ref($proto) || $proto;
        my $self  = {};
        bless ($self, $class);
	$self->{FILETAG} = 'conffiles';
	$self->{DESCRIPTION} = 'Generate a report of configuration files and settings';
        return $self;
}

#----------------
1;
