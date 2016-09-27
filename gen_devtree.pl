#!/usr/bin/env perl

#Generates a BMC device tree syntax file from the machine
#readable workbook.

use strict;
use XML::Simple;
use mrw::Targets;
use Getopt::Long;

use constant VERSION => "/dts-v1/;";
use constant STANDALONE_PROPERTY => "standalone_property";
use constant DTSI_INCLUDE => "DTSI_INCLUDE";
my %MFG_INCLUDES = (
    ASPEED => ["<dt-bindings/gpio/aspeed-gpio.h>"],
);


my $serverwizFile;
my $outputFile;
my $debug;

GetOptions("x=s" => \$serverwizFile,
           "o=s" => \$outputFile,
           "d" => \$debug)
or printUsage();

if ((not defined $serverwizFile) || (not defined $outputFile)) {
    printUsage();
}

my $targetObj = Targets->new;
$targetObj->loadXML($serverwizFile);

my $bmc = getBMCTarget();
if (length($bmc) == 0) {
    die "Unable to find a BMC in this system\n";
}

my $bmcModel = $targetObj->getAttribute($bmc, "MODEL");
my $bmcMfgr = $targetObj->getAttribute($bmc, "MANUFACTURER");
my $systemName = $targetObj->getSystemName();

open (my $f, ">$outputFile") or die "Could not open $outputFile\n";

printVersion($f);
printBmcDTSIInclude($f);
printChipIncludes($f);
printRootNodeStart($f);

printPropertyList($f, 1, "model", getSystemBMCModel());

printPropertyList($f, 1, "compatible", getBMCCompatibles());
printNode($f, 1, "chosen", getChosen());
printNode($f, 1, "memory", getMemory($bmc));

#TODO: LEDs, UART, I2C, aliases, pinctlr
printRootNodeEnd($f, 0);

printNodes($f, 0, getMacNodes());

printNodes($f, 0, getVuartNodes());

close $f;
exit 0;



#Return a hash for the 'chosen' node
sub getChosen()
{
    my $stdout = $targetObj->getAttributeField($bmc, "BMC_DT_CHOSEN",
                                            "stdout-path");
    my $args = $targetObj->getAttributeField($bmc, "BMC_DT_CHOSEN",
                                            "bootargs");
    my %chosen;
    $chosen{"stdout-path"} = $stdout;
    $chosen{"bootargs"} = $args;
    return %chosen;
}


#Returns a hash of the MAC nodes on the BMC
sub getMacNodes()
{
    my @nodes;
    my $children = $targetObj->getTargetChildren($bmc);

    foreach my $c (@$children) {

        if ($targetObj->getTargetType($c) eq "unit-ethernet-master") {

            #TODO: Maybe eventually look if a bus is wired up instead
            if ($targetObj->getAttribute($c, "UNIT_ENABLED") == 1) {
                my %node;
                my $num = $targetObj->getAttribute($c, "CHIP_UNIT");
                my $ncsi = $targetObj->getAttribute($c, "NCSI_MODE");
                my $hwChecksum = $targetObj->getAttribute($c,
                                                          "USE_HW_CHECKSUM");

                my $name = "mac$num";
                $node{$name}{status} = "okay";
                if ($ncsi == 1) {
                    $node{$name}{"use-ncsi"} = STANDALONE_PROPERTY;
                }
                if ($hwChecksum == 0) {
                    $node{$name}{"no-hw-checksum"} = STANDALONE_PROPERTY;
                }

                push @nodes, { %node };
            }
        }
    }
    return @nodes;
}


sub getVuartNodes()
{
    my @nodes;
    my %node;

    #For now, enable 1 node all the time.
    #TODO if this needs to be fixed.
    $node{vuart}{status} = "okay";

    push @nodes, { %node };

    return @nodes;
}

#Returns a hash{'reg'} = "<.....>"  based on the 
#BMC_DT_MEMORY attribute.
sub getMemory()
{
    my $target = shift;
    my $memory = $targetObj->getAttribute($target, "BMC_DT_MEMORY");
    my @mem = split(',', $memory);
    my %property;
    my $val = "<";

    #Encoded as 4 <base address>,<size> pairs of memory ranges
    #Unused ranges are all 0s.
    #For now, assumes 32 bit numbers, revisit later for 64 bit support
    #Convert it into:  <num1 num2 num3 num4 etc>
    
    for (my $i = 0;$i < scalar @mem;$i += 2) {

        #pair is valid if size is nonzero
        if (hex($mem[$i+1]) != 0) {
            $val .= "$mem[$i] $mem[$i+1] ";
        }
    }

    $val =~ s/\s$//;
    $val .= ">";
    $property{reg} = $val;

    return %property;
}

