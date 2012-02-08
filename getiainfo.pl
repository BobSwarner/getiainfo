#!/bin/perl

# Gather information on IA and organizes it into an Excel spreadsheet
# It will highlight the difference between systems
#
# pkginfo will collect information on IA specific packages for record keeping and comparisons
#
# Bob Swarner NCR 1/25/2012

use strict;
use Getopt::Std;
use Storable qw(store retrieve);
use Spreadsheet::WriteExcel;
use Date::Manip;
use Data::Dumper;

my $SERVER_LIST = "./server_list";
my $PACKAGE_LIST = "./package_list";
my $CONFIG_LIST = "./config_list";
my $DEBUG = 0;
my $TESTING = 0;
my $THISHOST = `uname -n`;
chomp $THISHOST;

my (@SERVERS,@PACKAGES,@CONFIGS,%CONFIG,%SSHUser,%OPTS,$SITENAME,$PKGXLS,$CONFXLS);

# HASH of values written to spreadsheet
# You do not need to worry about this unless you are changing the code
#
# HASH-> sheetname -+-> 'COLINDEX' -> columnname = #
#                   |
#                   +-> 'ROW' -> rowname -+-> 'INDEX' = #
#                                         |
#                                         +-> 'UNIQUES' = #
#                                         |
#                                         +-> 'DATA' ---> columnname -+-> 'VALUE' = text
#                                         |                           |
#                                         |                           +-> 'FORMAT' = #
#                                         |
#                                         +-> 'COMMENT' = text
#
    
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

        return if (!$DEBUG);
        Info( "DEBUG: $line" );
}

#---- RunLocalCommand -------------------------------------------------------------

