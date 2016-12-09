package Inventory;

use strict;


sub getInventory
{
    my $targetObj = shift;
    my @inventory;

    return @inventory;
}

1;

=head1 NAME

Inventory

=head1 DESCRIPTION

Retrieves the OpenBMC inventory from the MRW.

The inventory contains:

=over 4

=item * The system target

=item * The chassis target(s)

=item * All targets of class CARD (motherboards, daughter cards, etc)

=item * All targets of type PROC

=item * All targets of type BMC

=back

=head1 METHODS

=over 4

=item getInventory (C<TargetsObj>)

Returns an array of hashes representing inventory items.

The Hash contains:

* TARGET: The MRW target of the item, for example:

    /sys-0/node-0/motherboard-0/proc_socket-0/module-0/p9_proc_m

* OBMC_NAME: The OpenBMC name of the item, for example:

   /system/chassis/motherboard/cpu-2

   TODO: OBMC_NAME rules

=back

=cut
