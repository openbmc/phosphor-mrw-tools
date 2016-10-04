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

printNode($f, 1, "aliases", getAliases());
printNode($f, 1, "chosen", getChosen());
printNode($f, 1, "memory", getMemory($g_bmc));

printNodes($f, 1, getSpiFlashNodes());

printNode($f, 1, "leds", getLEDNode());

printRootNodeEnd($f, 0);

printNodes($f, 0, getMacNodes());
printNodes($f, 0, getUARTNodes());
printNodes($f, 0, getVuartNodes());

close $f;
exit 0;


#Returns a hash that represents the 'aliases' node.
#Will look like:
#  aliases {
#    name1 = &val1;
#    name2 = &val2;
#    ...
#  }
sub getAliases()
{
    my %aliases;
    my $name, my $val;

    #The MRW supports up to 6 name and value pairs.
    for (my $i = 1; $i <= 6; $i++) {
        my $nameAttr = "name$i";
        my $valAttr = "value$i";

        $name = $g_targetObj->getAttributeField($g_bmc, "BMC_DT_ALIASES",
                                                $nameAttr);
        if ($name ne "") {
            $val =  $g_targetObj->getAttributeField($g_bmc, "BMC_DT_ALIASES",
                                                    $valAttr);
            #The value will be printed as '&val'
            $aliases{$name} = "(alias)$val";
        }
    }

    return %aliases;
}


#Return a hash that represents the 'chosen' node
#Will look like:
#   chosen {
#      stdout-path = ...
#      bootargs = ...
#   }
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


