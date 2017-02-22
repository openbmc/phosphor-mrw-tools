#! /usr/bin/perl
use strict;
use warnings;


use mrw::Targets;
use mrw::Util;
use Getopt::Long;
use YAML::Tiny qw(LoadFile);


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

for my $target (keys %{$targets->getAllTargets()})
{
    if ($targets->getTargetType($target) eq "unit-i2c-master")
    {
        my $addr = "";
        if (!$targets->isBadAttribute($target, "REG_BASE_ADDRESS"))
        {
            $addr = $targets->getAttribute($target,"REG_BASE_ADDRESS");
        }
        if($addr ne "")
        {
            my $port = "";
            if (!$targets->isBadAttribute($target, "I2C_PORT"))
            {
                $port = $targets->getAttribute($target,"I2C_PORT");
                my $links = $targets->getNumConnections($target);
                if ($links)
                {
                    # Adjust from MRW numbering to Linux numbering scheme.
                    $port -= 1;
                    print $fh $port.":\n";
                    for (my $i = 0; $i < $links; $i++)
                    {
                        my $endpoint = 
                            $targets->getConnectionDestination($target, $i);
                        if (!$targets->isBadAttribute($endpoint, "I2C_ADDRESS"))
                        {
                            $addr =
                              $targets->getAttribute($endpoint, "I2C_ADDRESS");
                            $addr = Util::adjustI2CAddress(hex($addr));
                            print $fh "    ".$addr.": ";
                            my $fru = Util::getEnclosingFru($targets,
                                                            $endpoint);
                            print $fh $fru."\n";
                        }
                    }
                }
            }
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
