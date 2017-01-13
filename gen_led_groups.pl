#!/usr/bin/perl
use strict;
use warnings;

use mrw::Targets; # Set of APIs allowing access to parsed ServerWiz2 XML output
use mrw::Inventory; # To get list of Inventory targets
use Getopt::Long; # For parsing command line arguments
use Data::Dumper qw(Dumper); # Dumping blob

# Globals
my $force           = 0;
my $serverwizFile  = "";
my $debug           = 0;
my $outputFile     = "";
my $verbose         = 0;

# Command line argument parsing
GetOptions(
"f"   => \$force,             # numeric
"i=s" => \$serverwizFile,    # string
"o=s" => \$outputFile,       # string
"d"   => \$debug,
"v"   => \$verbose,
)
or printUsage();

if (($serverwizFile eq "") or ($outputFile eq ""))
{
    printUsage();
}

# Hashmap of all the LED groups with the properties
my %hashGroup;

# hash of targets to Names that have the FRU Inventory instances
my %invHash;

# Array of Enclosure Fault LED names. These are generally
# front-fault-led and rear-fault-led
my @encFaults;

# API used to access parsed XML data
my $targetObj = Targets->new;
if($verbose == 1)
{
    $targetObj->{debug} = 1;
}

if($force == 1)
{
    $targetObj->{force} = 1;
}

$targetObj->loadXML($serverwizFile);
print "Loaded MRW XML: $serverwizFile \n";

# Iterate over Inventory and get all the Inventory targets.
my @inventory = Inventory::getInventory($targetObj);
for my $item (@inventory)
{
    # Target to Obmc_Name hash.
    $invHash{$item->{TARGET}} = $item->{OBMC_NAME};
}

# For debugging purpose.
printDebug("\nList of Inventory targets\n");
foreach my $key (sort keys %invHash)
{
    printDebug("$invHash{$key}\n");
}

# Process all the targets in the XML. If the target is associated with a FRU,
# then remember it so that when we do the FRU inventory lookup, we know if
# that Inventory has a LED associated with it or not.
foreach my $target (sort keys %{$targetObj->getAllTargets()})
{
    # Some the target instances may *not* have this MRW_TYPE attribute.
    if($targetObj->isBadAttribute($target, "MRW_TYPE"))
    {
        next;
    }

    # Return true if not populated -or- not present
    if("LED" eq $targetObj->getMrwType($target))
    {
        # Just for clarity.
        my $ledTarget = $target;

        # OBMC_NAME field of the FRU
        # fruPath ex /system/chassis/motherboard/dimm1
        # device "dimm1"
        my $fruPath = '';
        my $device = '';

        # Get if this LED is a ENC-FAULT type.
        if(!$targetObj->isBadAttribute($target, "LED_TYPE"))
        {
            if("ENC-FAULT" eq $targetObj->getAttribute($ledTarget, "LED_TYPE"))
            {
                push @encFaults, $targetObj->getInstanceName($ledTarget);
            }
        }

        # Find if this LED is associated with a FRU.
        # Example, FAN will have LED on that assembly.
        my $conns = $targetObj->findConnections($ledTarget, "LOGICAL_ASSOCIATION");
        if ($conns ne "")
        {
            # This LED is associated with a FRU
            for my $conn (@{$conns->{CONN}})
            {
                my $destTarget = $conn->{DEST_PARENT};
                # If we have found this, then that means, we do not need to
                # hand cook a group name. delete this value from the inventory
                # array
                if(exists($invHash{$destTarget}))
                {
                    # This will remove a particular {key, value} pair
                    $fruPath = $invHash{$destTarget};
                    printDebug("$destTarget : $fruPath is having associated LED\n");
                    delete ($invHash{$destTarget});
                }
            }
            # fetch FruName from the device path
            $device = getFruName($fruPath);
            printDebug("$target; $device has device\n");
        }

        if($targetObj->isBadAttribute($ledTarget, "CONTROL_GROUPS"))
        {
            next;
        }

        # Need this to populate the table incase the device is empty
        my $instance = $targetObj->getInstanceName($ledTarget);

        my $controlGroup = $targetObj->getAttribute($ledTarget, "CONTROL_GROUPS");

        #remove spaces, because serverwiz isn't good at removing them itself
        $controlGroup =~ s/\s//g;
        my @groups= split(',', $controlGroup);  #just a long 16x3 = 48 element list

        for (my $i = 0; $i < scalar @groups; $i += 3)
        {
            if (($groups[$i] ne "NA") && ($groups[$i] ne ""))
            {
                my $groupName = $groups[$i];
                printDebug("$groupName\n");

                my $blinkFreq = $groups[$i+1];
                my $action = "'On'";
                my $period = 0;

                # Period in milli seconds
                my $dutyCycle = $groups[$i+2];
                if($blinkFreq > 0)
                {
                    $action = "'Blink'";
                    $period = (1 / $blinkFreq) * 1000;
                }

                # Insert into hash map;
                my $fru = ($device eq '') ? $instance : $device;
                $hashGroup{$groupName}{$fru}{"Action"} = $action;
                $hashGroup{$groupName}{$fru}{"Period"} = $period;
                $hashGroup{$groupName}{$fru}{"DutyOn"} = $dutyCycle;
            }
        } # Walk CONTROL_GROUP
    } # Has LED target
} # All the targets


