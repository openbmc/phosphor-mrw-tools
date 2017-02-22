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

        $sensorID = $targetObj->getAttribute($target, "IPMI_SENSOR_ID");

        $sensorType = $targetObj->getAttribute($target, "IPMI_SENSOR_TYPE");

        $sensorReadingType = $targetObj->getAttribute($target,
                             "IPMI_SENSOR_READING_TYPE");

        $path = $targetObj->getAttribute($target, "INSTANCE_PATH");

        #removing the string "instance:" from path
        $path =~ s/^instance:/\//;

        next if (not exists $types{$sensorType} );

        print $fh $sensorID.":\n";

        $path = Util::getObmcName(\@inventory, $path);

        printDebug("$sensorID : $sensorType : $sensorReadingType :$path \n");

        writeToFile($sensorType,$sensorReadingType,$path,$sensorTypeConfig,$fh);

    }

}
close $fh;


#Get the metadata for the incoming sensortype from the loaded config file.
#Write the sensor data into the output file

sub writeToFile
{
    my ($sensorType,$sensorReadingType,$path,$sensorTypeConfig,$fh) = @_;
    print $fh "  sensorType: ".$sensorType."\n";
    print $fh "  path: ".$path."\n";
    print $fh "  sensorReadingType: ".$sensorReadingType."\n";
    print $fh "  interfaces:"."\n";

    my $interfaces = $sensorTypeConfig->{$sensorType};
    #Walk over all the interfces as it needs to be written
    while ( my ($interface,$properties) = each %{$interfaces}) {
        print $fh "    ".$interface.":\n";
        #walk over all the properties as it needs to be written
        while ( my ($dbusProperty,$dbusPropertyValue) = each %{$properties}) {
                    #will write property named "Property" first then
                    #other properties.
            print $fh "      ".$dbusProperty.":\n";
            while ( my ( $offset,$values) = each %{$dbusPropertyValue}) {
                print $fh "        $offset:\n";
                while ( my ( $key,$value) = each %{$values})  {
                    print $fh "          $key: ". $value."\n";
                }
            }
        }
    }
}

# Usage
sub printUsage
{
    print "
    $0 -i [MRW filename] -m [SensorMetaData filename]-o [Output filename] [OPTIONS]
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
