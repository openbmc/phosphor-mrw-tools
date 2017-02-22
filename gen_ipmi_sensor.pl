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
my $debug           = 0;
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

#open the mrw xml and the metaData file for the sensor.
#Fetch the sensorid,sensortype,class,object path from the mrw.
#Get the metadata for that sensor from the metadata file.
#Merge the data into the outputfile

open(my $fh, '>', $outputFile) or die "Could not open file '$outputFile' $!";
my $sensorTypeConfig = LoadFile($metaDataFile);

my @interestedTypes = keys %{$sensorTypeConfig};
my %types;
@types{@interestedTypes} = ();

my @inventory = Inventory::getInventory($targetObj);
#Process all the targets in the XML
foreach my $target (sort keys %{$targetObj->getAllTargets()})
{
    my $sensorID = '';
    my $sensorType = '';
    my $sensorReadingType = '';
    my $path = '';

    if ($targetObj->getTargetType($target) eq "unit-ipmi-sensor") {

        if (!$targetObj->isBadAttribute($target, "IPMI_SENSOR_ID")) {
            $sensorID = $targetObj->getAttribute($target, "IPMI_SENSOR_ID");
        }

        if (!$targetObj->isBadAttribute($target, "IPMI_SENSOR_TYPE")) {
            $sensorType = $targetObj->getAttribute($target, "IPMI_SENSOR_TYPE");
        }

        if (!$targetObj->isBadAttribute($target, "IPMI_SENSOR_READING_TYPE")) {
            $sensorReadingType = $targetObj->getAttribute($target, "IPMI_SENSOR_READING_TYPE");
        }

        if (!$targetObj->isBadAttribute($target, "INSTANCE_PATH")) {
            $path = $targetObj->getAttribute($target, "INSTANCE_PATH");
            #removing the string "instance:" from path
            $path = substr $path, 9;
            $path = '/'.$path;

        }
        next if (not exists $types{$sensorType} or $sensorID eq '' or  $sensorReadingType eq '' or $path eq '');
        print $fh $sensorID.":";
        print $fh "\n";
        $path = Util::getObmcName(\@inventory, $path);

        printDebug("$sensorID : $sensorType : $sensorReadingType :$path \n");

    }

}

# Usage
sub printUsage
{
    print "
    $0 -i [MRW filename] -m [SensorMetaData filename]-o [Output filename] [OPTIONS]
Options:
    -f = force output file creation even when errors
    -d = debug mode
    -v = verbose mode - for verbose o/p from Targets.pm
        \n";
    exit(1);
}

# Helper function to put debug statements.
sub printDebug
{
    my $str = shift;
    print "DEBUG: ", $str, "\n" if $debug;
}

