#!/usr/bin/env perl

#Creates udev rules to launch the phosphor-hwmon service for hwmon devices.

use strict;
use mrw::Targets;
use mrw::LinuxHelpers;
use Getopt::Long;

use constant {
    I2C => "i2c",
    ENVFILE_PATH => "/etc/hwmon.d/"
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

makeConfFiles(\@hwmon);

printUdevRules($udevOutputFile, \@hwmon);

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


#Creates the config files for each hwmon device.  These
#config files contain additional information about the device
#that the phosphor-hwmon service needs, such as thresholds.
sub makeConfFiles()
{
    my $hwmon = shift;

    for my $entry (@$hwmon) {

        makeConfFileName($entry);

        #Future commit: Fill in file contents
    }
}


#Creates a name for the config file for a hwmon device.
#  $entry = a reference to the hash that contains the device information
sub makeConfFileName()
{
    my $entry = shift;

    #e.g. tmp423a-5-4c.conf
    my $filename = lc "$entry->{name}-" . "$entry->{bus}-" .
                   "$entry->{addr}.conf";

    $entry->{envfile} = $filename;
}


#Creates a udev rules file that contains rules to launch systemd
#services when hwmon device drivers are added.
#  $outfile = the name of the rules file to write to
#  $hwmon = reference to array of hwmon hashes
sub printUdevRules()
{
    my ($outfile, $hwmon) = @_;

    open (my $f, ">$outfile") or die "Could not open $outfile\n";
    print $f "#This file is autogenerated.\n";
    print $f "#Not every device listed may actually have a hwmon driver.\n";

    for my $entry (@$hwmon) {
        printRule($f, $entry);
    }

    close $f
}


#Creates a udev rule for a single device.  When the hwmon driver is added,
#the rule will cause a service to be started with the device path passed
#in to it.  The config file is an environment variable that can be
#obtained by running the udevadm command (or a udev lib call).
#  $f = the file to write to
#  $entry = a reference to the hash that contains the device information
sub printRule()
{
    my ($f, $entry) = @_;
    my $envFile = ENVFILE_PATH . $entry->{envfile};
    my $bus = $entry->{bus};
    my $type = $entry->{type};
    my $addr = $entry->{addr};
    $addr = "0" x (4 - length($addr)).$addr;

    #e.g. *i2c-5/5-0024/*
    my $devpath = "*$type-$bus/$bus-$addr/*";

    my $line = qq(SUBSYSTEM=="hwmon", );
    $line .=   qq(DEVPATH=="$devpath", );
    $line .=   qq(ACTION=="add", );
    $line .=   qq(TAG+="systemd", );
    $line .=   qq(ENV{SYSTEMD_WANTS}+="phosphor-hwmon@/sys/class/hwmon/%k.service", );
    $line .=   qq(ENV{ENVFILE}+="$envFile");

    print $f $line."\n";
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