#Gets the nodes that represents the BMC's SPI flash chips.  They're based
#on information from the spi-master-unit end of the connection, with
#a subnode of information from the destination chip.
#On ASPEED chips, they're nested under the ahb node (Advanced
#High-performance Bus).
#Will look like:
#   ahb {
#     fmc@... {
#       reg = ...
#       #address-cells = ...
#       #size-cells = ...
#       #compatible = ...
#
#       flash@... {
#          reg = ...
#          compatible = ...
#          label = ...
# #include ...
#       }
#     }
#     spi@... {
#     ...
#     }
#   }
sub getSpiFlashNodes()
{
    my %parentNode, my %node, my @nodes;
    my $lastParentNodeName = "default";
    my $parentNodeName = "ahb";

    my $connections = findConnections($g_bmc, "SPI", "FLASH");
    if ($connections eq "") {
        print "WARNING:  No SPI flashes found connected to the BMC\n";
        return @nodes;
    }

    foreach my $spi (@{$connections->{CONN}}) {

        my %unitNode; #Node for the SPI master unit
        my %flashNode; #subnode for the flash chip itself
        my $flashNodeName = "flash";
        my $nodeLabel = "";
        my @addresses;


        #Adds a comment into the output file about the MRW connection
        #that makes up this node.  Not that {SOURCE} always represents
        #the master unit, and DEST_PARENT represents the destination
        #chip.  The destination unit {DEST} isn't usually that interesting.
        $unitNode{COMMENT} = "$spi->{SOURCE} ->\n$spi->{DEST_PARENT}";

        #These flashes are nested in the 'ahb' (an internal chip bus)
        #node in ASPEED chips.  Get the name of it here. Will default
        #to 'ahb' if not set.
        if (!$g_targetObj->isBadAttribute($spi->{SOURCE},
                                        "INTERNAL_BUS", "NA")) {
            $parentNodeName = $g_targetObj->getAttribute($spi->{SOURCE},
                                                       "INTERNAL_BUS");
            #Not going to support this unless we have to
            if ($parentNodeName != $lastParentNodeName) {
                die "ERROR: SPI master unit $spi->{SOURCE} has a " .
                    "different internal bus name $parentNodeName than " .
                    "previous name $lastParentNodeName\n";
            }
            else {
                $lastParentNodeName = $parentNodeName;
            }
        }
        else {
            print "WARNING: No INTERNAL_BUS attribute value found for " .
                  "SPI flash unit $spi->{SOURCE}. Using '$parentNodeName'\n";
        }

        #The reg base and size of the unit will be added into
        #the reg property
        my $regBase = $g_targetObj->getAttribute($spi->{SOURCE},
                                               "BMC_DT_REG_BASE");
        my $regSize = $g_targetObj->getAttribute($spi->{SOURCE},
                                               "BMC_DT_REG_SIZE");

        #There is also another memory range that goes into reg
        my %sourceRegHash = getMemory($spi->{SOURCE});

        #Insert the regBase and regSize to the memory < ... > property
        $unitNode{reg} = "< $regBase $regSize " . substr($sourceRegHash{reg}, 2);

        #usually, this will be something like 'smc' or 'spi'
        my $nodeName = "spi";
        if (!$g_targetObj->isBadAttribute($spi->{SOURCE},
                                        "BMC_DT_NODE_NAME")) {
            $nodeName = $g_targetObj->getAttribute($spi->{SOURCE},
                                                 "BMC_DT_NODE_NAME");
        }
        else {
            print "WARNING: No BMC_DT_NODE_NAME attribute value found for " .
                  "SPI flash unit $spi->{SOURCE}. Using 'spi'\n";
        }

        #now turn it into something like fmc@...
        $regBase =~ s/^0x//;
        $nodeName .= "@".$regBase;

        if (!$g_targetObj->isBadAttribute($spi->{SOURCE},
                                        "BMC_DT_COMPATIBLE")) {
            $unitNode{compatible} = $g_targetObj->
                    getAttribute($spi->{SOURCE}, "BMC_DT_COMPATIBLE");
        }
        else {
            print "WARNING: No BMC_DT_COMPATIBLE attribute found for SPI " .
                  "flash unit $spi->{SOURCE}\n";
        }

        #The flash chip has its one reg property as well
        if (!$g_targetObj->isBadAttribute($spi->{DEST_PARENT},
                                        "BMC_DT_REG_PROPERTY")) {
            $flashNode{reg} = $g_targetObj->getAttribute($spi->{DEST_PARENT},
                                                       "BMC_DT_REG_PROPERTY");
            $flashNode{reg} = "<" . $flashNode{reg} . ">";
        }
        else {
            print "WARNING: No BMC_REG_PROPERTY attribute found for SPI " .
                  "flash $spi->{DEST_PARENT}.  Using <0>.\n";
            $flashNode{reg} = "<0>";
        }

        if (!$g_targetObj->isBadAttribute($spi->{DEST_PARENT},
                                        "BMC_DT_COMPATIBLE")) {
            $flashNode{compatible} = $g_targetObj->
                    getAttribute($spi->{DEST_PARENT}, "BMC_DT_COMPATIBLE");
        }
        else {
            print "WARNING: No BMC_DT_COMPATIBLE attribute found for SPI " .
                  "flash $spi->{DEST_PARENT}\n";
        }

        if (!$g_targetObj->isBadAttribute($spi->{DEST_PARENT},
                                        "BMC_DT_LABEL_PROPERTY")) {
            $flashNode{label} = $g_targetObj->
                    getAttribute($spi->{DEST_PARENT}, "BMC_DT_LABEL_PROPERTY");
        }

        #Some flash chips have a .dtsi include to pull in more properties.
        #Future - contents of the includes could be pulled into the MRW
        #as new attributes.
        if (!$g_targetObj->isBadAttribute($spi->{DEST_PARENT},
                                        "BMC_DT_INCLUDES")) {
            my $incs = $g_targetObj->
                    getAttribute($spi->{DEST_PARENT}, "BMC_DT_INCLUDES");
            #first remove the spaces and NAs
            $incs =~ s/\s+//g;
            $incs =~ s/NA,*//g;
            $flashNode{DTSI_INCLUDE} = $incs;
        }

        #the flash subnode name also has its reg[0] appended
        #like flash@...
        @addresses = split(' ', $flashNode{reg});
        $addresses[0] =~ s/<//;
        $addresses[0] =~ s/>//;
        $flashNodeName .= "@" . $addresses[0];
        $unitNode{$flashNodeName} = { %flashNode };

        #For now, just support a chip with 1 reg value
        if (scalar @addresses == 1) {
            $unitNode{'#address-cells'} = "<1>";
            $unitNode{'#size-cells'} = "<0>";
        }
        else {
            die "ERROR:  Unsupported number of <reg> entries " .
                "in flash node $flashNodeName for SPI flash " .
                "$spi->{DEST_PARENT}.  Only 1 entry supported.\n";
        }

        #This node will end up being in an array on the parent node
        my %node;
        $node{$nodeName} = { %unitNode };
        push @nodes, { %node };
    }

    $parentNode{$parentNodeName}{nodes} = [ @nodes ];

    #There is always just one in the array
    my @finalNodes;
    push @finalNodes, { %parentNode };
    return @finalNodes;
}


