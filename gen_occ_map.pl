#!/usr/bin/env perl
use strict;
use warnings;

use mrw::Targets; # Set of APIs allowing access to parsed ServerWiz2 XML output
use mrw::Inventory; # To get list of Inventory targets
use Getopt::Long; # For parsing command line arguments
use Data::Dumper qw(Dumper); # Dumping blob
use POSIX; # For checking if something is a digit

# Globals
my $force           = 0;
my $serverwizFile  = "";
my $debug           = 0;
my $outputFile     = "";
my $verbose         = 0;

# Command line argument parsing
GetOptions(
"f"   => \$force,             # numeric
"i=s" => \$serverwizFile,    # string
"o=s" => \$outputFile,       # string
"d"   => \$debug,
"v"   => \$verbose,
)
or printUsage();

if (($serverwizFile eq "") or ($outputFile eq ""))
{
    printUsage();
}

# Hashmap of all the OCCs and their sensor IDs
my %occHash;

# API used to access parsed XML data
my $targetObj = Targets->new;
if($verbose == 1)
{
    $targetObj->{debug} = 1;
}

if($force == 1)
{
    $targetObj->{force} = 1;
}

$targetObj->loadXML($serverwizFile);
print "Loaded MRW XML: $serverwizFile \n";

# Process all the targets in the XML
foreach my $target (sort keys %{$targetObj->getAllTargets()})
{
    # Only take the instances having 'OCC" as TYPE
    if ("OCC" ne $targetObj->getAttribute($target, "TYPE"))
    {
        next;
    }

    # OCC Name and sensor ID to insert into output file
    my $name = "";
    my $sensor = "";

    # Now that we are in OCC target instance, get the name
    # It would be something like OCC0 / OCC1 ...
    $name = $targetObj->getAttribute($target, "FRU_NAME");

    # Each OCC would have occ_active_sensor child that would have
    # more information, such as Sensor ID.
    # This would be an array of children targets
    my $children = $targetObj->getTargetChildren($target);

    for my $child (@{$children})
    {
        $sensor = $targetObj->getAttribute($child, "IPMI_SENSOR_ID");
    }

    # Populate a hashmap with OCC and its sensor ID
    $occHash{$name} = $sensor;

} # All the targets

# Generate the yaml file
generateYamlFile();
##------------------------------------END OF MAIN-----------------------

sub generateYamlFile
{
    my $fileName = $outputFile;
    open(my $fh, '>', $fileName) or die "Could not open file '$fileName' $!";

    foreach my $name (sort keys %occHash)
    {
        # Get the instance number. Ex. If the name is OCC0,
        # then extract 0
        my $instance = substr($name, -1);

        # If the last entry is not an integer then something wrong.
        isdigit($instance) or die "'$name' does not have instance number";

        # YAML with list of {Instance:SensorID} dictionary
        print $fh "- Instance: ";
        print $fh "$instance\n";
        print $fh "  SensorID: ";
        print $fh "$occHash{$name}\n";
    }
    close $fh;
}

# Helper function to put debug statements.
sub printDebug
{
    my $str = shift;
    print "DEBUG: ", $str, "\n" if $debug;
}

# Usage
sub printUsage
{
    print "
    $0 -i [XML filename] -o [Output filename] [OPTIONS]
Options:
    -f = force output file creation even when errors
    -d = debug mode
    -v = verbose mode - for verbose o/p from Targets.pm

PS: mrw::Targets can be found in https://github.com/open-power/serverwiz/
    mrw::Inventory can be found in https://github.com/openbmc/phosphor-mrw-tools/
    \n";
    exit(1);
}
#------------------------------------END OF SUB-----------------------
