#!/usr/bin/perl
use strict;
use warnings;

use mrw::Targets; # Set of APIs allowing access to parsed ServerWiz2 XML output
use mrw::Inventory; # To get list of Inventory targets
use Getopt::Long; # For parsing command line arguments
use Data::Dumper qw(Dumper); # Dumping blob

# Globals
my $force           = 0;
my $serverwiz_file  = "";
my $debug           = 0;
my $output_file     = "";
my $verbose         = 0;

# Command line argument parsing
GetOptions(
"f"   => \$force,             # numeric
"i=s" => \$serverwiz_file,    # string
"o=s" => \$output_file,       # string
"d"   => \$debug,
"v"   => \$verbose,
)
or printUsage();

if (($serverwiz_file eq "") or ($output_file eq ""))
{
    printUsage();
}

# Hashmap of all the LED groups with the properties
my %hashgroup;

# hash of targets to Names that have the FRU Inventory instances
my %invhash;

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

$targetObj -> loadXML($serverwiz_file);
print "Loaded MRW XML: $serverwiz_file \n";

# Iterate over Inventory and get all the Inventory targets.
my @inventory = Inventory::getInventory($targetObj);
for my $item (@inventory)
{
    # Target to Obmc_Name hash.
    $invhash{$item->{TARGET}} = $item->{OBMC_NAME};
}

# For debugging purpose.
printDebug("\nList of Inventory targets\n");
foreach my $key (sort keys %invhash)
{
    printDebug("$invhash{$key}\n");
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
        # frupath ex /system/chassis/motherboard/dimm1
        # device "dimm1"
        my $frupath = '';
        my $device = '';

        # Find if this LED is associated with a FRU.
        # Example, FAN will have LED on that assembly.
        my $conns = $targetObj->findConnections($ledTarget, "LOGICAL_ASSOCIATION");
        if ($conns ne "")
        {
            # This LED is associated with a FRU
            for my $conn (@{$conns->{CONN}})
            {
                my $desttarget = $conn->{DEST_PARENT};

                # If we have found this, then that means, we do not need to
                # hand cook a group name. delete this value from the inventory
                # array
                foreach my $invtarget (sort keys %invhash)
                {
                    # Getting the undefined use warning for the last element
                    # of invarray so making this 'defined' check
                    if ($invtarget eq $desttarget)
                    {
                        $frupath = $invhash{$invtarget};
                        printDebug("$invtarget : $frupath is having associated LED\n");

                        # This will remove a particular {key, value} pair
                        delete ($invhash{$invtarget});

                        # We have found a match. break.
                        last;
                    }
                }
            }
            # fetch FruName from the device path
            $device = getFruName($frupath);
            printDebug("$target; $device has device\n");
        }

        if($targetObj->isBadAttribute($ledTarget, "CONTROL_GROUPS"))
        {
            next;
        }

        # Need this to populate the table incase the device is empty
        my $instance = $targetObj->getInstanceName($ledTarget);

        my $controlgroup = $targetObj->getAttribute($ledTarget, "CONTROL_GROUPS");
        $controlgroup =~ s/\s//g;  #remove spaces, because serverwiz isn't good at removing them itself
        my @groups= split(',', $controlgroup);  #just a long 16x3 = 48 element list

        for (my $i = 0; $i < scalar @groups; $i += 3)
        {
            if (($groups[$i] ne "NA") && ($groups[$i] ne ""))
            {
                my $groupName = $groups[$i];
                #print "$groupName\n";

                my $blinkFreq = $groups[$i+1];
                my $action = '';
                if ($blinkFreq == 0)
                {
                    $action = "'On'";
                }
                else
                {
                    $action = "'Blink'";
                }

                # Frequency in milli seconds
                my $dutyCycle = $groups[$i+2];
                if($blinkFreq > 0)
                {
                    # Frequency in milli seconds
                    my $frequency = (1 / $blinkFreq) * 1000;

                    # Not all have FRU path so use instance name
                    my $fru = ($device eq '') ? $instance : $device;
                    $hashgroup{$groupName}{$fru}{"Frequency"} = $frequency;
                }
                else
                {
                    # Need this to be able to auto generate C++ header file
                    my $fru = ($device eq '') ? $instance : $device;
                    $hashgroup{$groupName}{$fru}{"Frequency"} = 0;
                }

                # Insert into hash map;
                my $fru = ($device eq '') ? $instance : $device;
                $hashgroup{$groupName}{$fru}{"Action"} = $action;
                $hashgroup{$groupName}{$fru}{"DutyOn"} = $dutyCycle;
            }
        } # Walk CONTROL_GROUP
    } # Has LED target
} # All the targets


# These are the FRUs that do not have associated LEDs. All of these need to be
# mapped to some group, which will be named after this target name and the
# elements of the group are EnclosureFaults Front and Back
printDebug("\n======================================================================\n");
printDebug("\nLEDs that do NOT have FRU in them\n");
foreach my $key (sort keys %invhash)
{
    my $device = getFruName($invhash{$key});
    print "$device\n";

    # For each of these device, the Group record would be this :
    my $groupName = $device . '' . "Fault";
    print "$groupName\n";

    # Only roll up is the front-fault-led and rear-fault-led
    # TODO Get these names from LED_TYPE of ENC-FAULT
    $hashgroup{$groupName}{"front-fault-led"}{"Action"} = "'On'";
    $hashgroup{$groupName}{"front-fault-led"}{"Blink"} = 0;
    $hashgroup{$groupName}{"front-fault-led"}{"DutyOn"} = 50;

    $hashgroup{$groupName}{"rear-fault-led"}{"Action"} = "'On'";
    $hashgroup{$groupName}{"rear-fault-led"}{"Blink"} = 0;
    $hashgroup{$groupName}{"rear-fault-led"}{"DutyOn"} = 50;
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
    my $last_slash=rindex($path, '/');
    $device=substr($path, $last_slash+1);
}

sub generateYamlFile
{
    my $filename = $output_file;
    my $group_copy = '';
    my $led_copy = '';
    open(my $fh, '>', $filename) or die "Could not open file '$filename' $!";

    foreach my $group (sort keys %hashgroup)
    {
        if($group ne $group_copy)
        {
            $group_copy = '';
            $led_copy = '';
        }

        foreach my $led (keys %{ $hashgroup{$group} })
        {
            foreach my $property (keys %{ $hashgroup{$group}{$led}})
            {
                if($group ne $group_copy)
                {
                    $group_copy = $group;
                    print $fh "$group:\n";
                }
                print $fh "    ";
                if($led ne $led_copy)
                {
                    $led_copy = $led;
                    print $fh "$led:\n";
                    print $fh "    ";
                }
                print $fh "    ";
                print $fh "$property:";
                print $fh " $hashgroup{$group}{$led}{$property}\n";
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
        \n";
    exit(1);
}
#------------------------------------END OF SUB-----------------------
