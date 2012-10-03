#============================================================================
#==== Package DBTables ======================================================
#============================================================================

package DBTables;

use vars qw/@ISA @EXPORT/;

use strict;
use warnings;

use CommonUtils;
require DBI;
use Data::Dumper;

@ISA = 'Exporter';
@EXPORT = qw(GetDBTableInfo);

our %DBINFO = ();
our %TABLEDATA = ();
our ($DBUSER,$DBPWD,$DR_DC_OFFSET,$HAS_DR);
	
#---- ReadTable  ------------------------------------------------------------------

sub ReadTable($$$) {
	my ($dbh,$tablename,$order_by) = @_;

	Debug( "Reading in table $tablename - ordering by '$order_by'" );

	my (@alldata);
		
	my $sth = $dbh->prepare( "SELECT * FROM $tablename ORDER BY $order_by" );
	$sth->execute();
	$TABLEDATA{$tablename}{HEADER} = [ @{ $sth->{NAME_lc} } ];
	while (my $row = $sth->fetchrow_arrayref) {
		push @alldata, [ @$row ];
	}
	$TABLEDATA{$tablename}{DATA} = [ @alldata ];
	# close out this SQL statement
	$sth->finish();
	close OUT;
}

#---- GetDBInfo ------------------------------------------------------------

sub GetDBInfo($) {
	my ($type) = @_;
	
	# Open a connection to the DB
	my $dbname = $DBINFO{$type}{SID};
	my $dbh;

	Debug "Connecting to $dbname as $DBUSER";

	$dbh = DBI->connect('dbi:Oracle:'.$dbname, $DBUSER, $DBPWD, { PrintError => 0, AutoCommit => 0 } ) or
		die "Connect to database '$dbname' as '$DBUSER' failed: $DBI::errstr";
	
	$dbh->{RaiseError} = 1; # do this, or check every call for errors

	foreach my $tablename (keys %{$DBINFO{$type}{TABLES}}) {
		my $order_by = $DBINFO{$type}{TABLES}{$tablename};
		ReadTable($dbh,$tablename,$order_by);
	}
	$dbh->disconnect();
}

#---- ReadTestData --------------------------------------------------------

sub ReadTestData() {
	# read in static test data
	my $infile = "../test-data/DBTABLES.dat";
	open IN, "<$infile" or die "Error opening $infile: $!";
	my $temp = $/;
	undef $/;
	my $data = <IN>;
	close IN;
	$/ = $temp;
	my $VAR1; # need to eval Dumper data
	eval( $data );
	%TABLEDATA = %{$VAR1};
#	print Dumper( \%TABLEDATA );
}

#---- WriteTestData --------------------------------------------------------

sub WriteTestData() {
	my $testfile = "DBTABLES.dat";
    # Save information to temp file for later processing
	open OUT, ">$testfile" or die "Error writing to $testfile: $!";
	print OUT Dumper( \%TABLEDATA );
	close OUT;
}

#---- SetDBInfo ------------------------------------------------------------

sub SetDBInfo() {
	$DBUSER = $Settings{DBUSER};
	$DBPWD = $Settings{DBPWD};
	my $dbname = $DBINFO{CONFDB}{SID} = $Settings{CONFDBSID};

	if ((!defined $DBPWD) || ($DBPWD eq "")) {
		$| = 1; #auto flush STDOUT
		system("stty -echo"); # Turn off echo
		print "Enter password for oracle user '$DBUSER' on SID '$dbname':";
		chop($DBPWD=<STDIN>);
	        print "\n";
		system("stty echo"); # Turn on echo
	}

	
	my $dbh;

	return if ($Settings{TESTING});
	
	die "Environment variable \$ORACLE_HOME not available\n" unless $ENV{ORACLE_HOME};
	
	Debug "Connecting to $dbname as $DBUSER";

	$dbh = DBI->connect('dbi:Oracle:'.$dbname, $DBUSER, $DBPWD, { PrintError => 0, AutoCommit => 0 } ) or
		die "Connect to database '$dbname' as '$DBUSER' failed: $DBI::errstr";
	
	$dbh->{RaiseError} = 1; # do this, or check every call for errors

	my ($sth,$value);

	# Find MasterDB SID in ConfDB
	$sth = $dbh->prepare( "select CONFIG_VALUE from IAD_CONFIG_DATA WHERE GROUP_NAME='database' AND CONFIG_NAME='MasterDatabaseName'" );
	die "Error:<$DBI::errstr> in prepare" if( $dbh->err );
	$sth->execute();
	die "Error:<$DBI::errstr> in execute" if( $dbh->err );
    	$sth->bind_columns( \$value );
    	if ($sth->fetch) {
		$DBINFO{MASTERDB}{SID} = $value;
	} else {
		die "Error retrieving MASTERDB SID";
	}
	$sth->finish();
	Debug "MasterDB SID set to $DBINFO{MASTERDB}{SID}";
	
	# Find DR Dispcode offset in ConfDB
	$sth = $dbh->prepare( "select CONFIG_VALUE from IAD_CONFIG_DATA WHERE GROUP_NAME='archive' AND CONFIG_NAME='DR_DC_Offset'" );
	die "Error:<$DBI::errstr> in prepare" if( $dbh->err );
	$sth->execute();
	die "Error:<$DBI::errstr> in execute" if( $dbh->err );
    	$sth->bind_columns( \$value );
    	if ($sth->fetch) {
		$DR_DC_OFFSET = $value;
		Debug "DR DISPCODE OFFSET set to $DR_DC_OFFSET";
		$HAS_DR = 1;
	} else {
		Info "Error retrieving DR_DC_OFFSET - Assuming no DR is configured.";
		$HAS_DR = 0;
	}
	$sth->finish();
	
	$dbh->disconnect();
}

