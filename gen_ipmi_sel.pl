#! /usr/bin/perl
use strict;
use warnings;

use mrw::Targets;
use mrw::Inventory;
use mrw::Util;
use Getopt::Long; # For parsing command line arguments
use YAML::Tiny qw(LoadFile);

# Globals
my $serverwizFile  = "";
my $debug          = 0;
my $outputFile     = "";
my $metaDataFile   = "";

# Command line argument parsing
GetOptions(
"i=s" => \$serverwizFile,    # string
"m=s" => \$metaDataFile,     # string
"o=s" => \$outputFile,       # string
"d"   => \$debug,
)
or printUsage();

if (($serverwizFile eq "") or ($outputFile eq "") or ($metaDataFile eq ""))
{
    printUsage();
}

my $targetObj = Targets->new;
$targetObj->loadXML($serverwizFile);

# Open the MRW xml and the Metadata file for the sensor.
# Get the IPMI sensor information based on the Entity ID and Sensor Type.
# Fetch the Sensor ID, Event/Reading Type and Object Path from MRW.
# Get the Sensor Type and Offset from the metadata file.
# Merge and generate an output YAML with inventory object path as the key.

open(my $fh, '>', $outputFile) or die "Could not open file '$outputFile' $!";
my $metaDataConfig = LoadFile($metaDataFile);

my @interestedTypes = keys %{$metaDataConfig};
my %types;

@types{@interestedTypes} = ();

my @inventory = Inventory::getInventory($targetObj);
#Process all the targets in the XML
foreach my $target (sort keys %{$targetObj->getAllTargets()})
{
    my $sensorID = '';
    my $sensorType = '';
    my $eventReadingType = '';
    my $path = '';
    my $obmcPath = '';
    my $entityID = '';
    my $base = "/xyz/openbmc_project/inventory";

    if ($targetObj->getTargetType($target) eq "unit-ipmi-sensor") {

        $sensorID = $targetObj->getAttribute($target, "IPMI_SENSOR_ID");
        $sensorType = $targetObj->getAttribute($target, "IPMI_SENSOR_TYPE");
        $eventReadingType = $targetObj->getAttribute($target,
                             "IPMI_SENSOR_READING_TYPE");
        $path = $targetObj->getAttribute($target, "INSTANCE_PATH");
        $entityID = $targetObj->getAttribute($target, "IPMI_ENTITY_ID");

        # Look only for the interested Entity ID & Sensor Type
        next if (not exists $types{$entityID});
        next if ($sensorType ne $metaDataConfig->{$entityID}->{SensorType});

        #if there is ipmi sensor without sensorid or sensorReadingType or
        #Instance path then die

        if ($sensorID eq '' or $eventReadingType eq '' or $path eq '') {
            close $fh;
            die("sensor without info for target=$target");
        }

        # Removing the string "instance:" from path
        $path =~ s/^instance:/\//;
        $obmcPath = Util::getObmcName(\@inventory, $path);

        # If unable to get the obmc path then die
        if (not defined $obmcPath) {
            close $fh;
            die("Unable to get the obmc path for path=$path");
        }

        $base .= $obmcPath;

        print $fh $base.":"."\n";
        print $fh "  sensorID: ".$sensorID."\n";
        print $fh "  sensorType: ".$sensorType."\n";
        print $fh "  eventReadingType: ".$eventReadingType."\n";
        print $fh "  offset: ".$metaDataConfig->{$entityID}->{Offset}."\n";

        printDebug("$sensorID : $sensorType : $eventReadingType : $entityID : $metaDataConfig->{$entityID}->{Offset}")
    }
}
close $fh;

# Usage
sub printUsage
{
    print "
    $0 -i [MRW filename] -m [SensorMetaData filename] -o [Output filename] [OPTIONS]
Options:
    -d = debug mode
        \n";
    exit(1);
}

# Helper function to put debug statements.
sub printDebug
{
    my $str = shift;
    print "DEBUG: ", $str, "\n" if $debug;
}
