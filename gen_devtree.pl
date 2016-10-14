#!/usr/bin/env perl

#Generates a BMC device tree syntax file from the machine
#readable workbook.

use strict;
use XML::Simple;
use mrw::Targets;
use Getopt::Long;
use YAML::Tiny qw(LoadFile);
use Scalar::Util qw(looks_like_number);

use constant {
    VERSION => "/dts-v1/;",
    ZERO_LENGTH_PROPERTY => "zero_length_property",
    PRE_ROOT_INCLUDES => "pre-root-node",
    ROOT_INCLUDES => "root-node",
    POST_ROOT_INCLUDES => "post-root-node"
};


my $serverwizFile;
my $configFile;
my $outputFile;
my $debug;

GetOptions("x=s" => \$serverwizFile,
           "y=s" => \$configFile,
           "o=s" => \$outputFile,
           "d" => \$debug)
or printUsage();

if ((not defined $serverwizFile) || (not defined $outputFile) ||
    (not defined $configFile)) {
    printUsage();
}

my %g_configuration = %{ LoadFile($configFile) };

my $g_targetObj = Targets->new;
$g_targetObj->loadXML($serverwizFile);

my ($g_bmc, $g_bmcModel, $g_bmcMfgr, $g_systemName);
setGlobalAttributes();

my $g_i2cBusAdjust = 0;
getI2CBusAdjust();

open (my $f, ">$outputFile") or die "Could not open $outputFile\n";

printVersion($f);
printIncludes($f, PRE_ROOT_INCLUDES);
printRootNodeStart($f);

printPropertyList($f, 1, "model", getSystemBMCModel());
printPropertyList($f, 1, "compatible", getBMCCompatibles());

printNode($f, 1, "aliases", getAliases());
printNode($f, 1, "chosen", getChosen());
printNode($f, 1, "memory", getBmcMemory());

printNodes($f, 1, getSpiFlashNodes());

printNode($f, 1, "leds", getLEDNode());

printIncludes($f, ROOT_INCLUDES);

printRootNodeEnd($f, 0);

printNodes($f, 0, getI2CNodes());
printNodes($f, 0, getMacNodes());
printNodes($f, 0, getUARTNodes());
printNodes($f, 0, getVuartNodes());

printIncludes($f, POST_ROOT_INCLUDES);

close $f;
exit 0;