#Returns a hash that represents the leds node by finding all of the
#GPIO connections to LEDs.
#Node will look like:
#   leds {
#       <ledname> {
#          gpios =  &gpio ASPEED_GPIO(x, y) GPIO_ACTIVE_xxx>
#       };
#       <another ledname> {
#       ...
#   }
sub getLEDNode()
{
    my %leds;

    $leds{compatible} = "gpio-led";

    my $connections = findConnections($g_bmc, "GPIO", "LED");

    if ($connections eq "") {
        print "WARNING:  No LEDs found connected to the BMC\n";
        return %leds;
    }

    foreach my $gpio (@{$connections->{CONN}}) {
        my %ledNode;

        $ledNode{COMMENT} = "$gpio->{SOURCE} ->\n$gpio->{DEST_PARENT}";

        #The node name will be the simplified LED name
        my $name = $gpio->{DEST_PARENT};
        $name =~ s/(-\d+$)//; #remove trailing position
        $name =~ s/.*\///;    #remove the front of the path

        #For now only supports ASPEED.
        if (uc($g_bmcMfgr) ne "ASPEED") {
            die "ERROR:  Unsupported BMC manufacturer $g_bmcMfgr\n";
        }
        my $num = $g_targetObj->getAttribute($gpio->{SOURCE}, "PIN_NUM");
        my $macro = getAspeedGpioMacro($num);

        #If it's active high or low
        my $state = $g_targetObj->getAttribute($gpio->{DEST_PARENT}, "ON_STATE");
        my $activeString = getGpioActiveString($state);

        $ledNode{gpios} = "<&gpio $macro $activeString>";

        $leds{$name} = { %ledNode };
    }

    return %leds;
}


#Returns a either GPIO_ACTIVE_HIGH or GPIO_ACTIVE_LOW
#  $val = either a 1 or a 0 for active high or low
sub getGpioActiveString() {
    my $val = shift;

    if ($val == 0) {
       return "GPIO_ACTIVE_LOW";
    }

    return "GPIO_ACTIVE_HIGH";
}


#Turns a GPIO number into something like ASPEED_GPIO(A, 0) for the
#ASPEED GPIO numbering scheme A[0-7] -> Z[0-7] and then starts at
#AA[0-7] after that.
#  $num = the GPIO number
sub getAspeedGpioMacro() {
    my $num = shift;
    my $char;
    my $offset = $num % 8;
    my $block = int($num / 8);

    #If past Z, wraps to AA, AB, etc
    if ((ord('A') + $block) > ord('Z')) {
        #how far past Z?
        $char = $block - (ord('Z') - ord('A'));

        #Don't let it wrap twice
        if ($char > (ord('Z') - ord('A') + 1)) {
            die "ERROR: Invalid PIN_NUM value $num found for GPIO\n";
        }

        #start back at 'A' again, and convert to a character
        $char = chr($char + ord('A') - 1);

        #Add in a bonus 'A', to get something like AB
        $char = "A".$char;
    }
    else {
        $char = ord('A') + $block;
        $char = chr($char);
    }

    return "ASPEED_GPIO($char, $offset)";
}


#Returns a list of hashes that represent the UART nodes on the BMC by
#finding the UART connections.
#Nodes will look like:
#  &uartX {
#     status = "okay"
#  }
sub getUARTNodes()
{
    my @nodes;

    #Using U750 for legacy MRW reasons
    my $connections = findConnections($g_bmc, "U750");

    if ($connections eq "") {
        print "WARNING:  No UART buses found connected to the BMC\n";
        return @nodes;
    }

    foreach my $uart (@{$connections->{CONN}}) {
        my %node;

        my $num = $g_targetObj->getAttribute($uart->{SOURCE}, "CHIP_UNIT");
        my $name = "uart$num";

        $node{$name}{status} = "okay";
        $node{$name}{COMMENT} = "$uart->{SOURCE} ->\n$uart->{DEST_PARENT}";

        push @nodes, { %node };
    }

    return @nodes;
}


#Returns a list of hashes that represent the MAC (ethernet) nodes on the BMC
#by finding the connections of type ETHERNET.
#Nodes will look like:
#  &macX {
#    ...
#  }
sub getMacNodes()
{
    my @nodes;

    my $connections = findConnections($g_bmc, "ETHERNET");

    if ($connections eq "") {
        print "WARNING:  No ethernet buses found connected to the BMC\n";
        return @nodes;
    }

    foreach my $eth (@{$connections->{CONN}}) {
        my %node;

        my $num = $g_targetObj->getAttribute($eth->{SOURCE}, "CHIP_UNIT");
        my $ncsi = $g_targetObj->getAttribute($eth->{SOURCE}, "NCSI_MODE");
        my $hwChecksum = $g_targetObj->getAttribute($eth->{SOURCE},
                                                  "USE_HW_CHECKSUM");

        my $name = "mac$num";
        $node{$name}{status} = "okay";

        if ($ncsi == 1) {
            $node{$name}{"use-ncsi"} = STANDALONE_PROPERTY;
        }
        if ($hwChecksum == 0) {
            $node{$name}{"no-hw-checksum"} = STANDALONE_PROPERTY;
        }

        $node{$name}{COMMENT} = "$eth->{SOURCE} ->\n$eth->{DEST_PARENT}";

        push @nodes, { %node };
    }

    return @nodes;
}


