#! /usr/bin/perl
use strict;
use warnings;


use mrw::Targets;
use mrw::Inventory;
use mrw::Util;
use Getopt::Long;


my $mrwFile = "";
my $outFile = "";


GetOptions(
"m=s" => \$mrwFile,
"o=s" => \$outFile,
)
or printUsage();


if (($mrwFile eq "") or ($outFile eq ""))
{
    printUsage();
}


# Load system MRW
my $targets = Targets->new;
$targets->loadXML($mrwFile);


# Load inventory
my @inventory = Inventory::getInventory($targets);


open(my $fh, '>', $outFile) or die "Could not open file '$outFile' $!";


# MRW/Targets.pm doesn't seem to tell me which the master proc(s) are.
# Find those out.
my @procs;
for my $target (keys %{$targets->getAllTargets()})
{
    if ($targets->getType($target) eq "PROC")
    {
        push @procs, $target;
    }
}

for my $proc (@procs)
{
    my $connections = $targets->findConnections($proc, "FSIM");
    if ("" ne $connections)
    {
        # This is a master processor
        my $link = "0x00"; # revisit on a multinode system
        my $fru = Util::getEnclosingFru($targets, $proc);
        print $fh $link.": ".Util::getObmcName(\@inventory, $fru);
        for my $fsi (@{$connections->{CONN}})
        {
            my $master = $fsi->{SOURCE};
            my $slave = $fsi->{DEST};
            my $link = $targets->getAttribute($master, "FSI_LINK");
            my $fru = Util::getEnclosingFru($targets, $slave);
            print $fh "\n".$link.": ".Util::getObmcName(\@inventory, $fru);
        }
    }
}


close $fh;


sub printUsage
{
    print "
    $0 -m [MRW file] -o [Output filename]\n";
    exit(1);
}
