#!/usr/bin/env perl

#This script replaces MRW attribute names with their values from the
#MRW XML in any file.  In addition, it can evaluate mathematical
#expressions if they are in [[ ]]s and can use variables passed in from
#the command line in those expressions.
#
#For example, if the attribute FOO has a value of 50 in the MRW, and
#the program was started with: -v "MY_VAR1=200 MY_VAR2=400"
#
#then the line
#  [[(MRW_FOO * MY_VAR1) + 5]]..[[MRW_FOO * MY_VAR2]]
#
#would get written out as:
#  10005..20000
#

use strict;
use warnings;

use mrw::Targets; # Set of APIs allowing access to parsed ServerWiz2 XML output
use Getopt::Long; # For parsing command line arguments

# Globals
my $force          = 0;
my $serverwizFile  = "";
my $debug          = 0;
my $outputFile     = "";
my $settingsFile   = "";
my $expressionVars = "";
my %exprVars;

# Command line argument parsing
GetOptions(
"f"   => \$force,            # numeric
"i=s" => \$serverwizFile,    # string
"o=s" => \$outputFile,       # string
"s=s" => \$settingsFile,     # string
"v=s" => \$expressionVars,   # string
"d"   => \$debug,
)
or printUsage();

if (($serverwizFile eq "") or ($outputFile eq "") or ($settingsFile eq "") )
{
    printUsage();
}

# API used to access parsed XML data
my $targetObj = Targets->new;
if($debug == 1)
{
    $targetObj->{debug} = 1;
}

if($force == 1)
{
    $targetObj->{force} = 1;
}

$targetObj->loadXML($serverwizFile);
print "Loaded MRW XML: $serverwizFile \n";

open(my $inFh, '<', $settingsFile) or die "Could not open file '$settingsFile' $!";
open(my $outFh, '>', $outputFile) or die "Could not open file '$outputFile' $!";

if (length($expressionVars) > 0)
{
    loadVars($expressionVars);
}

# Process all the targets in the XML
foreach my $target (sort keys %{$targetObj->getAllTargets()})
{
    # A future improvement could be to specify the MRW target.
    next if ("SYS" ne $targetObj->getType($target, "TYPE"));
    # Read the settings YAML replacing any MRW_<variable name> with their
    # MRW value
    while (my $row = <$inFh>)
    {
        while ($row =~ /MRW_(.*?)\W/g)
        {
            my $setting = $1;
            my $settingValue = $targetObj->getAttribute($target, $setting);
            $row =~ s/MRW_${setting}/$settingValue/g;
        }
        print $outFh $row;
    }
    last;
    close $inFh;
    close $outFh;
}

#Parse the variable=value string passed in from the
#command line and load it into %exprVars.
sub loadVars
{
    my $varString = shift;

    #Example: "VAR1=VALUE1 VAR2=VALUE2"
    my @entries = split(' ', $varString);

    for my $entry (@entries)
    {
        my ($var, $value) = $entry =~ /(.+)=(.+)/;

        if ((not defined $var) || (not defined $value))
        {
            die "Could not parse expression variable string $varString\n";
        }

        $exprVars{$var} = $value;
    }
}

# Usage
sub printUsage
{
    print "
    $0 -i [XML filename] -s [Settings YAML] -o [Output filename] -v [expr vars] [OPTIONS]

Required:
    -i = MRW XML filename
    -s = The Setting YAML with MRW variables in MRW_<MRW variable name> format
    -o = YAML output filename
Optional:
    -v = Variables and values for any [[expression]] evaluation
         in the form: \"VAR1=VALUE1 VAR2=VALUE2\"
Options:
    -f = force output file creation even when errors
    -d = debug mode
    \n";
    exit(1);
}
