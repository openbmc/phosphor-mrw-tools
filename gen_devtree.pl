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

my $g_targetObj = Targets->new;
$g_targetObj->loadXML($serverwizFile);

my $g_bmc = getBMCTarget();
if (length($g_bmc) == 0) {
    die "Unable to find a BMC in this system\n";
}

my $g_bmcModel = $g_targetObj->getAttribute($g_bmc, "MODEL");
my $g_bmcMfgr = $g_targetObj->getAttribute($g_bmc, "MANUFACTURER");
my $g_systemName = $g_targetObj->getSystemName();

open (my $f, ">$outputFile") or die "Could not open $outputFile\n";

printVersion($f);
printIncludes($f, 0);
printRootNodeStart($f);

printPropertyList($f, 1, "model", getSystemBMCModel());

printPropertyList($f, 1, "compatible", getBMCCompatibles());
printNode($f, 1, "chosen", getChosen());
printNode($f, 1, "memory", getMemory($g_bmc));

#TODO: LEDs, UART, I2C, aliases, pinctlr
printRootNodeEnd($f, 0);

printNodes($f, 0, getMacNodes());

printNodes($f, 0, getVuartNodes());

close $f;
exit 0;



#Return a hash that represents the 'chosen' node
sub getChosen()
{
    my $bmcStdOut = $g_targetObj->getAttributeField($g_bmc, "BMC_DT_CHOSEN",
                                                    "stdout-path");
    my $args = $g_targetObj->getAttributeField($g_bmc, "BMC_DT_CHOSEN",
                                              "bootargs");
    my %chosen;
    $chosen{"stdout-path"} = $bmcStdOut;
    $chosen{"bootargs"} = $args;
    return %chosen;
}


