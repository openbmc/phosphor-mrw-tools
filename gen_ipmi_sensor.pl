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
my %entityDict;

my $maxCorePerProc = 24;
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
    my $sensorName = '';
    my $entityID = '';
    my $entityInstance = '';

    if ($targetObj->getTargetType($target) eq "unit-ipmi-sensor") {

        $sensorName = $targetObj->getInstanceName($target);
        #not interested in this sensortype
        next if (not exists $types{$sensorName});

        $entityID = $targetObj->getAttribute($target, "IPMI_ENTITY_ID");
        if (exists ($entityDict{$entityID}))
        {
            $entityDict{$entityID}++;
        }
        else
        {
            $entityDict{$entityID} = '1';
        }
        $entityInstance = $entityDict{$entityID};

        $sensorID = $targetObj->getAttribute($target, "IPMI_SENSOR_ID");

        $sensorType = hex($targetObj->getAttribute($target,
                             "IPMI_SENSOR_TYPE"));

        $sensorReadingType = $targetObj->getAttribute($target,
                             "IPMI_SENSOR_READING_TYPE");

        $path = $targetObj->getAttribute($target, "INSTANCE_PATH");

        #if there is ipmi sensor without sensorid or sensorReadingType or
        #Instance path then die

        if ($sensorID eq '' or $sensorReadingType eq '' or $path eq '') {
            close $fh;
            die("sensor without info for target=$target");
        }

        if (exists $sensorTypeConfig->{$sensorName}{"path"}) {
            $obmcPath = $sensorTypeConfig->{$sensorName}->{"path"};
        }
        else {
            #removing the string "instance:" from path
            $path =~ s/^instance:/\//;
            $obmcPath = Util::getObmcName(\@inventory,$path);
        }

        # TODO via openbmc/openbmc#2144 - this fixup shouldn't be needed.
        $obmcPath = checkOccPathFixup($obmcPath);

        if (not defined $obmcPath) {
            close $fh;
            die("Unable to get the obmc path for path=$path");
        }

        print $fh $sensorID.":\n";

        my $serviceInterface =
            $sensorTypeConfig->{$sensorName}->{"serviceInterface"};
        my $readingType = $sensorTypeConfig->{$sensorName}->{"readingType"};
        my $sensorNamePattern = $sensorTypeConfig->{$sensorName}->{"sensorNamePattern"};

        # If temerature sensor
        if($sensorType == 0x01) {
            my $dbusPath .= "/xyz/openbmc_project/sensors/temperature/";
            if($sensorName eq "cpucore_temp_sensor") {
                my $core = $targetObj->getTargetParent($target);
                my $coreNo = $targetObj->getAttribute($core, "IPMI_INSTANCE");
                my $proc = Util::getEnclosingFru($targetObj, $core);
                my $procNo = $targetObj->getAttribute($proc, "POSITION");
                $coreNo = $coreNo - ($procNo * $maxCorePerProc);
                $dbusPath .= "p" . $procNo . "_core" . $coreNo . "_temp";
            }
            elsif ($sensorName eq "dimm_temp_sensor") {
                my $dimm = $targetObj->getTargetParent($target);
                my $dimmconn = $targetObj->getTargetParent($dimm);
                my $pos = $targetObj->getAttribute($dimmconn, "POSITION");
                $dbusPath .= "dimm" . $pos . "_temp";
            }
            elsif ($sensorName eq "vrm_vdd_temp_sensor") {
                my $proc = Util::getEnclosingFru($targetObj, $target);
                my $procNo = $targetObj->getAttribute($proc, "POSITION");
                $dbusPath .= "p" . $procNo . "_vdd_temp";
            }
            elsif ($sensorName eq "memory_temp_sensor") {
                my $gvcard = $targetObj->getTargetParent($target);
                my $pos = $targetObj->getAttribute($gvcard, "IPMI_INSTANCE");
                $dbusPath .= "gpu" . $pos . "_mem_temp";
            }
            elsif ($sensorName eq "gpu_temp_sensor") {
                my $gvcard = $targetObj->getTargetParent($target);
                my $pos = $targetObj->getAttribute($gvcard, "IPMI_INSTANCE");
                $dbusPath .= "gpu" . $pos . "_core_temp";
            }
            else {
                close $fh;
                die("Unsupported temperature sensor $sensorName \n");
            }
            
            my $multiplierM = $sensorTypeConfig->{$sensorName}->{"multiplierM"};
            my $offsetB = $sensorTypeConfig->{$sensorName}->{"offsetB"};
            my $bExp = $sensorTypeConfig->{$sensorName}->{"bExp"};
            my $rExp = $sensorTypeConfig->{$sensorName}->{"rExp"};
            my $unit = $sensorTypeConfig->{$sensorName}->{"unit"};
            my $scale = $sensorTypeConfig->{$sensorName}->{"scale"};

            # print debug info if enabled
            my $debug = "$sensorID : $sensorName : $sensorType : ";
            $debug .= "$sensorReadingType : $entityID : $entityInstance : ";
            $debug .= "$multiplierM : $offsetB : $bExp : $rExp : $unit";
            $debug .= "$scale : $dbusPath : $obmcPath \n";

            # write  temperatur sensor data to file
            writeTempSensorToFile($sensorName, $sensorType,
                $sensorReadingType, $dbusPath, $serviceInterface, $readingType,
                $multiplierM, $offsetB, $bExp, $rExp, $unit, $scale,
                $sensorTypeConfig, $entityID, $entityInstance,
                $sensorNamePattern, $fh);
            #print "\nAnalog SENSOR NAME = $sensorName ";
            #print "dbusPath=$dbusPath obmcPath=$obmcPath \n";
        }
        else {
            my $debug = "$sensorID : $sensorName : $sensorType : ";
            $debug .= "$sensorReadingType : $entityID : $entityInstance : ";
            $debug .= "$obmcPath \n";
            printDebug("$debug");
            writeToFile($sensorName, $sensorType, $sensorReadingType, $obmcPath,
                $serviceInterface, $readingType, $sensorTypeConfig, $entityID,
                $entityInstance, $sensorNamePattern, $fh);
        }
    }

}
close $fh;


