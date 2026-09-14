#!/usr/bin/perl
# Save or delete a deployment.
# This only writes the DEFINITION; pulling happens in deploy.cgi -> run_deploy().
use strict;
use warnings;
our (%text, %in);

require './vmkit-deploy-lib.pl';
&ReadParse();
&error_setup($text{'save_err'});

my $d = &domain_from_in();

my $dep;
if ($in{'new'}) {
	$dep = { };
	}
else {
	$dep = &get_deploy($d, $in{'id'});
	$dep || &error($text{'edit_egone'});
	}

# ---- per-field actions: "Check repository" and "Generate new URL" ----
# Both are submit buttons next to their own field. Nothing is saved; the form
# is redrawn with everything the user typed (the command box included) intact.
#
# Posting them elsewhere (formaction on the button) is ignored by the theme -
# the form always arrives here, so the two cases are separated here.
if ($in{'check'} || $in{'regen'}) {
	my ($fdep, $factions, $fnew) = &deploy_from_in($d);
	$fdep || &error($text{'edit_egone'});
	if ($in{'regen'} && $fdep->{'id'}) {
		# The UUID in the URL is a password: regenerating it invalidates
		# the old one at once, so it is written to disk immediately.
		$fdep->{'uuid'} = &new_uuid();
		&save_deploy($d, $fdep);
		&webmin_log("hookregen", "deploy",
			    $fdep->{'name'} || $fdep->{'id'});
		}
	&ui_print_header(&virtual_server::domain_in($d),
			 $fnew ? $text{'edit_title_new'} : $text{'edit_title'},
			 "", undef, 0, 0);
	&print_deploy_form($d, $fdep, $factions, $fnew);
	&ui_print_footer("index.cgi?dom=$d->{'id'}", $text{'edit_return'});
	exit;
	}

# ---- delete ----
# A CONFIRMATION SCREEN first: the action cannot be undone and its button sits
# right next to Save. The text also says WHAT IS NOT REMOVED - the fear that
# "delete" takes the site's files with it is strongest here.
if ($in{'delete'} && !$in{'confirm'}) {
	&ui_print_header(&virtual_server::domain_in($d), $text{'delete_title'},
			 "", undef, 0, 0);
	print "<p>",&text('delete_warn',
			  "<tt>".&html_escape($dep->{'name'} || $dep->{'id'})."</tt>"),
	      "</p>\n";
	print "<ul>\n";
	print "<li>$text{'delete_goes'}</li>\n";
	print "<li><b>",&text('delete_stays',
			      "<tt>".&html_escape(&deploy_target_dir($d, $dep))."</tt>"),
	      "</b></li>\n";
	print "</ul>\n";
	# The layout follows Virtualmin's own "Delete Server" page
	# (delete_domain.cgi): ONE primary action in the body, with cancel as a
	# navigation link in the footer rather than a second button.
	#
	# The button carries NO STYLE. The theme colours it from the LANGUAGE
	# KEY NAME - every generated button has data-entry="<key>" and the theme
	# reads that:
	#   delete, delete_ok -> btn-danger  (red)
	#   ...._ok           -> btn-success (green)
	#   anything else     -> btn-default
	# So whatever the label says, the key must be 'delete_ok'. Writing the
	# class by hand did not work and would tie us to one theme.
	#
	# 'delete' is the button's own name, so the confirmation flag is a
	# separate hidden field: absent on the first post, present on the second.
	print &ui_form_start("save_deploy.cgi", "post");
	print &ui_hidden("dom", $d->{'id'});
	print &ui_hidden("id", $dep->{'id'});
	print &ui_hidden("confirm", 1);
	print &ui_form_end([ [ "delete", $text{'delete_ok'} ] ]);
	# Two ways back, presented identically: the edit form and the list.
	&ui_print_footer("edit_deploy.cgi?dom=$d->{'id'}&id=$dep->{'id'}",
			 $text{'delete_cancel'},
			 "index.cgi?dom=$d->{'id'}", $text{'edit_return'});
	exit;
	}
if ($in{'delete'}) {
	&delete_deploy($d, $dep);
	&webmin_log("delete", "deploy", $dep->{'name'} || $dep->{'id'});
	&redirect("index.cgi?dom=$d->{'id'}");
	exit;
	}

# ---- validation ----
$in{'mode'} =~ /^(manual|auto)$/  || &error($text{'save_emode'});
$in{'name'} =~ /^[A-Za-z0-9._\- ]*$/ || &error($text{'save_ename'});

# The target directory may not escape the domain's home.
# The form field is relative to the DOCUMENT ROOT; it is stored relative to the
# home directory so deploy_target_dir and older records share one format.
my $target = &target_full($d, $in{'target'});
my $terr = &validate_target($d, $target);
&error($terr) if ($terr);

# No two deployments may share a target - it would be unclear which one wrote.
foreach my $other (&list_deploys($d)) {
	next if (!$in{'new'} && $other->{'id'} eq $dep->{'id'});
	if ($other->{'target'} eq $target) {
		&error(&text('save_edup', $other->{'name'} || $other->{'id'}));
		}
	}

# Is the repository really reachable, and does the branch exist there? Checked
# again even if the form already did: access may have changed in between, and a
# definition that cannot work should not be saved.
my ($defbranch, $branches, $rerr) = &remote_branches($d, $in{'repo'});
&error(&text('save_ereporeach', "<pre>".&html_escape($rerr)."</pre>")) if ($rerr);
&indexof($in{'branch'}, @$branches) >= 0 || &error($text{'save_ebranchgone'});

# ---- save ----
$dep->{'name'}   = $in{'name'};
$dep->{'repo'}   = $in{'repo'};
$dep->{'branch'} = $in{'branch'};
$dep->{'target'} = $target;
$dep->{'mode'}   = $in{'mode'};
$dep->{'actions_on'} = $in{'actions_on'} ? 1 : 0;
# The hook URL is generated when the form opens and carried in a hidden field,
# and that value is what gets written: the URL shown while adding must be the
# URL that is saved. The format is validated - this value is a password and is
# not taken from the form unchecked.
$dep->{'uuid'} = $in{'uuid'}
	if ($in{'uuid'} && $in{'uuid'} =~ /^[a-f0-9]{32}$/);
$dep->{'uuid'} ||= &new_uuid();
&save_deploy($d, $dep);

# The command text is NOT validated: free-form shell lines, no template. It
# grants no new privilege - the commands run as the domain's own user, only
# root or the domain owner can open this form, and the owner could already run
# the same commands over SSH or cron.
#
# Written AFTER save_deploy: that is where a new deployment's id is generated,
# and the command file's name depends on it.
&actions_write($d, $dep, $in{'actions'});

&webmin_log($in{'new'} ? "create" : "modify", "deploy",
	    $dep->{'name'} || $dep->{'id'});
&redirect("index.cgi?dom=$d->{'id'}");