#Finds the values for these globals:
# $g_bmc, $g_bmcModel, $g_bmcMfgr, $g_systemName
sub setGlobalAttributes()
{
    $g_bmc = getBMCTarget();
    if (length($g_bmc) == 0) {
        die "Unable to find a BMC in this system\n";
    }

    if ($g_targetObj->isBadAttribute($g_bmc, "MODEL")) {
        die "The MODEL attribute on $g_bmc is missing or empty.\n";
    }
    $g_bmcModel = $g_targetObj->getAttribute($g_bmc, "MODEL");

    if ($g_targetObj->isBadAttribute($g_bmc, "MANUFACTURER")) {
        die "The MANUFACTURER attribute on $g_bmc is missing or empty.\n";
    }
    $g_bmcMfgr = $g_targetObj->getAttribute($g_bmc, "MANUFACTURER");

    $g_systemName = $g_targetObj->getSystemName();
    if (length($g_systemName) == 0) {
        die "The SYSTEM_NAME attribute is not set on the system target.\n";
    }
}


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

    #Get the info from the config file

    if ((not exists $g_configuration{aliases}) ||
        (keys %{$g_configuration{aliases}} == 0)) {
        print "WARNING:  Missing or empty 'aliases' section in config file.\n";
        return %aliases;
    }
    %aliases = %{ $g_configuration{aliases} };

    #add a & reference if one is missing
    foreach my $a (keys %aliases) {
        if (($aliases{$a} !~ /^&/) && ($aliases{$a} !~ /^\(ref\)/)) {
            $aliases{$a} = "(ref)$aliases{$a}";
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
    my %chosen;
    my @allowed = qw(bootargs stdin-path stdout-path);

    #Get the info from the config file

    if (not exists $g_configuration{chosen}) {
        die "ERROR:  Missing 'chosen' section in config file.\n";
    }
    %chosen = %{ $g_configuration{chosen} };

    #Check for allowed entries.  Empty is OK.
    foreach my $key (keys %chosen) {
        my $found = 0;
        foreach my $good (@allowed) {
            if ($key eq $good) {
                $found = 1;
            }
        }

        if ($found == 0) {
            die "Invalid entry $key in 'chosen' section in config file\n";
        }
    }

    return %chosen;
}


#Return a hash that represents the 'memory' node.
#Will look like:
#  memory {
#     reg = < base size >
#  }
sub getBmcMemory()
{
    my %memory;

    #Get the info from the config file

    if (not exists $g_configuration{memory}) {
        die "ERROR:  Missing 'memory' section in config file.\n";
    }

    if ((not exists $g_configuration{memory}{base}) ||
        ($g_configuration{memory}{base} !~ /0x/)) {
        die "ERROR:  The base entry in the memory section in the config " .
            "file is either missing or invalid.\n";
    }

    if ((not exists $g_configuration{memory}{size}) ||
        ($g_configuration{memory}{size} !~ /0x/)) {
        die "ERROR:  The size entry in the memory section in the config " .
            "file is either missing or invalid.\n";
    }

    #Future: could do more validation on the actual values

    $memory{reg} = "<$g_configuration{memory}{base} " .
                   "$g_configuration{memory}{size}>";

    return %memory;
}



sub getSpiFlashNodes()
{
    #TODO: A new binding is coming soon that is much more simple than
    #the previous one.  When that is available, this function will
    #be updated to support it.  Before then, a root node include
    #will pick up the legacy spi flash nodes.
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
            $node{$name}{"use-ncsi"} = ZERO_LENGTH_PROPERTY;
        }
        if ($hwChecksum == 0) {
            $node{$name}{"no-hw-checksum"} = ZERO_LENGTH_PROPERTY;
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

#Returns a list of hashes that represent the I2C device nodes.
#There is 1 parent node for each bus, which then have subnodes
#for each device on that bus.  If a bus doesn't have any
#attached devices, it doesn't need to show up.
#The nodes will look like:
#  &i2c0 {
#     status = "okay"
#     device1@addr { (addr = 7 bit I2C address)
#       reg = <addr>
#       compatible = ...
#       ...
#     }
#     device2@addr {
#       reg = <addr>
#       ...
#     }
#  }
#  &i2c1 {
#  ...
#  }
sub getI2CNodes()
{
    my @nodes;
    my %busNodes;

    my $connections = findConnections($g_bmc, "I2C");

    if ($connections eq "") {
        print "WARNING:  No I2C buses found connected to the BMC\n";
        return @nodes;
    }

    foreach my $i2c (@{$connections->{CONN}}) {

        my %deviceNode, my $deviceName;

        $deviceNode{COMMENT} = "$i2c->{SOURCE} ->\n$i2c->{DEST_PARENT}";

        $deviceName = lc $i2c->{DEST_PARENT};
        $deviceName =~ s/-\d+$//; #remove trailing position
        $deviceName =~ s/.*\///;  #remove the front of the path

        #Get the I2C address
        my $i2cAddress = $g_targetObj->getAttribute($i2c->{DEST}, "I2C_ADDRESS");
        $i2cAddress = hex($i2cAddress);
        if ($i2cAddress == 0) {
            die "ERROR: Missing I2C address on $i2c->{DEST}\n";
        }

        #Put it in the format we want to print it in
        $i2cAddress = adjustI2CAddress($i2cAddress);
        $deviceNode{reg} = "<$i2cAddress>";

        $deviceName = makeNodeName($deviceName, $deviceNode{reg});

        #Get the I2C bus number
        if ($g_targetObj->isBadAttribute($i2c->{SOURCE},
                                         "I2C_PORT")) {
            die "ERROR: I2C_PORT attribute in $i2c->{DEST_PARENT} " .
                "is either missing or empty.\n";
        }

        my $busNum = $g_targetObj->getAttribute($i2c->{SOURCE}, "I2C_PORT");
        if ($busNum =~ /0x/i) {
            $busNum = hex($busNum);
        }

        #Convert the number to the Linux numbering scheme.
        $busNum += $g_i2cBusAdjust;

        #Get the compatible property
        if ($g_targetObj->isBadAttribute($i2c->{DEST_PARENT},
                                         "BMC_DT_COMPATIBLE")) {
            die "ERROR: BMC_DT_COMPATIBLE attribute in $i2c->{DEST_PARENT} " .
                "is either missing or empty.\n";
        }

        $deviceNode{compatible} = $g_targetObj->getAttribute(
                                                    $i2c->{DEST_PARENT},
                                                    "BMC_DT_COMPATIBLE");

        #Get any other part specific properties, where the property
        #names are actually defined in the XML.
        my %props = getPartDefinedDTProperties($i2c->{DEST_PARENT});
        foreach my $prop (sort keys %props) {
            $deviceNode{$prop} = $props{$prop};
        }

        #busNodeName is the hash twice so when we loop
        #below it doesn't get lost
        my $busNodeName = "i2c$busNum";
        $busNodes{$busNodeName}{$busNodeName}{status} = "okay";
        $busNodes{$busNodeName}{$busNodeName}{$deviceName} = { %deviceNode };
    }

    #Each bus gets its own hash entry in the array
    for my $b (sort keys %busNodes) {
        push @nodes, { %{$busNodes{$b}} };
    }

    return @nodes;
}


#Returns a hash of property names and values that should be stored in
#the device tree node for this device. The names of the properties and
#the attributes to find their values in are stored in the
#BMC_DT_ATTR_NAMES attribute in the chip.
#  $chip = the chip target
sub getPartDefinedDTProperties()
{
    my $chip = shift;
    my %props;

    if ($g_targetObj->isBadAttribute($chip, "BMC_DT_ATTR_NAMES")) {
        return %props;
    }

    my $attr = $g_targetObj->getAttribute($chip, "BMC_DT_ATTR_NAMES");
    $attr =~ s/\s//g;
    my @names = split(',', $attr);

    #There can be up to 4 entries in this attribute
    for (my $i = 0; $i < scalar @names; $i += 2) {

        #$names[$i] holds the name of the attribute.
        #$names[$i+1] holds the name of the property to store its value in.
        if (($names[$i] ne "NA") && ($names[$i] ne "")) {

            my $val = $g_targetObj->getAttribute($chip, $names[$i]);

            #if the value is empty, assume it's for a standalone property,
            #which gets turned into: some-property;
            if ($val eq "") {
                $props{$names[$i+1]} = ZERO_LENGTH_PROPERTY;
            }
            else {
                $props{$names[$i+1]} = "<$val>";
            }
        }
    }

    return %props;
}


#Convert the MRW I2C address into the format the dts needs
#  $addr = the I2C Address
sub adjustI2CAddress()
{
    my $addr = shift;

    #MRW holds the 8 bit value.  We need the 7 bit one.
    my $addr = $addr >> 1;
    $addr = sprintf("0x%X", $addr);
    $addr = lc $addr;

    return $addr;
}


#Sets the global $g_i2cBusAdjust from the configuration file.
sub getI2CBusAdjust()
{
    if (exists $g_configuration{"i2c-bus-adjust"}) {

        $g_i2cBusAdjust = $g_configuration{"i2c-bus-adjust"};

        if (!looks_like_number($g_i2cBusAdjust)) {
            die "ERROR:  Invalid i2c-bus-adjust value $g_i2cBusAdjust " .
                "found in config file.\n";
        }
    }
    else {
        $g_i2cBusAdjust = 0;
        print "WARNING: No I2C Bus number adjustment done " .
              "for this system.\n";
    }
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
#     - 'ZERO_LENGTH_PROPERTY' then value gets turned into:  value;
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

    #First print properties, then includes, then subnodes

    #Print Properties
    foreach my $v (sort keys %vals) {

        next if ($v eq "COMMENT");
        next if ($v eq "DTSI_INCLUDE");
        next if (ref($vals{$v}) eq "HASH");
        next if (ref($vals{$v}) eq "ARRAY");

        if ($vals{$v} ne ZERO_LENGTH_PROPERTY) {
            printProperty($f, $level+1, $v, $vals{$v});
        }
        else {
            printZeroLengthProperty($f, $level+1, $v);
        }
    }

    #Print Includes
    foreach my $v (sort keys %vals) {

        if ($v eq "DTSI_INCLUDE") {
            #print 1 include per line
            my @incs = split(',', $vals{$v});
            foreach my $i (@incs) {
                print $f qq(#include "$i";\n);
            }
        }
    }

    #Print Nodes
    foreach my $v (sort keys %vals) {

        if (ref($vals{$v}) eq "HASH") {
            printNode($f, $level+1, $v, %{$vals{$v}});
        }
        #An array of nested nodes
        elsif (ref($vals{$v}) eq "ARRAY") {
            my @array = @{$vals{$v}};
            &printNodes($f, $level+1, @array);
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
        print $f qq("$vals[$i]");
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
    my $quoteChar = qq(");

    $val = convertReference($val);

    #properties with < > or single word aliases don't need quotes
    if (($val =~ /<.*>/) || ($val =~ /^&\w+$/)) {
        $quoteChar = "";
    }

    print $f indent($level) . "$name = $quoteChar$val$quoteChar;\n";
}


#Prints a zero length property e.g. some-property;
#  $f = file handle
#  $level = indent level (0,1,etc)
#  $name = name of property
sub printZeroLengthProperty()
{
    my ($f, $level, $name) = @_;
    print $f indent($level) . "$name;\n";
}


#Replace '(ref)' with '&'.
#Needed because Serverwiz doesn't properly escape '&'s in the XML,
#so the '(ref)' string is used to represent the reference
#specifier instead of '&'.
sub convertReference() {
    my $val = shift;
    $val =~ s/\(ref\)/&/g;
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
#The files to include come from the configuration file.
#  $f = file handle
#  $type = include type
sub printIncludes()
{
    my ($f, $type) = @_;
    my @includes = getIncludes($type);

    foreach my $i (@includes) {
        #if a .dtsi, gets " ", otherwise < >
        if ($i =~ /\.dtsi$/) {
            $i = qq("$i");
        }
        else {
            $i = "<$i>";
        }
        print $f "#include $i\n";
    }
}


#Returns an array of include files found in the config file
#for the type specified.
# $type = the include type, which is the section name in the
#         YAML configuration file.
sub getIncludes()
{
    my $type = shift;
    my @includes;

    #The config file may have a section but no includes
    #listed in it, which is OK.
    if ((exists $g_configuration{includes}{$type}) &&
        (ref($g_configuration{includes}{$type}) eq "ARRAY")) {

        @includes = @{$g_configuration{includes}{$type}};
    }

    return @includes;
}


#Appends the first value of the 'reg' property
#passed in to the name passed in to create the
#full name for the node
#  $name = node name that will be appended to
#  $reg = the reg property values
sub makeNodeName()
{
    my ($name, $reg) = @_;

    $reg =~ s/<//g;
    $reg =~ s/>//g;
    my @vals = split(' ', $reg);

    if (scalar @vals > 0) {
        $vals[0] =~ s/0x//;
        $name .= "@" . lc $vals[0];
    }

    return $name;
}


#Prints the root node starting bracket.
#  $f = file handle
sub printRootNodeStart() {
    my $f = shift;
    print $f qq(/ {\n);
}


#Prints the root node ending bracket.
#  $f = file handle
#  $level = indent level (0,1,etc)
sub printRootNodeEnd() {
    my ($f, $level) = @_;
    print $f indent($level).qq(};\n);
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
    print "gen_devtree.pl -x [XML filename] -y [yaml config file] " .
          "-o [output filename]\n";
    exit(1);
}
