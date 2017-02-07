#! /usr/bin/perl
use strict;
use warnings;

use mrw::Targets;
use mrw::Inventory;
use Getopt::Long;
use YAML::Tiny qw(LoadFile);

my $mrwFile = "";
my $outFile = "";
my $configFile = "";

GetOptions(
"m=s" => \$mrwFile,
"c=s" => \$configFile,
"o=s" => \$outFile,
)
or printUsage();

if (($mrwFile eq "") or ($configFile eq "") or ($outFile eq ""))
{
    printUsage();
}

# Target Type : Target inventory path
my %defaultPaths = (
    "ETHERNET", "/system/chassis/motherboard/bmc/ethernet",
);

# Load system MRW
my $targets = Targets->new;
$targets->loadXML($mrwFile);

# Parse config YAML
my $targetItems = LoadFile($configFile);

# Targets we're interested in, from the config YAML
my @targetNames = keys %{$targetItems};
my %targetTypes;
@targetTypes{@targetNames} = ();
my @targetTypes;
my @paths;

# Retrieve OBMC path of targets we're interested in
my @inventory = Inventory::getInventory($targets);
for my $item (@inventory) {
    my $targetType = "";
    my $path = "";

    if (!$targets->isBadAttribute($item->{TARGET}, "TYPE")) {
        $targetType = $targets->getAttribute($item->{TARGET}, "TYPE");
    }
    next if (not exists $targetTypes{$targetType});

    push @targetTypes, $targetType;
    push @paths, $item->{OBMC_NAME};
    delete($targetTypes{$targetType});
}

for my $type (keys %targetTypes)
{
    # One or more targets wasn't present in the inventory
    push @targetTypes, $type;
    push @paths, $defaultPaths{$type};
}

open(my $fh, '>', $outFile) or die "Could not open file '$outFile' $!";
print $fh "FRUS=".join ',',@targetTypes;
print $fh "\n";
print $fh "PATHS=".join ',',@paths;
close $fh;

sub printUsage
{
    print "
    $0 -m [MRW file] -c [Config yaml] -o [Output fileame]\n";
    exit(1);
}
