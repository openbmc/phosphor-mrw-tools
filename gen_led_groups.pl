#!/usr/bin/perl
use strict;
use warnings;

use Targets; # Set of APIs allowing access to parsed ServerWiz2 XML output
use Getopt::Long; # For parsing command line arguments
use Data::Dumper qw(Dumper); # Dumping blob
use Inventory; # To get list of Inventory targets

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

# Array of targets that have the FRU association for LEDs
# Typically each LED will be associated with one FRU.
my @fruarray;

# Array of targets that have the FRU Inventory instances
my @invarray;

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
    push @invarray, $item->{TARGET};
}

# For debugging purpose.
printDebug("\nLEDs containing FRU associations\n");
foreach my $i (0 .. $#invarray)
{
    printDebug("$invarray[$i]\n");
}

# Process all the targets in the XML. If the target is associated with a FRU,
# then remember it so that when we do the FRU inventory lookup, we know if
# that Inventory has a LED associated with it or not.
foreach my $target (sort keys %{$targetObj->getAllTargets()})
{
    my $led = '';

	# Some the target instances may *not* have this MRW_TYPE attribute.
    if(!$targetObj->isBadAttribute($target, "MRW_TYPE"))
    {
        # Return true if not populated -or- not present
        $led = $targetObj->getMrwType($target);
        if($led eq "LED")
        {
            # Just for clarity.
            my $ledTarget = $target;

			# Find if this LED is associated with a FRU.
			# Example, FAN will have LED on that assembly.
            my $conns = $targetObj->findConnections($ledTarget, "LOGICAL_ASSOCIATION");
            if ($conns ne "")
            {
                for my $conn (@{$conns->{CONN}})
                {
                    my $desttarget = $conn->{DEST_PARENT};

                    # This LED is associated with a FRU
                    push @fruarray, $desttarget;

                    # If we have found this, then that means, we do not need to
                    # hand cook a group name. delete this value from the inventory
                    # array
                    foreach my $i (0 .. $#invarray)
                    {
                        # Getting the undefined use warning for the last element
                        # of invarray so making this 'defined' check
                        if (defined $invarray[$i] and ($invarray[$i] eq $desttarget))
                        {
                            # This will remove '1' array element at index [i]
                            splice @invarray, $i, 1;
                        }
                    }
                }
            }

            # Get Instance name, which is the name of the LED.
            my $instance = $targetObj->getInstanceName($ledTarget);
            printDebug("$led : $target; $instance\n");

            if(!$targetObj->isBadAttribute($ledTarget, "CONTROL_GROUPS"))
            {
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

                        my $dutyCycle = $groups[$i+2];
                        if($blinkFreq > 0)
                        {
                            # Frequency in milli seconds
                            my $frequency = (1 / $blinkFreq) * 1000;
                            $hashgroup{$groupName}{$instance}{"Frequency"} = $frequency;
                        }

                        # Insert into hash map;
                        $hashgroup{$groupName}{$instance}{"Action"} = $action;
                        $hashgroup{$groupName}{$instance}{"DutyOn"} = $dutyCycle;
                    }
                } # Walk CONTROL_GROUP
            } # Has CONTROL_GROUP
        } # Has LED target
    } # Has MRW_TYPE
} # All the targets

printDebug("\nLEDs that have FRU in them\n");
foreach my $i (0 .. $#fruarray)
{
    printDebug("$fruarray[$i]\n");
}

# These are the FRUs that do not have associated LEDs. All of these need to be
# mapped to some group, which will be named after this target name and the
# elements of the group are EnclosureFaults Front and Back
printDebug("\n======================================================================\n");
foreach my $i (0 .. $#invarray)
{
    my $invTarget = $invarray[$i];
    my $instanceName = $targetObj->getInstanceName($invTarget);
    printDebug("$invTarget :  $instanceName\n");
}
printDebug("\n======================================================================\n");

# Generate the yaml file
generateYamlFile();
#------------------------------------END OF MAIN-----------------------

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
