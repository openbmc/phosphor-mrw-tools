use Module::Build;

Module::Build->new(
    dist_name => 'MRWTools',
    dist_version => '1.0',
    license => 'perl',
    script_files => ['gen_devtree.pl', 'gen_led_groups.pl', 'hwmon.pl'],
    pm_files => {'Inventory.pm' => 'lib/mrw/Inventory.pm',
                 'Util.pm' => 'lib/mrw/Util.pm'},
)->create_build_script;
