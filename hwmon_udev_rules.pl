#!/usr/bin/env perl

#Creates udev rules to launch the phosphor-hwmon service for hwmon devices.

use strict;
use mrw::Targets;
use mrw::LinuxHelpers;
use Getopt::Long;

use constant {
    I2C => "i2c",
};

my $serverwizFile;
my $udevOutputFile;
my @hwmon;

GetOptions("x=s" => \$serverwizFile,
           "u=s" => \$udevOutputFile) or printUsage();

if ((not defined $serverwizFile) || (not defined $udevOutputFile)) {
    printUsage();
}


my $g_targetObj = Targets->new;
$g_targetObj->loadXML($serverwizFile);

my $bmc = getBMCTarget();

getI2CSensors($bmc, \@hwmon);

#TODO: The FSI OCC sensors when that driver is ready

#Next: print config files and generate rules

exit 0;


#Creates hashes that represent an I2C device that a udev rule is
#required for.  Note that the MRW doesn't know if a device actually
#uses a hwmon driver or not, so it includes all i2C devices.
#Their rules just won't ever match on anything.  An optional future
#improvement would be to somehow store the hwmon knowledge in a
#file in the openbmc repository and use that here.
#  $bmc = the BMC target
#  $hwmon = reference to array of hashes to add to
sub getI2CSensors()
{
    my $bmc = shift;
    my $hwmon = shift;

    my $connections = $g_targetObj->findConnections($bmc, "I2C");

    if ($connections eq "") {
        return;
    }

    for my $i2c (@{$connections->{CONN}}) {

            my %entry;
            $entry{type} = I2C;
            $entry{name} = getI2CName($i2c);

            my ($bus, $addr) = getI2CBusAndAddress($i2c);
            $entry{bus}  = $bus;
            $entry{addr} = $addr;

            push @$hwmon, { %entry };
    }
}


#Finds the name of the end device from an I2C connection.
#  $i2c = reference to hash representing the connection
#  returns the device name
sub getI2CName()
{
    my $i2c = shift;

    my $name = $i2c->{DEST_PARENT};
    $name =~ s/(-\d+$)//; #remove trailing position
    $name =~ s/.*\///;    #remove the front of the path

    return $name;
}


#Finds ands formats the I2C Bus number and address from
#an I2C connection.
#  $i2c = reference to hash representing the connection
#  returns bus and address
sub getI2CBusAndAddress()
{
    my $i2c = shift;

    #The address comes from the destination unit, and needs
    #to be the 7 bit value in hex without the 0x.
    my $addr = $g_targetObj->getAttribute($i2c->{DEST}, "I2C_ADDRESS");
    $addr = hex($addr);
    $addr = $addr >>= 1;
    $addr = sprintf("%x", $addr);

    #The bus number comes from the source unit, and should
    #be returned in decimal.
    my $bus = $g_targetObj->getAttribute($i2c->{SOURCE}, "I2C_PORT");
    if ($bus =~ /^0x/i) {
        $bus = hex($bus);
    }

    #Convert the MRW I2C bus numbering scheme to Linux bus numbering
    $bus += LinuxHelpers::MRW_TO_LINUX_I2C_BUS_NUM_OFFSET;

    return ($bus, $addr);
}


#Returns the target for the BMC chip.
#Not worrying about multiple BMC systems for now.
sub getBMCTarget()
{
    foreach my $target (sort keys %{$g_targetObj->getAllTargets()})
    {
        if ($g_targetObj->getType($target) eq "BMC") {
           return $target;
        }
    }
    return "";
}


sub printUsage
{
    print "hwmon.pl -x [XML filename] -u [udev rules output filename]\n";
    exit(1);
}
