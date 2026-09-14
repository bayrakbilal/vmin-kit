# vmkit-check - the Virtualmin plugin contract.
#
# Not a domain feature: feature_suitable always says no, so the plugin is never
# offered on a virtual server. It is enabled globally (Features and Plugins)
# only so that Virtualmin asks it for settings_links, which is how the check
# page appears under System Settings.
use strict;
use warnings;
our (%text);
our $module_name;

require 'vmkit-check-lib.pl';

sub feature_name
{
return $text{'feat_name'};
}

sub feature_label
{
return $text{'feat_name'};
}

sub feature_disname
{
return $text{'feat_name'};
}

sub feature_losing
{
return "";
}

sub feature_suitable
{
return 0;
}

# settings_links()
# One link under System Settings, next to Re-Check Configuration. A link
# starting with '/' is taken as-is by Virtualmin (outside its own module).
sub settings_links
{
return ( { 'link'  => "/$module_name/",
	   'title' => $text{'index_title'},
	   'icon'  => 'check',
	   'cat'   => 'setting' } );
}

1;