#Returns a list of hashes that represent the virtual UART nodes
#Node will look like:
#  &vuart {
#   status = "okay"
#  }
sub getVuartNodes()
{
    my @nodes;
    my %node;

    #For now, enable 1 node all the time.
    #TBD if this needs to be fixed
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
    my $val = "< ";

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
    $val .= " >";
    $property{reg} = $val;

    return %property;
}


#Returns a list of compatible fields for the BMC itself.
sub getBMCCompatibles()
{
    my @compats;

    #1st entry:  <system mfgr>,<system name>-bmc
    #2nd entry:  <bmc mfgr>,<bmc model>

    foreach my $target (sort keys %{ $g_targetObj->getAllTargets() }) {
        if ($g_targetObj->getType($target) eq "SYS") {
           my $mfgr = $g_targetObj->getAttribute($target, "MANUFACTURER");
           push @compats, lc "$mfgr,$g_systemName-bmc";
           last;
        }
    }

    push @compats, lc($g_bmcMfgr).",".lc($g_bmcModel);

    return @compats;
}


#Returns a string for the system's BMC model property
sub getSystemBMCModel()
{
    #'<System> BMC'
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
#     - 'COMMENT', then value gets turned into a // comment
#     - 'STANDALONE_PROPERTY' then value gets turned into:  value;
#
#     If the value is:
#     - a hash - then that hash gets turned into a child node
#       where the key is the name of the child node
#     - an array of hashes indicates an array of child nodes
sub printNode()
{
    my ($f, $level, $name, %vals) = @_;
    my $include = "";

    if ($level == 0) {
        $name = "&".$name;
    }

    print $f "\n";

    if (exists $vals{COMMENT}) {
        my @lines = split('\n', $vals{COMMENT});
        foreach my $l (@lines) {
            print $f indent($level) . "// $l\n";
        }
    }

    print $f indent($level) . "$name {\n";

    foreach my $v (sort keys %vals) {

        next if ($v eq "COMMENT");

        #A header file include, print it later
        if ($v eq DTSI_INCLUDE) {
            $include = $vals{$v};
        }
        #A nested node
        elsif (ref($vals{$v}) eq "HASH") {
            printNode($f, $level+1, $v, %{$vals{$v}});
        }
        #An array of nested nodes
        elsif (ref($vals{$v}) eq "ARRAY") {
            my @array = @{$vals{$v}};
            &printNodes($f, $level+1, @array);
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
    my $quote = "\"";

    $val = convertAlias($val);

    #properties with < > or single word aliases don't need quotes
    if (($val =~ /<.*>/) || ($val =~ /^&\w+$/)) {
        $quote = "";
    }

    print $f indent($level) . "$name = $quote$val$quote;\n";
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
        $attr =~ s/\s+//g; #remove whitespace
        $attr =~ s/NA,*//g; #remove the NAs
        my @incs = split(',', $attr);

        foreach my $i (@incs) {
            push @includes, $i
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


#Will look for all the connections of the specified type coming from
#any sub target of the specified target, instead of just 1 level down
#like the Targets inteface does.  Needed because sometimes we have
#target->pingroup->sourceunit instead of just target->sourceunit
#  $target = the target to find connections off of
#  $bus = the bus type
#  $partType = destination part type, leave off if a don't care
sub findConnections() {
    my ($target, $bus, $partType) = @_;
    my %allConnections;
    my $i = 0;

    #get the ones from target->child
    my $connections = $g_targetObj->findConnections($target, $bus, $partType);
    if ($connections ne "") {
        foreach my $c (@{$connections->{CONN}}) {
            $allConnections{CONN}[$i] = { %{$c} };
            $i++;
        }
    }

    #get everything deeper
    my @children = getAllTargetChildren($target);
    foreach my $c (@children) {
        my $connections = $g_targetObj->findConnections($c, $bus, $partType);
        if ($connections ne "") {

            foreach my $c (@{$connections->{CONN}}) {
                $allConnections{CONN}[$i] = { %{$c} };
                $i++;
            }
        }
    }

    #Match the Targets::findConnections return strategy
    if (!keys %allConnections) {
        return "";
    }

    return \%allConnections;
}

#Returns every sub target, not just the 1st level children.
#  $target = the target to find the children of
sub getAllTargetChildren()
{
    my $target = shift;
    my @children;

    my $targets = $g_targetObj->getTargetChildren($target);
    if ($targets ne "") {

        foreach my $t (@$targets) {
            push @children, $t;
            my @more = getAllTargetChildren($t);
            push @children, @more;
        }
    }

    return @children;
}


sub printUsage
{
    print "gen_devtree.pl -x [XML filename] -o [output filename]\n";
    exit(1);
}
