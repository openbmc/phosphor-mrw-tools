#!/usr/bin/env perl
use strict;
use warnings;

use mrw::Targets; # Set of APIs allowing access to parsed ServerWiz2 XML output
use Getopt::Long; # For parsing command line arguments

# Globals
my $force           = 0;
my $serverwizFile  = "";
my $debug           = 0;
my $outputFile     = "";
my $settingsFile   = "";

# Command line argument parsing
GetOptions(
"f"   => \$force,            # numeric
"i=s" => \$serverwizFile,    # string
"o=s" => \$outputFile,       # string
"s=s" => \$settingsFile,     # string
"d"   => \$debug,
)
or printUsage();

if (($serverwizFile eq "") or ($outputFile eq "") or ($settingsFile eq "") )
{
    printUsage();
}

# API used to access parsed XML data
my $targetObj = Targets->new;
if($debug == 1)
{
    $targetObj->{debug} = 1;
}

if($force == 1)
{
    $targetObj->{force} = 1;
}

$targetObj->loadXML($serverwizFile);
print "Loaded MRW XML: $serverwizFile \n";

open(my $inFh, '<', $settingsFile) or die "Could not open file '$settingsFile' $!";
open(my $outFh, '>', $outputFile) or die "Could not open file '$outputFile' $!";

# Process all the targets in the XML
foreach my $target (sort keys %{$targetObj->getAllTargets()})
{
    # A future improvement could be to specify the MRW target.
    next if ("SYS" ne $targetObj->getType($target, "TYPE"));
    # Read the settings YAML replacing any MRW_<variable name> with their
    # MRW value
    while (my $row = <$inFh>)
    {
        while ($row =~ /MRW_(.*?)\W/g)
        {
            my $setting = $1;
            my $settingValue = $targetObj->getAttribute($target, $setting);
            $row =~ s/MRW_${setting}/$settingValue/g;
        }
        print $outFh $row;
    }
    last;
    close $inFh;
    close $outFh;
}

# Usage
sub printUsage
{
    print "
    $0 -i [XML filename] -s [Settings YAML] -o [Output filename] [OPTIONS]

Required:
    -i = MRW XML filename
    -s = The Setting YAML with MRW variables in MRW_<MRW variable name> format
    -o = YAML output filename
Options:
    -f = force output file creation even when errors
    -d = debug mode
    \n";
    exit(1);
}
