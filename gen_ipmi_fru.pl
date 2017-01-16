#! /usr/bin/perl
use strict;
use warnings;

use mrw::Targets;
use mrw::Inventory;
use Getopt::Long; # For parsing command line arguments
use YAML::XS 'LoadFile'; # For loading and reading of YAML file

# Globals
my $serverwizFile  = "";
my $debug           = 0;

# Command line argument parsing
GetOptions(
"i=s" => \$serverwizFile,    # string
"d"   => \$debug,
)
or printUsage();

if (($serverwizFile eq ""))
{
    printUsage();
}

my $targetObj = Targets->new;
$targetObj->loadXML($serverwizFile);

#open the mrw xml Fetch the FRU id,type,object path from the mrw.

my @inventory = Inventory::getInventory($targetObj);
for my $item (@inventory) {
    my $isFru = 0, my $fruID = 0, my $fruType = "";
    my $isChildFru = 0;

    #Fetch the fruid.
    if (!$targetObj->isBadAttribute($item->{TARGET}, "FRU_ID")) {
        $fruID = $targetObj->getAttribute($item->{TARGET}, "FRU_ID");
        $isFru = 1;
    }

    #Fech the fru type.
    if (!$targetObj->isBadAttribute($item->{TARGET}, "TYPE")) {
        $fruType = $targetObj->getAttribute($item->{TARGET}, "TYPE");
    }

    #skip those entries whose type is NA and is not fru.
    next if ( $fruType eq 'NA' or not($isFru) or $fruType eq 'BMC');

    printDebug ("FRUID => $fruID,FRUType => $fruType, ObjectPath => $item->{OBMC_NAME}");

}
#------------------------------------END OF MAIN-----------------------

# Usage
sub printUsage
{
    print "
    $0 -i [MRW filename] [OPTIONS]
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
