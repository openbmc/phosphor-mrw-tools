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
    my $obmcPath = '';

    if ($targetObj->getTargetType($target) eq "unit-ipmi-sensor") {

        $sensorID = $targetObj->getAttribute($target, "IPMI_SENSOR_ID");

        $sensorType = $targetObj->getAttribute($target, "IPMI_SENSOR_TYPE");

        $sensorReadingType = $targetObj->getAttribute($target,
                             "IPMI_SENSOR_READING_TYPE");

        $path = $targetObj->getAttribute($target, "INSTANCE_PATH");

        #not interested in this sensortype
        next if (not exists $types{$sensorType});

        #if there is ipmi sensor without sensorid or sensorReadingType or
        #Instance path then die

        if ($sensorID eq '' or $sensorReadingType eq '' or $path eq '') {
            close $fh;
            die("sensor without info for target=$target");
        }

        #removing the string "instance:" from path
        $path =~ s/^instance:/\//;

        print STDOUT $path."\n"; 

        my ($str1,$str2) = split(/\/([^\/]+)$/, $path);
        if($path eq "/sys-0"){
            $obmcPath = $sensorTypeConfig->{$sensorType}->{"path"};
        }
        elsif($str2 eq "occ"){
            my ($sys, $node, $mb, $sok, $mod, $proc)  = split /\//, $str1;
            my ($nm,$occNum) = split(/-([^-]+)$/, $sok);
 
            $obmcPath =  $sensorTypeConfig->{$sensorType}->{"path"}."occ".$occNum;
        }            
        else{
            $obmcPath = Util::getObmcName(\@inventory, $path);

            #if unable to get the obmc path then die
            if (not defined $obmcPath) {
                close $fh;
                die("Unable to get the obmc path for path=$path");
           }
        }

        print $fh $sensorID.":\n";

        printDebug("$sensorID : $sensorType : $sensorReadingType :$obmcPath \n");

        writeToFile($sensorType,$sensorReadingType,$obmcPath,$sensorTypeConfig,$fh);

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
    print $fh "  updatePath: ".$sensorTypeConfig->{$sensorType}->{"updatePath"}."\n";
    print $fh "  updateInterface: ".$sensorTypeConfig->{$sensorType}->{"updateInterface"}."\n";
    print $fh "  updateCommand: ".$sensorTypeConfig->{$sensorType}->{"updateCommand"}."\n";
    print $fh "  readingType: ".$sensorTypeConfig->{$sensorType}->{"readingType"}."\n";
    print $fh "  byteOffset: ".$sensorTypeConfig->{$sensorType}->{"byteOffset"}."\n";
    print $fh "  interfaces:"."\n";

    my $interfaces = $sensorTypeConfig->{$sensorType}->{"interfaces"};
    #Walk over all the interfces as it needs to be written
    while (my ($interface,$properties) = each %{$interfaces}) {
        print $fh "    ".$interface.":\n";
        #walk over all the properties as it needs to be written
        while (my ($dbusProperty,$dbusPropertyValue) = each %{$properties}) {
                    #will write property named "Property" first then
                    #other properties.
            print $fh "      ".$dbusProperty.":\n";
            while (my ( $offset,$values) = each %{$dbusPropertyValue}) {
                print $fh "        $offset:\n";
                while (my ( $key,$value) = each %{$values})  {
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
