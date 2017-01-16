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
my $outputFile     = "";
my $metaDataFile   = "";

# Command line argument parsing
GetOptions(
"i=s" => \$serverwizFile,    # string
"m=s" => \$metaDataFile,     #string
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

#open the mrw xml and the metaData file for the fru.
#Fetch the FRU id,type,object path from the mrw.
#Get the metadata for that fru from the metadata file.
#Merge the data into the outputfile

open(my $fh, '>', $outputFile) or die "Could not open file '$outputFile' $!";
my $fruTypeConfig = LoadFile($metaDataFile);

my @interestedTypes = keys %{$fruTypeConfig};
my %types;
@types{@interestedTypes} = ();

my @inventory = Inventory::getInventory($targetObj);
for my $item (@inventory) {
    my $isFru = 0, my $fruID = 0, my $fruType = "";
    #Fetch the FRU ID.
    if (!$targetObj->isBadAttribute($item->{TARGET}, "FRU_ID")) {
        $fruID = $targetObj->getAttribute($item->{TARGET}, "FRU_ID");
        $isFru = 1;
    }
    # Fetch the FRU Type.
    if (!$targetObj->isBadAttribute($item->{TARGET}, "TYPE")) {
        $fruType = $targetObj->getAttribute($item->{TARGET}, "TYPE");
    }

    #Skip if we're not interested
    next if (not $isFru or not exists $types{$fruType});

    printDebug ("FRUID => $fruID, FRUType => $fruType, ObjectPath => $item->{OBMC_NAME}");

    print $fh $fruID.":";
    print $fh "\n";

    writeToFile($fruType,$item->{OBMC_NAME},$fruTypeConfig,$fh);

}
close $fh;

#------------------------------------END OF MAIN-----------------------

#Get the metdata for the incoming frutype from the loaded config file.
#Write the FRU data into the output file

sub writeToFile
{
    my $fruType = $_[0];#fru type
    my $instancePath = $_[1];#instance Path
    my $fruTypeConfig = $_[2];#loaded config file (frutypes)
    my $fh = $_[3];#file Handle
    #walk over all the fru types and match for the incoming type
    print $fh "  ".$instancePath.":";
    print $fh "\n";
    my $interfaces = $fruTypeConfig->{$fruType};
    #Walk over all the interfces as it needs to be written
    while ( my ($interface,$properties) = each %{$interfaces}) {
        print $fh "    ".$interface.":";
        print $fh "\n";
        #walk over all the properties as it needs to be written
        while ( my ($dbusProperty,$metadata) = each %{$properties}) {
                    #will write property named "Property" first then
                    #other properties.
            print $fh "      ".$dbusProperty.":";
            print $fh "\n";
            for my $key (sort keys %{$metadata}) {
                print $fh "        $key: "."$metadata->{$key}";
                print $fh "\n";
            }
        }
    }
}

# Usage
sub printUsage
{
    print "
    $0 -i [MRW filename] -m [MetaData filename] -o [Output filename] [OPTIONS]
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
