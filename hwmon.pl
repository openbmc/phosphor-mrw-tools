#!/usr/bin/env perl

#Creates a configuration file for each hwmon sensor in the MRW
#for use by phosphor-hwmon.  These configuration files contain
#labels and thresholds for the hwmon features for that sensor.

use strict;
use warnings;

use mrw::Targets;
use mrw::Util;
use Getopt::Long;

use constant {
    I2C_TYPE => "i2c"
};

my $serverwizFile;
my @hwmon;

GetOptions("x=s" => \$serverwizFile) or printUsage();

if (not defined $serverwizFile) {
    printUsage();
}

my $g_targetObj = Targets->new;
$g_targetObj->loadXML($serverwizFile);

my $bmc = Util::getBMCTarget($g_targetObj);

getI2CSensors($bmc, \@hwmon);

exit 0;


#Returns an array of hashes that represent hwmon enabled I2C sensors.
sub getI2CSensors
{
    my ($bmc, $hwmon) = @_;
    my $connections = $g_targetObj->findConnections($bmc, "I2C");

    return if ($connections eq "");

    for my $i2c (@{$connections->{CONN}}) {

        my $chip = $i2c->{DEST_PARENT};
        my @hwmonUnits = Util::getChildUnitsWithTargetType($g_targetObj,
                                                      "unit-hwmon-feature",
                                                      $chip);

        #If chip didn't have hwmon units, it isn't hwmon enabled.
        next unless (scalar @hwmonUnits > 0);

        my %entry;
        $entry{type} = I2C_TYPE;
        $entry{name} = lc $g_targetObj->getInstanceName($chip);

        push @$hwmon, { %entry };
    }
}


sub printUsage
{
    print "$0 -x [XML filename]\n";
    exit(1);
}
