package Util;

#Holds common utility functions for MRW processing.

use strict;
use warnings;

use mrw::Targets;

#Returns the BMC target for a system.
# param[in] $targetObj = The Targets object
sub getBMCTarget
{
    my ($targetObj) = @_;

    for my $target (keys %{$targetObj->getAllTargets()}) {
        if ($targetObj->getType($target) eq "BMC") {
           return $target;
        }
    }

    die "Could not find BMC target in the MRW XML\n";
}


#Returns an array of child units based on their Target Type.
# param[in] $targetObj = The Targets object
# param[in] $unitTargetType = The target type of the units to find
# param[in] $chip = The chip target to find the units on
sub getChildUnitsWithTargetType
{
    my ($targetObj, $unitTargetType, $chip) = @_;
    my @units;

    my @children = $targetObj->getAllTargetChildren($chip);

    for my $child (@children) {
        if ($targetObj->getTargetType($child) eq $unitTargetType) {
            push @units, $child;
        }
    }

    return @units;
}

# Returns OBMC name corresponding to a Target name
# param[in] \@inventory = reference to array of inventory items
# param[in] $targetName = A Target name
sub getObmcName
{
    my ($inventory_ref, $targetName) = @_;
    my @inventory = @{ $inventory_ref };

    for my $item (@inventory)
    {
        if($item->{TARGET} eq $targetName)
        {
            return $item->{OBMC_NAME};
        }
    }
    return undef;
}

#Returns the array of all the device paths based on the type.
# param[in] \@inventory = reference to array of inventory items.
# param[in] $targetObj = The Targets object.
# param[in] $type = The target type.
sub getDevicePath
{
    my ($inventory_ref, $targetObj, $type) = @_;
    my @inventory = @{ $inventory_ref };
    my $fruType = "";
    my @devices;
    for my $item (@inventory)
    {
        if (!$targetObj->isBadAttribute($item->{TARGET}, "TYPE")) {
            $fruType = $targetObj->getAttribute($item->{TARGET}, "TYPE");
            if ($fruType eq $type) {
                push(@devices,$item->{OBMC_NAME});
            }
        }
    }
    return @devices;
}


1;

=head1 NAME

Util

=head1 DESCRIPTION

Contains utility functions for the MRW parsers.

=head1 METHODS

=over 4

=item getBMCTarget(C<TargetsObj>)

Returns the target string for the BMC chip.  If it can't find one,
it will die.  Currently supports single BMC systems.

=item getChildUnitsWithTargetType(C<TargetsObj>, C<TargetType>, C<ChipTarget>)

Returns an array of targets that have target-type C<TargetType>
and are children (any level) of target C<ChipTarget>.

=item getObmcName(C<InventoryItems>, C<TargetName>)

Returns an OBMC name corresponding to a Target name. Returns
undef if the Target name is not found.

=item getDevicePath(C<InventoryItems>, C<TargetsObj>, C<TargetType>)
#Returns the array of all the device path based on the C<TargetType>.

=back

=cut