#Returns a list of hashes that represent the MAC (ethernet) nodes on the BMC
sub getMacNodes()
{
    my @nodes;
    my $children = $g_targetObj->getTargetChildren($g_bmc);

    #The next version of this will look for ethernet connections in the
    #MRW instead of just the units...
    foreach my $c (@$children) {

        if ($g_targetObj->getTargetType($c) eq "unit-ethernet-master") {

            if ($g_targetObj->getAttribute($c, "UNIT_ENABLED") == 1) {
                my %node;
                my $num = $g_targetObj->getAttribute($c, "CHIP_UNIT");
                my $ncsi = $g_targetObj->getAttribute($c, "NCSI_MODE");
                my $hwChecksum = $g_targetObj->getAttribute($c,
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


#Returns a last of hashes that represent the virtual UART nodes
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
#BMC_DT_MEMORY attribute.  This is used to display
#memory ranges.
sub getMemory()
{
    my $target = shift;
    my $memory = $g_targetObj->getAttribute($target, "BMC_DT_MEMORY");
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

    #The first one is from the MRW, the next one is more generic
    #and just <mfgr>-<model>.

    if (!$g_targetObj->isBadAttribute($g_bmc, "BMC_DT_COMPATIBLE", "NA")) {
        my $attr = $g_targetObj->getAttribute($g_bmc, "BMC_DT_COMPATIBLE");
        push @compats, $attr;
    }

    push @compats, lc($g_bmcMfgr).",".lc($g_bmcModel);

    return @compats;
}


#Returns a string for the system's BMC model property
sub getSystemBMCModel()
{
    #<System> BMC
    my $sys = lc $g_systemName;
    $sys = uc(substr($sys, 0, 1)) . substr($sys, 1);

    return $sys . " BMC";
}


#Prints a list of nodes at the same indent level
#  $f = file handle
#  $level = indent level (0,1,etc)
#  @nodes = array of node hashes to print, where the
#  key for the hash is the name of the node
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
#  $f = file handle
#  $level = indent level (0,1,etc)
#  $name = the name of the node - shows up as:
#     name { ...
#  %vals = The contents of the node, with the following options:
#     if the key is:
#     - 'DTSI_INCLUDE', then value gets turned into a #include
#     - 'COMMENT', then value gets turned into a // comment (coming soon)
#     - 'STANDALONE_PROPERTY' then value gets turned into:  value;
#
#     If the value is:
#     - a hash - then that hash gets turned into a child node
#       where the key is the name of the child node
#     - an array of hashes indicates an array of nodes (coming soon)
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

    #Now print the includes, if any.
    if ($include ne "") {
        my @incs = split(',', $include);
        foreach my $i (@incs) {
            print $f "#include \"$i\";\n";
        }
    }

    print $f indent($level) . "};\n";
}


#Prints a comma separated list of properties.
#e.g.  a = "b, c, d";
#  $f = file handle
#  $level = indent level (0,1,etc)
#  $name = name of property
#  @vals = list of property values
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
#  $f = file handle
#  $level = indent level (0,1,etc)
#  $name = name of property
#  @vals = property values
sub printProperty()
{
    my ($f, $level, $name, $val) = @_;
    print $f indent($level) . "$name = \"" . convertAlias($val) . "\";\n";
}


#Prints a standalone property e.g. some-property;
#  $f = file handle
#  $level = indent level (0,1,etc)
#  $name = name of property
sub printStandaloneProperty()
{
    my ($f, $level, $name) = @_;
    print $f indent($level) . "$name;\n";
}


#Replace '(alias)' with '&'.
#Needed because Serverwiz doesn't properly escape '&'s in the XML,
#so the '(alias)' string is used to represent the alias
#specifier instead of '&'.
sub convertAlias() {
    my $val = shift;
    $val =~ s/\(alias\)/&/g;
    return $val
}


#Returns the target for the BMC chip.
#Not worrying about multiple BMC systems for now.
sub getBMCTarget()
{
    foreach my $target (sort keys %{ $g_targetObj->getAllTargets() })
    {
        if ($g_targetObj->getType($target) eq "BMC") {
           return $target;
        }
    }
    return "";
}


#Prints the device tree version line.
#  $f = file handle
sub printVersion()
{
    my $f = shift;
    print $f VERSION."\n"
}


#Prints the #include line for pulling in an include file.
#  $f = file handle
#  $level = indent level (0,1,etc)
sub printIncludes()
{
    my ($f, $level) = @_;
    my @includes = getIncludes($g_bmc);

    foreach my $i (@includes) {
        #if a .dtsi, gets " ", otherwise < >
        if ($i =~ /\.dtsi$/) {
            $i = "\"" . $i . "\"";
        }
        else {
            $i = "<" . $i . ">";
        }
        print $f indent($level) . "#include $i;\n";
    }
}


#Returns an array of includes from the BMC_DT_INCLUDES attribute
#on the target passed in.
#  $target = the target to get the includes from
sub getIncludes()
{
    my $target = shift;
    my @includes;


    if (!$g_targetObj->isBadAttribute($target, "BMC_DT_INCLUDES")) {
        my $attr = $g_targetObj->getAttribute($target, "BMC_DT_INCLUDES");
        my @incs = split(',', $attr);

        foreach my $i (@incs) {
            if ($i ne "NA") {
                push @includes, $i
            }
        }
    }

    return @includes;
}


#Prints the root node starting bracket.
#  $f = file handle
sub printRootNodeStart() {
    my $f = shift;
    print $f "\\ \{\n";
}


#Prints the root node ending bracket.
#  $f = file handle
#  $level = indent level (0,1,etc)
sub printRootNodeEnd() {
    my ($f, $level) = @_;
    print $f indent($level)."\};\n";
}


#Returns a string that can be used to indent based on the
#level passed in.  Each level is an additional 4 spaces.
#  $level = indent level (0,1,etc)
sub indent() {
    my $level = shift;
    return ' ' x ($level * 4);
}


sub printUsage
{
    print "gen_devtree.pl -x [XML filename] -o [output filename]\n";
    exit(1);
}