#---- ConvertTableData --------------------------------------------------------

sub ConvertTableData($) {
	my ($dbtables) = @_;
	my ($count);
	
	foreach my $table (keys %TABLEDATA) {
		my @header = @{$TABLEDATA{$table}{HEADER}};
		my $num = @header;
		# presetup column indexes for spreadsheet
		for ($count=0; $count<$num; $count++) {
			$dbtables->{$table}{COLUMN}{$header[$count]}{INDEX} = $count;
		}
		$count = 0;
		foreach my $row (@{$TABLEDATA{$table}{DATA}}) {
			for (my $i=0; $i<$num; $i++) {
				my $datum = @{$row}[$i];
				if (defined $datum) {
					$datum =~ s/\s+$//;  #trim trailing blanks
				} else {
					$datum = "";
				}
				$dbtables->{$table}{ROW}{$count}{DATA}{$header[$i]}{VALUE} = $datum;
			}
			$dbtables->{$table}{ROW}{$count}{INDEX} = $count;
			$count++;
		}
	}
	
}

#-----AddDispTable ---------------------------------------------------------------------

sub AddDispTable($$) {
	my ($dispref,$table) = @_;
	
# dispref-+->{COLUMN}-->{column_name} -+-> 'INDEX' = index #
#         |                            |
#         |                            +-> 'COMMENT' = comment
#         |
#         +->{NUM} = number of columns
#         |
#         +->{DATA}--->{dispcode (primary only)}--->{type (PRIM or DR)}--->{column_name} = value;

	# if this is the first one, add a column index for disp code
	my $first = 1;
	if (!defined $dispref->{COLUMN}{dispcode}) {
		$dispref->{COLUMN}{dispcode}{INDEX} = 0;
		$dispref->{NUM} = 1;
		$first = 1;
	}
	
	# go through the table and add columns and data as needed
	my @header = @{$TABLEDATA{$table}{HEADER}};
	my $num = @header;
	my $disp_col = -1;
	for (my $count=0; $count<$num; $count++) {
		if ("\U$header[$count]" ne "DISPCODE") {
			$dispref->{COLUMN}{$header[$count]}{INDEX} = $dispref->{NUM}++;
			$dispref->{COLUMN}{$header[$count]}{COMMENT} = "from $table table";
		} else {
			$disp_col = $count;
		}
	}
	if ($disp_col < 0) {
		Info "Error finding dispcode in table $table";
		exit 1;
	}
	
	foreach my $row (@{$TABLEDATA{$table}{DATA}}) {
		my $index = @{$row}[$disp_col];
		my $type = "PRIM";
		if ($HAS_DR && ($index > $DR_DC_OFFSET)) {
			$index = $index - $DR_DC_OFFSET;
			$type = "DR";
		}
		for (my $i=0; $i<$num; $i++) {
			next if (($i == $disp_col) && (!$first));
			my $datum = @{$row}[$i];
			if (defined $datum) {
				$datum =~ s/\s+$//;  #trim trailing blanks
			} else {
				$datum = "";
			}
			$dispref->{DATA}{$index}{$type}{$header[$i]} = $datum;
		}
	}
	
}
#---- CreateProcessedDispCodePage -----------------------------------------------------

