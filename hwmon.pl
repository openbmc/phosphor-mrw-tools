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
        getHwmonAttributes(\@hwmonUnits, \%entry);
        getI2CAttributes($i2c, \%entry);

        push @$hwmon, { %entry };
    }
}


#Reads the hwmon related attributes from the HWMON_FEATURE
#complex attribute and adds them to the hash.
sub getHwmonAttributes
{
    my ($units, $entry) = @_;
    my %hwmonFeatures;

    for my $unit (@$units) {

        #The hwmon name, like 'in1', 'temp1', 'fan1', etc
        my $hwmon = $g_targetObj->getAttributeField($unit,
                                                    "HWMON_FEATURE",
                                                    "HWMON_NAME");

        #The useful name for this feature, like 'ambient'
        my $name = $g_targetObj->getAttributeField($unit,
                                                   "HWMON_FEATURE",
                                                   "DESCRIPTIVE_NAME");
        $hwmonFeatures{$hwmon}{label} = $name;

        #Thresholds are optional, ignore if NA
        my $warnHigh = $g_targetObj->getAttributeField($unit,
                                                       "HWMON_FEATURE",
                                                       "WARN_HIGH");
        if (($warnHigh ne "") && ($warnHigh ne "NA")) {
            $hwmonFeatures{$hwmon}{warnhigh} = $warnHigh;
        }

        my $warnLow = $g_targetObj->getAttributeField($unit,
                                                      "HWMON_FEATURE",
                                                      "WARN_LOW");
        if (($warnLow ne "") && ($warnLow ne "NA")) {
            $hwmonFeatures{$hwmon}{warnlow} = $warnLow;
        }

        my $critHigh = $g_targetObj->getAttributeField($unit,
                                                       "HWMON_FEATURE",
                                                       "CRIT_HIGH");
        if (($critHigh ne "") && ($critHigh ne "NA")) {
            $hwmonFeatures{$hwmon}{crithigh} = $critHigh;
        }

        my $critLow = $g_targetObj->getAttributeField($unit,
                                                      "HWMON_FEATURE",
                                                      "CRIT_LOW");
        if (($critLow ne "") && ($critHigh ne "NA")) {
            $hwmonFeatures{$hwmon}{critlow} = $critLow;
        }
    }

    $entry->{hwmon} = { %hwmonFeatures };
}


#Reads the I2C attributes for the chip and adds them to the hash.
#This includes the i2C address, and register base address and
#offset for the I2C bus the chip is on.
sub getI2CAttributes
{
    my ($i2c, $entry) = @_;

    #The address comes from the destination unit, and needs
    #to be the 7 bit value in hex without the 0x.
    my $addr = $g_targetObj->getAttribute($i2c->{DEST}, "I2C_ADDRESS");
    $addr = hex($addr) >> 1;
    $entry->{addr} = sprintf("%x", $addr);

    #The reg base address and offset may be optional depending on
    #the BMC chip type.  We'll check later if it's required but missing.
    if (!$g_targetObj->isBadAttribute($i2c->{SOURCE}, "REG_BASE_ADDRESS")) {
        my $addr = $g_targetObj->getAttribute($i2c->{SOURCE},
                                              "REG_BASE_ADDRESS");
        $entry->{regBaseAddress} = sprintf("%x", hex($addr));
    }

    if (!$g_targetObj->isBadAttribute($i2c->{SOURCE}, "REG_OFFSET")) {
        my $offset = $g_targetObj->getAttribute($i2c->{SOURCE},
                                                "REG_OFFSET");
        $entry->{regOffset} = sprintf("%x", hex($offset));
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
