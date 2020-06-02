#! /usr/bin/perl

# This script is used for generating callout lists from the MRW for devices
# that can be accessed from the BMC.  The callouts have a location code, the
# target name (for debug), a priority, and in some cases a MRU.  The script
# supports I2C, FSI, SPI, FSI-I2C, and FSI-SPI devices.  The output is a JSON
# file organized into sections for each callout type, with keys based on the
# type.  I2c uses a bus and address, FSI uses a link, and SPI uses a bus
# number. If FSI is combined with I2C or SPI, then the link plus the I2C/SPI
# keys is used.  Multi-hop FSI links are indicated by a dash in between the
# links, eg "0-1".
#
# An example section is:
# "FSI":
# {
#   "5":
#   {
#      "Callouts":[
#        {
#           "Priority":"H"
#           "LocationCode": "P1-C50",
#           "MRU":"/sys-0/node-0/motherboard/proc_socket-0/module-0/power9-0",
#           "Name":"/sys-0/node-0/motherboard/cpu0"
#        },
#        {
#           "Priority":"H",
#           "LocationCode": "P1-C42",
#           "MRU":"/sys-0/node-0/motherboard/ebmc-card/BMC-0",
#           "Name":"/sys-0/node-0/motherboard/ebmc-card"
#        },
#        {
#           "Priority":"L",
#           "LocationCode": "P1",
#           "Name":"/sys-0/node-0/motherboard"
#        }
#     ],
#     "Dest":"/sys-0/node-0/motherboard-0/proc_socket-0/module-0/power9-0",
#     "Source":"/sys-0/node-0/motherboard-0/ebmc-card-connector-0/card-0/bmc-0"
#   }
# }
# The Name, Dest and Source entries are MRW targets and are just for debug.
#
# The optional --segments argument will output a JSON file of all the bus
# segments in the system, which is what the callouts are made from.

use strict;
use warnings;

use mrw::Targets;
use mrw::Util;
use Getopt::Long;
use File::Basename;
use JSON;

my $mrwFile = "";
my $outFile = "";
my $printSegments = 0;

# Not supporting priorites A, B, or C until necessary
my %priorities = (H => 3, M => 2, L => 1);

# Segment bus types
my %busTypes = ( I2C => 1, FSIM => 1, FSICM => 1, SPI => 1 );

GetOptions(
    "m=s" => \$mrwFile,
    "o=s" => \$outFile,
    "segments" => \$printSegments
)
    or printUsage();

if (($mrwFile eq "") or ($outFile eq ""))
{
    printUsage();
}

# Load system MRW
my $targets = Targets->new;
$targets->loadXML($mrwFile);

# Find all single segment buses that we care about
my %allSegments = getPathSegments();

# Write the segments to a JSON file
if ($printSegments)
{
    my $outDir = dirname($outFile);
    my $segmentsFile = "$outDir/segments.json";

    open(my $fh, '>', $segmentsFile) or
        die "Could not open file '$segmentsFile' $!";

    my $json = JSON->new;
    $json->indent(1);
    $json->canonical(1);
    my $text = $json->encode(\%allSegments);
    print $fh $text;
    close $fh;
}

