use Module::Build;

Module::Build->new(
    dist_name => 'MRWTools',
    dist_version => '1.0',
    license => 'perl',
    script_files => ['gen_callouts.pl',
                     'gen_devtree.pl',
                     'gen_fru_properties.pl',
                     'gen_ipmi_fru.pl',
                     'gen_led_groups.pl',
                     'gen_openpower_fru.pl',
                     'hwmon.pl'],
    pm_files => {'Inventory.pm' => 'lib/mrw/Inventory.pm',
                 'Util.pm' => 'lib/mrw/Util.pm'},
)->create_build_script;
