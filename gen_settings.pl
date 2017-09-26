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
# Setting to get from the MRW
my @settings = ("OPEN_POWER_SOFT_MIN_PCAP_WATTS",
                "OPEN_POWER_N_PLUS_ONE_BULK_POWER_LIMIT_WATTS");

# Command line argument parsing
GetOptions(
"f"   => \$force,            # numeric
"i=s" => \$serverwizFile,    # string
"o=s" => \$outputFile,       # string
"d"   => \$debug,
)
or printUsage();

if (($serverwizFile eq "") or ($outputFile eq ""))
{
    printUsage();
}

# Hashmap of all the settings and their values
my %settingsHash;

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

# Process all the targets in the XML
foreach my $target (sort keys %{$targetObj->getAllTargets()})
{
    # The settings are found under the sys-sys-power9 type target instance
    next if ("sys-sys-power9" ne $targetObj->getTargetType($target, "TYPE"));

    foreach my $setting (@settings)
    {
        $settingsHash{$setting} = $targetObj->getAttribute($target, $setting);
    }
}
generateYamlFile();

sub generateYamlFile
{
    my $fileName = $outputFile;
    open(my $fh, '>', $fileName) or die "Could not open file '$fileName' $!";

    foreach my $setting (sort keys %settingsHash)
    {
        # YAML with list of {setting:value} dictionary
        print $fh "- Setting: ";
        print $fh "$setting\n";
        print $fh "  Value: ";
        print $fh "$settingsHash{$setting}\n";
    }
    close $fh;
}

# Usage
sub printUsage
{
    print "
    $0 -i [XML filename] -o [Output filename] [OPTIONS]
Options:
    -f = force output file creation even when errors
    -d = debug mode

PS: mrw::Targets can be found in https://github.com/open-power/serverwiz/
    mrw::Inventory can be found in https://github.com/openbmc/phosphor-mrw-tools/
    \n";
    exit(1);
}