# These are the FRUs that do not have associated LEDs. All of these need to be
# mapped to some group, which will be named after this target name and the
# elements of the group are EnclosureFaults Front and Back
printDebug("\n======================================================================\n");
printDebug("\nFRUs that do not have associated LEDs\n");
foreach my $key (sort keys %invHash)
{
    my $device = getFruName($invHash{$key});

    # For each of these device, the Group record would be this :
    my $groupName = $device . "Fault";
    printDebug("$device :: $groupName\n");

    # Setup roll-up LEDs to the ones that are of type ENC-FAULT
    foreach my $led (0 .. $#encFaults)
    {
        $hashGroup{$groupName}{$encFaults[$led]}{"Action"} = "'On'";
        $hashGroup{$groupName}{$encFaults[$led]}{"Period"} = 0;
        $hashGroup{$groupName}{$encFaults[$led]}{"DutyOn"} = 50;
    }
}
printDebug("\n======================================================================\n");

# Generate the yaml file
generateYamlFile();
#------------------------------------END OF MAIN-----------------------

# Gven a '/' separated string, returns the leaf.
# Ex: /a/b/c/d returns device=d
sub getFruName
{
    my $path = shift;
    my $device = '';
    my $lastSlash=rindex($path, '/');
    $device=substr($path, $lastSlash+1);
}

sub generateYamlFile
{
    my $fileName = $outputFile;
    my $groupCopy = '';
    my $ledCopy = '';
    open(my $fh, '>', $fileName) or die "Could not open file '$fileName' $!";

    foreach my $group (sort keys %hashGroup)
    {
        if($group ne $groupCopy)
        {
            $groupCopy = '';
            $ledCopy = '';
        }

        foreach my $led (keys %{ $hashGroup{$group} })
        {
            foreach my $property (keys %{ $hashGroup{$group}{$led}})
            {
                if($group ne $groupCopy)
                {
                    $groupCopy = $group;
                    print $fh "$group:\n";
                }
                print $fh "    ";
                if($led ne $ledCopy)
                {
                    $ledCopy = $led;
                    print $fh "$led:\n";
                    print $fh "    ";
                }
                print $fh "    ";
                print $fh "$property:";
                print $fh " $hashGroup{$group}{$led}{$property}\n";
            }
        }
    }
    close $fh;
}

# Helper function to put debug statements.
sub printDebug
{
    my $str = shift;
    print "DEBUG: ", $str, "\n" if $debug;
}

# Usage
sub printUsage
{
    print "
    $0 -i [XML filename] -o [Output filename] [OPTIONS]
Options:
    -f = force output file creation even when errors
    -d = debug mode
    -v = verbose mode - for verbose o/p from Targets.pm

PS: mrw::Targets can be found in https://github.com/open-power/serverwiz/
    mrw::Inventory can be found in https://github.com/openbmc/phosphor-mrw-tools/
    \n";
    exit(1);
}
#------------------------------------END OF SUB-----------------------
