#============================================================================
#==== Package PkgInfo =======================================================
#============================================================================

package PkgInfo;

use vars qw/@ISA @EXPORT/;

use strict;
use warnings;

use CommonUtils;

use Data::Dumper;
use Storable qw(store retrieve);

@ISA = 'Exporter';
@EXPORT = qw(GetAllPackageInfo);

my @PackageList = ();

#---- ProcessServerPkginfo --------------------------------

sub ProcessServerPkginfo($) {
    my ($server) = @_;
	my @KEYWORDS = ("VERSION", "PSTAMP", "INSTDATE", "STATUS");

    my ($pkgcount,$pkgtotal,$package,$type,$value,%pkginfo);
    my $ReadPackage = 0;

    Debug "Retrieving package info from $server";
	my ($ret,@input);

    if ($Settings{TESTING}) {
	    open PKGINFO, "<../test-data/$server.pkginfo.txt" or die "Error running pkginfo on $server\n";
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
            if (grep ($_ eq $package, @PackageList)) {
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
			            if ($value =~ /^(... \d\d \d\d\d\d) /) {   # MMM DD YYYY time
				            $value = $1;   # tries to strip off the time
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


#---- CollectData ---------------------------------------------------------

sub CollectData($) {
	my ($self,$fullhash) = @_;
	Info "Start Retrieving Package Info from all Servers ...";

	my $pkginfo = \%{$fullhash->{DATA}};

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

	# Retrieve the data from each server from the appropriate file
	# and put into a single hash
	foreach my $server (keys %{$Settings{SERVERS}}) {
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
				$pkginfo->{$sheet}{ROW}{$pkg}{DATA}{$server}{VALUE} = $tmpinfo->{$pkg}{$sheet};
			}
		}
	}
#	print Dumper($pkginfo);
}

#---- Initialize ----------------------------------------------

sub Initialize() {
        my $self = shift;
	
	@PackageList = ReadList( $Settings{PACKAGES}{FILE} );
}

#---- new ------------------------------------------------------

sub new {
        my $proto = shift;
        my $class = ref($proto) || $proto;
        my $self  = {};
        bless ($self, $class);
	$self->{FILETAG} = 'pkginfo';
	$self->{DESCRIPTION} = 'Generate a report of installed packages';
        return $self;
}


1;