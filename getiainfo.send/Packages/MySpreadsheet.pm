#============================================================================
#==== Package MySpreadsheet =================================================
#============================================================================

package MySpreadsheet;

use vars qw/@ISA @EXPORT/;

use strict;
use Spreadsheet::WriteExcel;
use Data::Dumper;

@ISA = 'Exporter';
@EXPORT = qw(WriteXLS);


my (%known_config_defaults);
$known_config_defaults{ProcessUniques} = 1;
$known_config_defaults{PrintRowHeader} = 1;
$known_config_defaults{ProcessIndexes} = 1;

# HASH of values used by WriteXLS
# You do not need to worry about this unless you are changing the code
#
#                  +-> 'PrintRowHeader' = 0/1
#                  |
#                  +-> 'FileName' = XLS filename
#                  |
#      +   CONFIG -+-> 'ProcessUniques' = 0/1
#      |
# HASH-+-> DATA --->sheetname -+-> 'COLUMN' -> columnname -+-> 'INDEX' = # (set by ProcessIndexes)
#                              |                           |
#                              |                           +-> 'COMMENT' = text
#                              |                          
#                              |
#                              +-> 'COLFREEZEOVERIDE' = column # to freeze
#                              |
#                              +-> 'ROW' -> rowname -+-> 'INDEX' = # (set by ProcessIndexes)
#                                                    |
#                                                    +-> 'UNIQUES' = # (set by ProcessUniques)
#                                                    |
#                                                    +-> 'DATA' ---> columnname -+-> 'VALUE' = text
#                                                    |                           |
#                                                    |                           +-> 'FORMAT' = # (set by ProcessUniques)
#                                                    |
#                                                    +-> 'COMMENT' = text
#

#---- MyWorksheetWrite -------------------------------------------

# intercept writes to the spreadsheet to capture max column widths
my (@COLMAX);

sub MyWorksheetWrite ($$$$$) {
	my ($worksheet, $row, $col, $text, $format) = @_;
	
	my $len = length $text;
	$COLMAX[$col] = $len if ($len > $COLMAX[$col]);
	$worksheet->write( $row, $col, $text, $format);	
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
			$hashref->{$sheet}{COLUMN}{$col}{INDEX} = $count++;
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

#---- WriteSheet -------------------------------------------------

sub WriteSheet($$$$$)
{
	my ($workbook,$sheetname,$sheetref,$formatref,$configref) = @_;
	my $worksheet = $workbook->add_worksheet($sheetname);
	my $RowStart = 1; # First row of data
	
	
	@COLMAX = ();
	
	my $ColumnStart = 0;
	if ($configref->{PrintRowHeader}) {
		MyWorksheetWrite( $worksheet, 0, 0, "", $formatref->{head});
		$ColumnStart++;
	}
	if ($configref->{ProcessUniques}) {
		MyWorksheetWrite( $worksheet, 0, 1, "Uniques", $formatref->{head});	
		$worksheet->write_comment( 0, 1, 'This indicates the number of unique entries on each row.' );
		$ColumnStart++;
	}

	my $freeze_col = $ColumnStart;
	if (defined $sheetref->{COLFREEZEOVERIDE}) {
		$freeze_col = $sheetref->{COLFREEZEOVERIDE};
	}
	$worksheet->freeze_panes(1, $freeze_col); # Freeze the col/rows for headers
		
	# Write column headers for this sheet
	foreach my $col (keys %{$sheetref->{COLUMN}}) {
		my $column_number = $sheetref->{COLUMN}{$col}{INDEX} + $ColumnStart;
		MyWorksheetWrite( $worksheet, 0, $column_number, $col, $formatref->{head} );
		if ($sheetref->{COLUMN}{$col}{COMMENT}) {
			$worksheet->write_comment( 0, $column_number, $sheetref->{COLUMN}{$col}{COMMENT} );
		}
	}
	
	# Enter each row into the spreadsheet
	foreach my $row (keys %{$sheetref->{ROW}}) {
		my $rownumber = $sheetref->{ROW}{$row}{INDEX} + $RowStart;
		# Row heading in column 0
		MyWorksheetWrite( $worksheet, $rownumber, 0, $row, $formatref->{head} ) if ($configref->{PrintRowHeader});
		if ($sheetref->{ROW}{$row}{COMMENT}) {
			$worksheet->write_comment( $rownumber, 0, $sheetref->{ROW}{$row}{COMMENT} );
		}
		# Number of unique values for this row in column 1
		my $val = $sheetref->{ROW}{$row}{UNIQUES};
		my $format = ($val>1 ? $formatref->{red} : "" );
		MyWorksheetWrite( $worksheet, $rownumber, 1, $val, $format );
		foreach my $col (keys %{$sheetref->{ROW}{$row}{DATA}}) {
			my $colnumber = $sheetref->{COLUMN}{$col}{INDEX}+$ColumnStart;
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

#---- ProcessConfigs -------------------------------------------------

sub ProcessConfigs($) {
	my ($configref) = @_;
	
	foreach my $setting (keys %known_config_defaults) {
		if (!defined $configref->{$setting}) {
			$configref->{$setting} = $known_config_defaults{$setting};
		}
	}
}
#---- WriteXLS ---------------------------------------------------

sub WriteXLS($) {
	my ($fullhashref) = @_;
	
	my ($dataref,$configref,$XLSFile);
	
	$dataref = \%{$fullhashref->{DATA}};
	$configref = \%{$fullhashref->{CONFIG}};
	$XLSFile = $configref->{FileName};
	ProcessConfigs($configref);  # set defaults for undefined settings
	
	# Create a new workbook 
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

	ProcessUniques($dataref) if ($configref->{ProcessUniques});
	ProcessIndexes($dataref) if ($configref->{ProcessIndexes});
		
	foreach my $sheet (sort keys %{$dataref}) {
    	WriteSheet( $workbook, $sheet, \%{$dataref->{$sheet}}, \%formats, $configref );
	}
}


1;