# Returns a hash of all the FSI, I2C, and SPI segments in the MRW
sub getPathSegments
{
    my %segments;
    foreach my $target (sort keys %{$targets->getAllTargets()})
    {
        my $numConnections = $targets->getNumConnections($target);

        if ($numConnections == 0)
        {
            next;
        }

        for (my $connIndex=0;$connIndex<$numConnections;$connIndex++)
        {
            my $connBusObj = $targets->getConnectionBus($target, $connIndex);
            my $busType = $connBusObj->{bus_type};

            # We only care about certain bus types
            if (not exists $busTypes{$busType})
            {
                next;
            }

            my $dest = $targets->getConnectionDestination($target, $connIndex);

            my %segment;
            $segment{BusType} = $busType;
            $segment{SourceUnit} = $target;
            $segment{SourceChip} = getParentByClass($target, "CHIP");
            if ($segment{SourceChip} eq "")
            {
                die "Warning: Could not get parent chip for source $target\n";
            }

            $segment{DestUnit} = $dest;
            $segment{DestChip} = getParentByClass($dest, "CHIP");

            # If the unit's direct parent is a connector that's OK too.
            if ($segment{DestChip} eq "")
            {
                my $parent = $targets->getTargetParent($dest);
                if ($targets->getAttribute($parent, "CLASS") eq "CONNECTOR")
                {
                    $segment{DestChip} = $parent;
                }
            }

            if ($segment{DestChip} eq "")
            {
                die "Warning: Could not get parent chip for dest $dest\n";
            }

            my $fruPath = $targets->getBusAttribute(
                $target, $connIndex, "FRU_PATH");

            if (defined $fruPath)
            {
                $segment{FRUPath} = $fruPath;
                my @callouts = getFRUPathCallouts($fruPath);
                $segment{Callouts} = \@callouts;
            }
            else
            {
                $segment{FRUPath} = "";
                my @empty;
                $segment{Callouts} = \@empty;
            }

            if ($busType eq "I2C")
            {
                $segment{I2CBus} = $targets->getAttribute($target, "I2C_PORT");
                $segment{I2CAddress} =
                    hex($targets->getAttribute($dest, "I2C_ADDRESS"));

                $segment{I2CBus} = $segment{I2CBus};

                # Convert to the 7 bit address that linux uses
                $segment{I2CAddress} =
                    Util::adjustI2CAddress($segment{I2CAddress});
            }
            elsif ($busType eq "FSIM")
            {
                $segment{FSILink} =
                    hex($targets->getAttribute($target, "FSI_LINK"));
            }
            elsif ($busType eq "SPI")
            {
                $segment{SPIBus} = $targets->getAttribute($target, "SPI_PORT");

                # Seems to be in HEX sometimes
                if ($segment{SPIBus} =~ /^0x/i)
                {
                    $segment{SPIBus} = hex($segment{SPIBus});
                }
            }

            push @{$segments{$busType}}, { %segment };
        }
    }

    return %segments;
}

#Breaks the FRU_PATH atttribute up into its component callouts.
#It looks like:  "H:<some target>,L:<some other target>(<MRU>)"
#Where H/L are the priorities and can be H/M/L.
#The MRU that is in parentheses is optional and is a chip name on that
#FRU target.
sub getFRUPathCallouts
{
    my @callouts;
    my $fruPath = shift;

    my @entries = split(',', $fruPath);

    for my $entry (@entries)
    {
        my %callout;
        my ($priority, $path) = split(':', $entry);

        # pull the MRU out of the parentheses at the end and then
        # remove the parentheses.
        if ($path =~ /\(.+\)$/)
        {
            ($callout{MRU}) = $path =~ /\((.+)\)/;

            $path =~ s/\(.+\)$//;
        }

        # The FRU_PATH path value may just have '/sys/' instead of '/sys-0'.
        # Fix it up
        $path =~ s/^\/sys\//\/sys-0\//;

        $callout{Priority} = $priority;
        if (not exists $priorities{$priority})
        {
            die "Invalid priority: '$priority' on callout $path\n";
        }

        $callout{Name} = $path;

        push @callouts, \%callout;
    }

    return @callouts;
}

# Returns an ancestor target based on its class
sub getParentByClass
{
    my ($target, $class) = @_;
    my $parent = $targets->getTargetParent($target);

    while (defined $parent)
    {
        if (!$targets->isBadAttribute($parent, "CLASS"))
        {
            if ($class eq $targets->getAttribute($parent, "CLASS"))
            {
                return $parent;
            }
        }
        $parent = $targets->getTargetParent($parent);
    }

    return "";
}

sub printUsage
{
    print "$0 -m <MRW file> -o <Output filename> [--segments] [-n]\n" .
    "        -m <MRW file> = The MRW XML\n" .
    "        -o <Output filename> = The output JSON\n" .
    "        [--segments] = Optionally create a segments.json file\n" .
    exit(1);
}
