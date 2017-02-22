#! /usr/bin/perl
use strict;
use warnings;


use mrw::Targets;
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


open(my $fh, '>', $outFile) or die "Could not open file '$outFile' $!";


my $bmc = Util::getBMCTarget($targets);
my $connections = $targets->findConnections($bmc, "I2C");
# hash of arrays - {I2C master port : list of connected slave Targets}
my %masters;

for my $i2c (@{$connections->{CONN}})
{
    my $master = $i2c->{SOURCE};
    my $port = $targets->getAttribute($master,"I2C_PORT");
    $port = Util::adjustI2CPort($port);
    my $slave = $i2c->{DEST};
    push(@{$masters{$port}}, $slave);
}

for my $m (keys %masters)
{
    print $fh $m.":\n";
    for my $s(@{$masters{$m}})
    {
        my $addr = $targets->getAttribute($s,"I2C_ADDRESS");
        $addr = Util::adjustI2CAddress(hex($addr));
        print $fh "    ".$addr.": ";
        my $fru = Util::getEnclosingFru($targets, $s);
        print $fh $fru."\n";
    }
}


close $fh;


sub printUsage
{
    print "
    $0 -m [MRW file] -o [Output filename]\n";
    exit(1);
}
