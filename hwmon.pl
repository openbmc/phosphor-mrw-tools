#!/usr/bin/env perl

#Creates a configuration file for each hwmon sensor in the MRW
#for use by phosphor-hwmon.  These configuration files contain
#labels and thresholds for the hwmon features for that sensor.

use strict;
use warnings;

use mrw::Targets;
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

my $bmc = getBMCTarget();

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
        my @hwmonUnits = getHwmonUnits($chip);

        #If chip didn't have hwmon units, it isn't hwmon enabled.
        next unless (scalar @hwmonUnits > 0);

        my %entry;
        $entry{type} = I2C_TYPE;
        $entry{name} = lc $g_targetObj->getInstanceName($chip);

        push @$hwmon, { %entry };
    }
}


#Returns an array of 'unit-hwmon-feature' units found on the chip.
sub getHwmonUnits
{
    my ($chip) = @_;
    my @units;

    my $children = $g_targetObj->getTargetChildren($chip);

    return @units if ($children eq "");

    for my $child (@$children) {
        if ($g_targetObj->getTargetType($child) eq "unit-hwmon-feature") {
            push @units, $child;
        }
    }

    return @units;
}


#Returns the target for the BMC chip.
sub getBMCTarget
{
    for my $target (keys %{$g_targetObj->getAllTargets()}) {
        if ($g_targetObj->getType($target) eq "BMC") {
           return $target;
        }
    }
    return "";
}


sub printUsage
{
    print "$0 -x [XML filename]\n";
    exit(1);
}