sub RunLocalCommand( $ ) {
	my($cmd) = @_;

	my(@output,$ret);

	Debug( "Running: $cmd" );

	if ($TESTING) {
		@output = ( "---  TEST MODE - NO OUTPUT  ---\n" );
		$ret = 0;
	} else {
		if (!open( CMD, "$cmd 2>&1 |")) {
			Info( "Error running |$cmd|" );
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

#---- RunCommand -------------------------------------------------------------

sub RunCommand( $ $ ) {
	my($server,$cmd) = @_;

	#Debug "Running |$cmd| on $server";

	my(@output,$ret,$fullcmd);
	
	my ($local) = (($server eq "localhost") or ($server eq $THISHOST));

	if ($local) {
		$fullcmd = "$cmd";
	} else {
		my $connectas = ($SSHUser{$server} ? "$SSHUser{$server}\@$server" : $server ); # use username to connect as if it was provided
		$fullcmd = "ssh -o StrictHostKeyChecking=no $connectas $cmd";
	}

	($ret,@output) = RunLocalCommand( $fullcmd );

	return $ret, @output;
}

#---- ReadList --------------------------------------------

sub ReadList($) {
        my ($filename) = @_;

        my (@list);
        Debug "Reading list from $filename";
        open INPUT, "<$filename" or die "Error opening $filename\n";
        foreach (<INPUT>) {
                next if (/^#/);
                next if (/^\s*$/);
                s/^\s*//;
                s/\s*$//;
                push @list, $_;
        }
        close INPUT;
        Debug "Reading list complete";
        return @list;
}

#---- TempFile ---------------------------------------------

sub TempFile($$)
{
	my ($server,$type) = @_;

	return "tmp.$type.$server.dat";
}

#---- ProcessServerPkginfo --------------------------------

sub ProcessServerPkginfo($) {
    my ($server) = @_;
	my @KEYWORDS = ("VERSION", "PSTAMP", "INSTDATE", "STATUS");

    my ($pkgcount,$pkgtotal,$package,$type,$value,%pkginfo);
    my $ReadPackage = 0;
    
    Debug "Retrieving package info from $server";
	my ($ret,@input);
	
    if ($TESTING) {
	    open PKGINFO, "<$server.pkginfo.txt" or die "Error running pkginfo on $server\n";
	    @input = <PKGINFO>;
	    close PKGINFO;
	    $ret = 0;
    } else {
	    ($ret,@input) = RunCommand( $server, "pkginfo -l" );
    }
    
	if ($ret) {
		Info "FATAL: Error running pkginfo on $server";
		exit 1;
    }
    foreach (@input) {
        chomp;
        if (/^\s*PKGINST:\s*(\S+)/) {
            $pkgtotal++;
            $package = $1;
            if (grep ($_ eq $package, @PACKAGES)) {
	           	$pkgcount++;
	           	$ReadPackage = 1;
            } else {
	            $ReadPackage = 0;
            }
        } elsif ($ReadPackage) {
            if (/^\s*([A-Z]+):\s*(.+)$/) {
	            $type = $1;
	            $value = $2;
	            if (grep ($_ eq $type, @KEYWORDS)) {
		            # Special processing INSTDATE to remove time
		            if ($type eq "INSTDATE") {
		                my $outdate=ParseDate($value);
		                if (! $outdate) {
		                        Info "WARNING: Invalid INSTDATE ($value) in package $package.\n" ;
		                } else {
			                $value = UnixDate($outdate,"%b %d %Y");
		                }
	            	}
		            $pkginfo{$package}{$type} = $value;
            	}
            }
        }
    }
    Info "Read $pkgcount packages on $server (from $pkgtotal total)\n";
    
    # Save information to temp file for later processing
    my $outfile = TempFile($server,"pkginfo");
    Debug "Storing data for $server in $outfile";
    my $result = eval { store( \%pkginfo, $outfile ) };
	if( $@ ) {
		warn "Serious error from Storable: $@" ;
	} elsif( not defined $result ) {
		warn "I/O error from Storable: $!";
	}
	
    Debug "Package info from $server complete";
}

#---- MyWorksheetWrite -------------------------------------------

# intercept writes to the spreadsheet to capture max column widths
my (@COLMAX);

sub MyWorksheetWrite ($$$$$) {
	my ($worksheet, $row, $col, $text, $format) = @_;
	
	my $len = length $text;
	$COLMAX[$col] = $len if ($len > $COLMAX[$col]);
	$worksheet->write( $row, $col, $text, $format);	
}

#---- WriteSheet -------------------------------------------------

sub WriteSheet($$$$)
{
	my ($workbook,$sheetname,$sheetref,$formatref) = @_;
	my $worksheet = $workbook->add_worksheet($sheetname);
	my $ColumnStart = 2; # First column for actual data
	my $RowStart = 1; # First row of data
	
	@COLMAX = ();
	
    $worksheet->freeze_panes(1, $ColumnStart); # Freeze the col/rows for headers

	MyWorksheetWrite( $worksheet, 0, 0, "", $formatref->{head});	
	MyWorksheetWrite( $worksheet, 0, 1, "Uniques", $formatref->{head});	
	$worksheet->write_comment( 0, 1, 'This indicates the number of unique entries on each row.' );
	
	# Write column headers for this sheet
	foreach my $col (keys %{$sheetref->{COLINDEX}}) {
		MyWorksheetWrite( $worksheet, 0, $sheetref->{COLINDEX}{$col}+$ColumnStart, $col, $formatref->{head} );
	}
	
	# Enter each row into the spreadsheet
	foreach my $row (keys %{$sheetref->{ROW}}) {
		my $rownumber = $sheetref->{ROW}{$row}{INDEX} + $RowStart;
		# Row heading in column 0
		MyWorksheetWrite( $worksheet, $rownumber, 0, $row, $formatref->{head} );
		if ($sheetref->{ROW}{$row}{COMMENT}) {
			$worksheet->write_comment( $rownumber, 0, $sheetref->{ROW}{$row}{COMMENT} );
		}
		# Number of unique values for this row in column 1
		my $val = $sheetref->{ROW}{$row}{UNIQUES};
		my $format = ($val>1 ? $formatref->{red} : "" );
		MyWorksheetWrite( $worksheet, $rownumber, 1, $val, $format );
		foreach my $col (keys %{$sheetref->{ROW}{$row}{DATA}}) {
			my $colnumber = $sheetref->{COLINDEX}{$col}+$ColumnStart;
			my $val = $sheetref->{ROW}{$row}{DATA}{$col}{VALUE};
			my $formatnum = $sheetref->{ROW}{$row}{DATA}{$col}{FORMAT};
			my $format;
			if ($formatnum == 0) {
				$format = ""; # Most common value - no special formatting
			} else {
				$formatnum = ($formatnum-1)%($formatref->{NUM});  # cycle through the list of formats as needed
				$format = $formatref->{LIST}[$formatnum];
			}
			MyWorksheetWrite( $worksheet, $rownumber, $colnumber, $val, $format );		
		}
	}

	# set each column width based on the longest text written
	my $numcols = @COLMAX;
	my ($col,$width);
	for ($col=0; $col<$numcols; $col++) {
		$width = $COLMAX[$col] * 1.1; # rough factor to adjust for the font widths
		$width = 10 if ($width < 10);
		$worksheet->set_column($col, $col, $width)
	}
}

#---- WriteXLS ---------------------------------------------------

sub WriteXLS($$) {
	my ($XLSFile,$hashref) = @_;
	
    # Create a new workbook 
	Debug "Writing XLS to $XLSFile";	
    my $workbook  = Spreadsheet::WriteExcel->new($XLSFile);
    if (not defined $workbook) {
	    die "Error opening $XLSFile as an Excel workbook\n";
    }
    
    # Set formats to use
    my %formats;
    $workbook->set_custom_color(40, 211,  211,  211 ); # light gray
    $formats{head} = $workbook->add_format(bold=>1, bg_color=>40 );
	$formats{red} = $workbook->add_format( bg_color=>'Red' );	
	
	# create a list of formats to use to assign to uniques values in a row
	foreach my $color (qw/red cyan blue brown gray green lime magenta orange pink purple silver yellow/) {
		push @{$formats{LIST}}, $workbook->add_format( bg_color=>$color );
	}
	$formats{NUM} = scalar @{$formats{LIST}};
	
	foreach my $sheet (sort keys %{$hashref}) {
    	WriteSheet( $workbook, $sheet, \%{$hashref->{$sheet}}, \%formats );
	}
}

#---- ProcessUniques --------------------------------------

sub ProcessUniques($) {
	my ($hashref) = @_;
	
	foreach my $sheet (keys %{$hashref}) {
		foreach my $row (keys %{$hashref->{$sheet}{ROW}}) {
			my %valuehash;
			foreach my $col (keys %{$hashref->{$sheet}{ROW}{$row}{DATA}}) {
				my $value = $hashref->{$sheet}{ROW}{$row}{DATA}{$col}{VALUE};
				next if ((length $value) == 0);
				$valuehash{$value}++;
			}
			# we now have a list of all of the unique non-blank values for this row
			# sort the list by highest count to lowest
			my @tmplist = sort { $valuehash{$b} <=> $valuehash{$a} } keys %valuehash;

			# set the 'UNIQUES' value to a count of those unique values
			my $num = @tmplist;
			$hashref->{$sheet}{ROW}{$row}{UNIQUES} = $num;
			
			# create a new hash which points the value to the array index number
			# This will be used to decide which format to print the data in;
			my %formathash;
			for (my $count=0; $count<$num; $count++) {
				$formathash{$tmplist[$count]} = $count;
			}
			
			# now, add those format numbers to each column in the row
			foreach my $col (keys %{$hashref->{$sheet}{ROW}{$row}{DATA}}) {
				my $value = $hashref->{$sheet}{ROW}{$row}{DATA}{$col}{VALUE};
				$hashref->{$sheet}{ROW}{$row}{DATA}{$col}{FORMAT} = $formathash{$value};
			}
		}
	}
}

#---- ProcessIndexes --------------------------------------

# for each sheet, create a sort list of columns and rows used in the sheet
# use this sheet to assign an index value to be use for column/row assignments

sub ProcessIndexes($) {
	my ($hashref) = @_;
	
	foreach my $sheet (keys %{$hashref}) {
		my (%rowhash, %colhash, $row, $col);
		foreach $row (keys %{$hashref->{$sheet}{ROW}}) {
			$rowhash{$row} = 1;
			foreach $col (keys %{$hashref->{$sheet}{ROW}{$row}{DATA}}) {
				$colhash{$col} = 1;
			}
		}
		# now we have a list of rows and col used in this particular sheet
		# assign an index to each based on their sorted value
		my ($count,%rowindex);
		
		# The column index is added directly to the sheet hash
		$count = 0;
		foreach $col (sort keys %colhash) {
			$hashref->{$sheet}{COLINDEX}{$col} = $count++;
		}

		$count = 0;
		foreach $row (sort keys %rowhash) {
			$rowindex{$row} = $count++;
		}
				
		# now we have the row index, go through and put it in the sheet hash
		foreach $row (keys %{$hashref->{$sheet}{ROW}}) {
			$hashref->{$sheet}{ROW}{$row}{INDEX} = $rowindex{$row};
		}		
	}
}
#---- GetAllPackageInfo ---------------------------------------------------------

sub GetAllPackageInfo() {
	Info "Start Retrieving Package Info from all Servers ...";
	
	# Fork off one subprocess for each server to get the data in parallel
	my @pidlist;
	foreach my $server (sort @SERVERS) {
		my $pid = fork();
		if ($pid) {
			# parent
			Debug "Forked PID $pid\n";
			push(@pidlist, $pid);
		} elsif ($pid == 0) {
			# child
		    ProcessServerPkginfo( $server );
			exit(0);
		} else {
			die "couldn’t fork: $!\n";
		}
	}
	
	# Wait for each subprocess to finish
	foreach (@pidlist) {
		waitpid($_, 0);
	}
	
	my %pkginfo;
	
	# Retrieve the data from each server from the appropriate file
	# and put into a single hash
	foreach my $server (@SERVERS) {
		my $infile = TempFile($server,"pkginfo");
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
		
		foreach my $pkg (keys %{$tmpinfo}) {
			foreach my $sheet (keys %{$tmpinfo->{$pkg}}) {
				$pkginfo{$sheet}{ROW}{$pkg}{DATA}{$server}{VALUE} = $tmpinfo->{$pkg}{$sheet};
			}
		}
	}
	ProcessUniques(\%pkginfo);
	ProcessIndexes(\%pkginfo);
	Info "Start producing XLS to $PKGXLS";
	WriteXLS($PKGXLS,\%pkginfo);
}

#---- FindSSHUsers -----------------------------------------------

sub FindSSHUsers() {
	my (@tempservers) = @SERVERS;
	@SERVERS = ();
	%SSHUser = ();
	foreach my $data (@tempservers) {
		if ($data =~ /^(.+)@(.+)$/) {
			my $user = $1;
			my $server = $2;
			$SSHUser{$server} = $user;
			push @SERVERS, $server;
		} else {
			push @SERVERS, $data;
		}
	}
}

#---- IsRunningParamd -------------------------------------------

sub IsRunningParamd() {
	my $return = 0;
	if (!$TESTING) {
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
	$val =~ s/^\s*//;  # remove starting whitespace if any
	$val =~ s/\s*$//;  # remove ending whitespace if any
	$dataref->{$key} = $val;
}

#---- CheckSum ------------------------------------------------------

sub CheckSum($) {
	my ($dataref) = @_;

	my ($alldata,$sum);
	foreach my $key (sort keys %{$dataref}) {
		my $val = $dataref->{$key};
		$alldata = $alldata."$key=$val\n";
	}
	$sum = unpack("%32C*",$alldata) % 65535;
	return $sum;
}
	
#---- GetSetData ----------------------------------------------------------

#returns a checksum of the data

sub GetSetData($$$) {
	my ($dataref,$file,$id) = @_;
	
	my ($ret,@input) = RunLocalCommand ("iaparamc ARCHIVE ExportSet /$THISHOST/$file/$id" );
	if ($ret) {
		Info "FATAL: Error running: iaparamc ARCHIVE ExportSet /$THISHOST/$file/$id";
		exit 1;
	}
	foreach (@input) {
		ProcessKeyPair($dataref,$_);
	}	 
	my $sum = CheckSum($dataref);
	return $sum;
}

#----- PrintLocalConfig --------------------------------------

sub PrintLocalConfig() {
	Debug "Getting Local Configuration Information";	
	
	my $RunningParamd = IsRunningParamd();
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
	foreach my $server (sort @SERVERS) {
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
	foreach my $server (@SERVERS) {
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
	foreach (@CONFIGS) {
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

#---- GetAllConfigInfo ------------------------------------

sub GetAllConfigInfo() {
	my (%confinfo,$source,$sum,$EnterData,$column,$id);
	
	# Take all of the collected configuration information and put it in a hash
	# ready to output to the spreadsheet
	
	foreach my $file (keys %{ $CONFIG{FILE}}) {
		foreach my $server (@SERVERS) {
			$EnterData = 1;
			if ($CONFIG{FILE}{$file}{LOCALFILE}{$server}{EXISTS}) {
				my $hashref = \%{$CONFIG{FILE}{$file}{LOCALFILE}{$server}};
				$sum = $hashref->{CHECKSUM};
				$source = "Local File";
				my $column = "Local file on $server";
				AddDataColumn( \%{$confinfo{$file}}, $column, \%{$hashref->{DATA}} );
			} elsif ($CONFIG{FILE}{$file}{LOCALSET}{$server}{EXISTS}) {
				my $hashref = \%{$CONFIG{FILE}{$file}{LOCALSET}{$server}};
				my $id = $hashref->{ID};
				$sum = $hashref->{CHECKSUM};
				$source = "Local Set $id";
				my $column = "Local set ($id) for $server";
				AddDataColumn( \%{$confinfo{$file}}, $column, \%{$hashref->{DATA}} );
			} elsif ($CONFIG{FILE}{$file}{GLOBALSET}{EXISTS}) {
				my $hashref = \%{$CONFIG{FILE}{$file}{GLOBALSET}};
				my $id = $hashref->{ID};
				$sum = $hashref->{CHECKSUM};
				$source = "Global Set $id";
				my $column = "Global set ($id)";
				AddDataColumn( \%{$confinfo{$file}}, $column, \%{$hashref->{DATA}} );
			} else {
				$EnterData = 0;
			}
			if ($EnterData) {
				$confinfo{"0. SOURCE"}{ROW}{$file}{DATA}{$server}{VALUE} = $source;
				$confinfo{"0. SOURCE"}{ROW}{$file}{COMMENT} = $CONFIG{FILE}{$file}{LOCALFILE}{DIR};
				$confinfo{"1. CHECKSUM"}{ROW}{$file}{DATA}{$server}{VALUE} = $sum;
			}
		}
	}
	ProcessUniques(\%confinfo);
	ProcessIndexes(\%confinfo);
	Info "Start producing XLS to $CONFXLS";
	WriteXLS($CONFXLS,\%confinfo);
}

#---- TestConnections -----------------------------------------

sub TestConnections() {
	foreach my $server (@SERVERS) {
		Debug "Testing $server";
		my ($ret,@output) = RunCommand( $server, "uname -n" );
		if ($ret != 0) {
			Info "ERROR: Cannot connect to $server";
		} else {
			Info "Connection to $server is ok.";
		}
	}
}

#==== MAIN ================================================

my $Usage = <<"EOUSAGE";

Usage: getiainfo.pl [-vh] [-s server_list] [-p package_list] [-c config_list] [-n "Site Name"] [-m <mode>]
	-v: prints verbose debugging messages
	-h: prints this messages and exits
	-s: sets the file to use as list of server (defaults to $SERVER_LIST)	
	-p: sets the file to use as list of packages (defaults to $PACKAGE_LIST)	
	-c: sets the file to use as list of config files (defaults to $CONFIG_LIST)	
	-n: set the site name for file naming.  Will prompt if not entered.
	-m: running mode.  Available modes are:
	      connect-test: tests ability to connect to each server in the server list and then exits
	      pkginfo: generates pkginfo report only (this will be generated by default)
	      config: generages configuration file report only (this will be generated by default)
EOUSAGE
# non-published options:
# -T - testing mode: Does not run commands - use local files to fake the interaction

if (!getopts('hvs:p:c:n:Tm:', \%OPTS)) {
	printf STDERR $Usage;
	exit 1;
}

if ($OPTS{h}) {
	print $Usage;
	exit 0;
}

$DEBUG = $OPTS{v};
Debug "Debug messages are on.";
$TESTING = $OPTS{T};
Debug "Testing mode is on.";

$SERVER_LIST = ( $OPTS{s} ? $OPTS{s} : $SERVER_LIST );
$PACKAGE_LIST = ( $OPTS{p} ? $OPTS{p} : $PACKAGE_LIST );
$CONFIG_LIST = ( $OPTS{c} ? $OPTS{c} : $CONFIG_LIST );

# Read in the server list and pull out any specific ssh users
@SERVERS = ReadList( $SERVER_LIST );
FindSSHUsers();

# Do all tests by default
my $DoPkginfo = 1;
my $DoConfig = 1;

# decipher mode if entered on command line
if ($OPTS{m}) {
	my $mode = $OPTS{m};
	if ($mode eq "connect-test" ) {
		# if testing server connections, do so and then exit
		Info "Testing connections to servers in $SERVER_LIST";
		TestConnections();
		exit 0;
	} elsif ($mode eq "pkginfo" ) {
		$DoPkginfo = 1;
		$DoConfig = 0;
	} elsif ($mode eq "config" ) {
		$DoPkginfo = 0;
		$DoConfig = 1;
	} else {
		Info "ERROR: $mode in not a valid mode.";
		print $Usage;
		exit 1;
	}	
}

# Set Customer/site name, either from command line or prompting
if ($OPTS{n}) {
	$SITENAME = $OPTS{n};
} else {
	$SITENAME = "";
	while ($SITENAME eq "") {
		print "Customer or Site name: ";
		$SITENAME = <STDIN>;
		chomp $SITENAME;
	}
}
Debug "Site Name = $SITENAME\n";

# Set XLS file name based on customer name and current date/time - prompt for verification
my ($now,$nowstring);
$now=ParseDate("Now");
if (!$now) {
        Info "WARNING: Invalid current date returned.\n" ;
        $nowstring = "unknown";
} else {
    $nowstring = UnixDate($now,"%Y.%m.%d-%H.%M");
}

if ($DoPkginfo) {
	Info "Generating report for installed packages";
	$PKGXLS = "$SITENAME-pkginfo-$nowstring.xls";
	Info "Package info XLS file name = $PKGXLS";
	@PACKAGES = ReadList( $PACKAGE_LIST );
	GetAllPackageInfo();
}

if ($DoConfig) {
	Info "Generating report for configuration settings";
	$CONFXLS = "$SITENAME-config-$nowstring.xls";
	Info "Configuration info XLS file name = $CONFXLS";
	@CONFIGS = ReadList( $CONFIG_LIST );
	SetConfigInfo();
	GetAllConfigInfo();
}

Info "Finished";