#Returns a list of compatible fields for the BMC itself.
sub getBMCCompatibles()
{
    my @compats;

    #The first once is from the MRW, the next one is more generic
    #and just <mfgr>-<model>.
    
    if (!$targetObj->isBadAttribute($bmc, "BMC_DT_COMPATIBLE", "NA")) {
        my $attr = $targetObj->getAttribute($bmc, "BMC_DT_COMPATIBLE");
        push @compats, $attr; 
    }

    push @compats, lc($bmcMfgr).",".lc($bmcModel);

    return @compats;
}


sub getSystemBMCModel()
{
    #<System> BMC
    my $sys = lc $systemName;
    $sys = uc(substr($sys, 0, 1)) . substr($sys, 1);

    return $sys . " BMC";
}


#Prints a list of nodes at the same indent level
sub printNodes()
{
    my ($f, $level, @nodes) = @_;

    foreach my $n (@nodes) {
        my %node = %$n;

        foreach my $name (sort keys %node) {
            my %n = %{ $node{$name} };
            printNode($f, $level, $name, %n);
        }
    }
}


#Print a single node and its children
sub printNode() 
{
    my ($f, $level, $name, %vals) = @_;
    my $include = "";

    if ($level == 0) {
        $name = "&".$name;    
    }
    
    print $f "\n".indent($level) . "$name {\n";

    foreach my $v (sort keys %vals) {

        #A header file include, print it later
        if ($v eq DTSI_INCLUDE) {
            $include = $vals{$v};
        }
        #A nested node
        elsif (ref($vals{$v}) eq "HASH") {
            printNode($f, $level+1, $v, %{$vals{$v}});
        }
        elsif ($vals{$v} ne STANDALONE_PROPERTY) {
            printProperty($f, $level+1, $v, $vals{$v});
        }
        else {
            printStandaloneProperty($f, $level+1, $v);
        }
    }

    if ($include ne "") {
        print $f "#include \"$include\";\n";
    }

    print $f indent($level) . "};\n";
}


#Prints a comma separated list of properties.
#e.g.  a = "b, c, d";
sub printPropertyList()
{
    my ($f, $level, $name, @vals) = @_;

    print $f indent($level) . "$name = ";

    for (my $i = 0;$i < scalar @vals; $i++) {
        print $f "\"$vals[$i]\"";
        if ($i < (scalar(@vals) - 1)) {
            print $f ", ";
        }
    }
    print $f ";\n"
}


#Prints a single property.  e.g. a = "b";
sub printProperty()
{
    my ($f, $level, $name, $val) = @_;
    print $f indent($level) . "$name = \"" . convertAlias($val) . "\";\n";
}


#Prints a standalone property e.g. some-property;
sub printStandaloneProperty()
{
    my ($f, $level, $name) = @_;
    print $f indent($level) . "$name;\n";
}


#replace (alias) with &
sub convertAlias() {
    my $val = shift;
    $val =~ s/\(alias\)/&/g;
    return $val
}


sub getBMCTarget()
{
    foreach my $target (sort keys %{ $targetObj->getAllTargets() })
    {
        if ($targetObj->getType($target) eq "BMC") {
           return $target; 
        }
    }
    return "";
}


sub printVersion()
{
    my $f = shift;
    print $f VERSION."\n"
}


sub printBmcDTSIInclude()
{
    my $f = shift;

    if (!$targetObj->isBadAttribute($bmc, "BMC_DTSI_INCLUDE")) {
        my $inc = $targetObj->getAttribute($bmc, "BMC_DTSI_INCLUDE");
        if (($inc ne "NA") && ($inc ne "")) {
            print $f "#include \"$inc\";\n";
        }
    }
}


sub printChipIncludes()
{
    my $f = shift;
    my $m = uc $bmcMfgr;
    if (exists $MFG_INCLUDES{$bmcMfgr}) {
        foreach my $i (@{$MFG_INCLUDES{$bmcMfgr}}) {
           print $f "#include \"$i\";\n";
        }
    }
    else {
        print "No include file was found for BMC manufacturer $bmcMfgr\n";
    }
}


sub printRootNodeStart() {
    my $f = shift;
    print $f "\\ \{\n";
}


sub printRootNodeEnd() {
    my ($f, $level) = @_;
    print $f indent($level)."\};\n";
}


sub indent() {
    my $level = shift;
    return ' ' x ($level * 4);

}


sub printUsage
{
    print "gen_devtree.pl -x [XML filename] -o [output filename]\n";
    exit(1);
}
