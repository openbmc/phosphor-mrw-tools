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

my @interestedDeviceType = ("PROC","CORE","CARD","DIMM","MEMBUFF","SYS","NODE");
my %hash;
@hash{@interestedDeviceType} = ();

my @inventory = Inventory::getInventory($targetObj);
for my $item (@inventory) {
    my $isFru = 0, my $fruID = 0, my $fruType = "";
    #Fetch the FRUID.
    if (!$targetObj->isBadAttribute($item->{TARGET}, "FRU_ID")) {
        $fruID = $targetObj->getAttribute($item->{TARGET}, "FRU_ID");
        $isFru = 1;
    }
    #Fetch the FRU Type.
    if (!$targetObj->isBadAttribute($item->{TARGET}, "TYPE")) {
        $fruType = $targetObj->getAttribute($item->{TARGET}, "TYPE");
    }

    #Skip those entries whose type is NA.
    next if ( $fruType eq 'NA' or not($isFru) or $fruType eq 'BMC');

    printDebug ("FRUID => $fruID, FRUType => $fruType, ObjectPath => $item->{OBMC_NAME}");

    print $fh $fruID.":";
    print $fh "\n";

    writeToFile($isFru,$fruType,$item->{OBMC_NAME},$fruTypeConfig,$fh);

    # Fetch all the childrens for this inventory target,It might happen the children is fru or non fru
    # Follwing condition to be true for fetching the associated non fru devices.
    # -it should be non fru.
    # -type of the fru is in the interested types.
    # - the parent of the child should be same as inventory target.

    foreach my $child ($targetObj->getAllTargetChildren($item->{TARGET})) {
        $fruType = $targetObj->getAttribute($child, "TYPE");

        if (!$targetObj->isBadAttribute($child, "FRU_ID")) {
            #i.e this child is a fru,we are interrested in non fru devices
            next;
        }

        #Fetch the Fru Type
        if (!$targetObj->isBadAttribute($child, "TYPE")) {
            $fruType = $targetObj->getAttribute($child, "TYPE");
        }

        # check whether this fru type is in interested fru types.
        if (not exists $hash{$fruType}) {
            next;
        }

        # find the parent fru of this child.
        my $parent = $targetObj->getTargetParent($child);
        while ($parent ne ($item->{TARGET})) {
            $parent = $targetObj->getTargetParent($parent);
            if (!$targetObj->isBadAttribute($parent, "FRU_ID")) {
                last;
            }

        }
        #if parent of the child is not equal to the item->target
        #i.e some other fru is parent of this child.
        if ( $parent ne ($item->{TARGET}) ){
            next;
        }

        printDebug("     ".$child);
        printDebug("     Type:".$fruType );
        writeToFile(0,$fruType, $child, $fruTypeConfig, $fh);
    }
}
close $fh;

#------------------------------------END OF MAIN-----------------------

#Get the metdata for the incoming frutype from the loaded config file.
#Write the FRU data into the output file

sub writeToFile
{
    my $isFru = $_[0];#is Fru
    my $fruType = $_[1];#fru type
    my $instancePath = $_[2];#instance Path
    my $fruTypeConfig = $_[3];#loaded config file (frutypes)
    my $fh = $_[4];#file Handle
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
                #write  the property value depending on the fru type
                if ($key eq "Value" and $dbusProperty eq "FieldReplaceable") {
                    if ( $isFru){
                        print $fh "        Value: "."True";
                    }
                    else {
                        print $fh "        Value: "."False";
                    }
                    print $fh "\n";
                    next;
                }
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
    $0 -i [MRW filename] -m [MetaData filename]-o [Output filename] [OPTIONS]
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