sub writeInterfaces
{
    my ($interfaces, $fh) = @_;
    #Walk over all the interfces as it needs to be written
    while (my ($interface,$properties) = each %{$interfaces}) {
        print $fh "    ".$interface.":\n";
        #walk over all the properties as it needs to be written
        while (my ($dbusProperty,$dbusPropertyValue) = each %{$properties}) {
                    #will write property named "Property" first then
                    #other properties.
            print $fh "      ".$dbusProperty.":\n";
            while (my ($condition,$offsets) = each %{$dbusPropertyValue}) {
                print $fh "          $condition:\n";
                while (my ($offset,$values) = each %{$offsets}) {
                    print $fh "            $offset:\n";
                    while (my ($key,$value) = each %{$values})  {
                        print $fh "              $key: ". $value."\n";
                    }
                }
            }
        }
    }
}

#Get the metadata for the incoming sensortype from the loaded config file.
#Write the sensor data into the output file
sub writeToFile
{
    my ($sensorName,$sensorType,$sensorReadingType,$path,$serviceInterface,
        $readingType,$sensorTypeConfig,$entityID,$entityInstance,
        $sensorNamePattern,$fh) = @_;

    print $fh "  entityID: ".$entityID."\n";
    print $fh "  entityInstance: ".$entityInstance."\n";
    print $fh "  sensorType: ".$sensorType."\n";
    print $fh "  path: ".$path."\n";

    print $fh "  sensorReadingType: ".$sensorReadingType."\n";
    print $fh "  serviceInterface: ".$serviceInterface."\n";
    print $fh "  readingType: ".$readingType."\n";
    print $fh "  sensorNamePattern: ".$sensorNamePattern."\n";
    print $fh "  interfaces:"."\n";

    my $interfaces = $sensorTypeConfig->{$sensorName}->{"interfaces"};
    writeInterfaces($interfaces, $fh);
}

sub writeTempSensorToFile
{
    my ($sensorName, $sensorType, $sensorReadingType, $path, $serviceInterface,
        $readingType, $multiplierM, $offsetB, $bExp, $rExp,
        $unit, $scale, $sensorTypeConfig, $entityID, $entityInstance,
        $sensorNamePattern, $fh) = @_;

    print $fh "  entityID: ".$entityID."\n";
    print $fh "  entityInstance: ".$entityInstance."\n";
    print $fh "  sensorType: ".$sensorType."\n";
    print $fh "  path: ".$path."\n";
    print $fh "  sensorReadingType: ".$sensorReadingType."\n";
    print $fh "  serviceInterface: ".$serviceInterface."\n";
    print $fh "  readingType: ".$readingType."\n";
    print $fh "  multiplierM: ".$multiplierM."\n";
    print $fh "  offsetB: ".$offsetB."\n";
    print $fh "  bExp: ".$bExp."\n";
    print $fh "  rExp: ".$rExp."\n";
    print $fh "  unit: ".$unit."\n";
    print $fh "  scale: ".$scale."\n";
    print $fh "  sensorNamePattern: ".$sensorNamePattern."\n";
    print $fh "  interfaces:"."\n";

    my $interfaces = $sensorTypeConfig->{$sensorName}->{"interfaces"};
    writeInterfaces($interfaces, $fh);
}

# Convert MRW OCC inventory path to application d-bus path
sub checkOccPathFixup
{
    my ($path) = @_;
    if ("/system/chassis/motherboard/cpu0/occ" eq $path) {
        return "/org/open_power/control/occ0";
    }
    if ("/system/chassis/motherboard/cpu1/occ" eq $path) {
        return "/org/open_power/control/occ1";
    }
    return $path;
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
