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

makeConfFiles($bmc, \@hwmon);

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


#Creates .conf files for each chip.
sub makeConfFiles
{
    my ($bmc, $hwmon) = @_;

    for my $entry (@$hwmon) {
        printConfFile($bmc, $entry);
    }
}


#Writes out a configuration file for a hwmon sensor, containing:
#  LABEL_<feature> = <descriptive label>  (e.g. LABEL_temp1 = ambient)
#  WARNHI_<feature> = <value> (e.g. WARNHI_temp1 = 99)
#  WARNLO_<feature> = <value> (e.g. WARNLO_temp1 = 0)
#  CRITHI_<feature> = <value> (e.g. CRITHI_temp1 = 100)
#  CRITHI_<feature> = <value> (e.g. CRITLO_temp1 = -1)
sub printConfFile
{
    my ($bmc, $entry) = @_;
    my $fileName = getConfFileName($bmc, $entry);

    open(my $f, ">$fileName") or die "Could not open $fileName\n";

    for my $feature (sort keys %{$entry->{hwmon}}) {
        print $f "LABEL_$feature = \"$entry->{hwmon}{$feature}{label}\"\n";

        #Thresholds are optional
        if (exists $entry->{hwmon}{$feature}{warnhigh}) {
            print $f "WARNHI_$feature = \"$entry->{hwmon}{$feature}{warnhigh}\"\n";
        }
        if (exists $entry->{hwmon}{$feature}{warnlow}) {
            print $f "WARNLO_$feature = \"$entry->{hwmon}{$feature}{warnlow}\"\n";
        }
        if (exists $entry->{hwmon}{$feature}{crithigh}) {
            print $f "CRITHI_$feature = \"$entry->{hwmon}{$feature}{crithigh}\"\n";
        }
        if (exists $entry->{hwmon}{$feature}{critlow}) {
            print $f "CRITLO_$feature = \"$entry->{hwmon}{$feature}{critlow}\"\n";
        }
    }

    close $f;
}


#Returns the name to use for the chip's configuration file.
sub getConfFileName
{
    my ($bmc, $entry) = @_;

    my $mfgr = $g_targetObj->getAttribute($bmc, "MANUFACTURER");

    #Unfortunately, because the conf file name is based on the
    #device tree path which is tied to the internal chip structure,
    #this has to be model specific.  Until proven wrong, I'm going
    #to make an assumption that all ASPEED chips have the same path
    #as so far all of the models I've seen do.
    if ($mfgr eq "ASPEED") {
        return getAspeedConfFileName($entry);
    }
    else {
        die "Unsupported BMC manufacturer $mfgr\n";
    }
}


#Returns the configuration filename for the chip with an ASPEED BMC.
sub getAspeedConfFileName
{
    my ($entry) = @_;
    my $name;

    #The file name is an escaped version of the OF_FULLNAME udev variable
    #which looks like /ahb/apb/i2c@1e78a000/i2c-bus@400/ucd90160@64.

    if ($entry->{type} eq I2C_TYPE) {

        #ASPEED requires the reg base address & offset fields
        if ((not exists $entry->{regBaseAddress}) ||
            (not exists $entry->{regOffset})) {
            die "Missing regBaseAddress or regOffset attributes " .
                "in the I2C master unit XML\n";
        }

        my $baseAddr = $entry->{regBaseAddress};
        my $offset = $entry->{regOffset};
        my $chip = $entry->{name};
        my $addr = $entry->{addr};

        #Start out with the regular version, and then escape below
        $name = "/ahb/apb/i2c@" . "$baseAddr/i2c-bus@" .
                "$offset/$chip@" . "$addr.conf";
        $name =~ s/-/\\x2d/g; #'-' -> '\x2d'
        $name =~ s/@/\\x40/g; #'@' -> '\x40'
        $name =~ s/\//-/g;    #'/' -> '-'
    }
    else {
        #TODO: FSI support for the OCC when known
        die "HWMON bus type $entry->{type} not implemented yet\n";
    }

    return $name;
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
