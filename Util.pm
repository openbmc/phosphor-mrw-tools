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

=item getUnitsWithTargetType(C<TargetsObj>, C<TargetType>, C<ChipTarget>)

Returns an array of targets that have target-type C<TargetType>
and are children (any level) of target C<ChipTarget>.

=back

=cut