sub CreateProcessedDispCodePage($) {
	my ($dbtables) = @_;

	my (%proctable);
	my $newtable = "0. DISPCODE (PROCESSED)";
	my $alternate_format = 2;
	
	AddDispTable(\%proctable,'DISP_CODE');
	AddDispTable(\%proctable,'APP_CODE');
	AddDispTable(\%proctable,'CENTERA_INFO');

	my @column_list = keys %{$proctable{COLUMN}};

	foreach my $col (@column_list) {
		$dbtables->{$newtable}{COLUMN}{$col}{INDEX} = $proctable{COLUMN}{$col}{INDEX};
		$dbtables->{$newtable}{COLUMN}{$col}{COMMENT} = $proctable{COLUMN}{$col}{COMMENT};
	}

	# add data to new table while creating new index and alternating format based on grouped disp codes
	my $row_count = 0;
	my $dispcode_count = 0;
	foreach my $code (sort { $a <=> $b } keys %{$proctable{DATA}}) {  # force numeric sort
		my $hashref = $proctable{DATA}{$code};
		my $row_format = ( $dispcode_count % 2 ? 0 : $alternate_format );
		foreach my $type (qw/PRIM DR/) {
			my $row = sprintf( "ROW%5.5d", $row_count );
			$dbtables->{$newtable}{ROW}{$row}{INDEX} = $row_count;
			foreach my $col (@column_list) {
				$dbtables->{$newtable}{ROW}{$row}{DATA}{$col}{VALUE} = $proctable{DATA}{$code}{$type}{$col};
				$dbtables->{$newtable}{ROW}{$row}{DATA}{$col}{FORMAT} = $row_format;
			}
			$row_count++;
		}
		$dispcode_count++;
	}
	$dbtables->{$newtable}{COLFREEZEOVERIDE} = 1;
}


#---- GetTableList -----------------------------------------------------------

sub GetTableList() {
	my (@rawlist,$error);
	
	Debug "Getting DB tables information";
	
	$error = 0;
	@rawlist = ReadList( $Settings{DBTABLES}{FILE} );
	foreach my $rawline (@rawlist) {
		my ($count,@list);
		$count = (@list) = split /:/, $rawline;
		if ($count != 3) {
			Info "Invalid number of items in $Settings{DBTABLES}{FILE}";
			Info "Line = $rawline";
			$error = 1;
		} else {
			#convert to uppercase
			for (my $i=0; $i<$count; $i++) {$list[$i] = "\U$list[$i]" };
			if (($list[0] ne "CONFDB") && ($list[0] ne "MASTERDB")) {
				Info "$list[0] is not a valid DB designation";
				$error = 1;
			} else {
				$DBINFO{$list[0]}{TABLES}{$list[1]} = $list[2];
			}
		}
				
	}
	if ($error) {
		Info "Error(s) reading $Settings{DBTABLES}{FILE} - stopping";
		exit 1;
	}
}

#---- CollectData -------------------------------------------------------

sub CollectData($) {
	my ($self,$dbtables) = @_;	

	if ($Settings{TESTING}) {
		# Read in test data
		ReadTestData();
		$DR_DC_OFFSET = 5000;
		$HAS_DR = 1;
	} else {

		foreach my $dbtype (keys %DBINFO) {
			GetDBInfo($dbtype);
		}
		
#		WriteTestData(); # Save TABLEDATA to file for testing uses
	}
	ConvertTableData(\%{$dbtables->{DATA}});
	CreateProcessedDispCodePage(\%{$dbtables->{DATA}});
	$dbtables->{CONFIG}{ProcessUniques} = 0;
	$dbtables->{CONFIG}{PrintRowHeader} = 0;
	$dbtables->{CONFIG}{ProcessIndexes} = 0;
}

#---- Initialize ----------------------------------------------

sub Initialize() {
        my $self = shift;
	
        $self->GetTableList();
        $self->SetDBInfo();	
}

#---- new ------------------------------------------------------

sub new {
        my $proto = shift;
        my $class = ref($proto) || $proto;
        my $self  = {};
        bless ($self, $class);
	$self->{FILETAG} = 'dbtables';
	$self->{DESCRIPTION} = 'Generate a report of interesting DB tables';
        return $self;
}

#================
1;
