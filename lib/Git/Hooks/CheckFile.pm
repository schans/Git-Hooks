#!/usr/bin/env perl

package Git::Hooks::CheckFile;
# ABSTRACT: Git::Hooks plugin for checking files

use 5.010;
use utf8;
use strict;
use warnings;
use Git::Hooks qw/:DEFAULT :utils/;
use Text::Glob qw/glob_to_regex/;
use Path::Tiny;
use List::MoreUtils qw/any none/;
use Error qw(:try);

my $PKG = __PACKAGE__;
(my $CFG = __PACKAGE__) =~ s/.*::/githooks./;

sub check_command {
    my ($git, $commit, $file, $command) = @_;

    my $tmpfile = $git->blob($commit, $file);
    $tmpfile or return;

    # interpolate filename in $command
    (my $cmd = $command) =~ s/\{\}/\'$tmpfile\'/g;

    # execute command and update $errors
    my $saved_output = redirect_output();
    my $exit = system $cmd;
    my $output = restore_output($saved_output);
    if ($exit != 0) {
        $command =~ s/\{\}/\'$file\'/g;
        my $message = do {
            if ($exit == -1) {
                "command '$command' could not be executed: $!";
            } elsif ($exit & 127) {
                sprintf("command '%s' was killed by signal %d, %s coredump",
                        $command, ($exit & 127), ($exit & 128) ? 'with' : 'without');
            } else {
                sprintf("command '%s' failed with exit code %d", $command, $exit >> 8);
            }
        };

        # Replace any instance of the $tmpfile name in the output by
        # $file to avoid confounding the user.
        $output =~ s/\Q$tmpfile\E/$file/g;

        $git->error($PKG, $message, $output);
        return;
    } else {
        # FIXME: What we should do with eventual output from a
        # successful command?
    }
    return 1;
}

sub check_new_files {
    my ($git, $commit, @files) = @_;

    return 1 unless @files;     # No new file to check

    # Construct a list of command checks from the
    # githooks.checkfile.name configuration. Each check in the list is a
    # pair containing a regex and a command specification.
    my @name_checks;
    foreach my $check ($git->get_config($CFG => 'name')) {
        my ($pattern, $command) = split / /, $check, 2;
        if ($pattern =~ m/^qr(.)(.*)\g{1}/) {
            $pattern = qr/$2/;
        } else {
            $pattern = glob_to_regex($pattern);
        }
        $command .= ' {}' unless $command =~ /\{\}/;
        push @name_checks, [$pattern => $command];
    }

    # See if we have to check a file size limit
    my $sizelimit = $git->get_config($CFG => 'sizelimit');

    # Grok all REGEXP checks
    my %re_checks;
    foreach my $name (qw/basename path/) {
        foreach my $check (qw/deny allow/) {
            $re_checks{$name}{$check} = [map {qr/$_/} $git->get_config("$CFG.$name" => $check)];
        }
    }

    # Now we iterate through every new file and apply to them the matching
    # commands.
    my $errors = 0;

  FILE:
    foreach my $file (@files) {
        my $basename = path($file)->basename;

        if (any  {$basename =~ $_} @{$re_checks{basename}{deny}} and
            none {$basename =~ $_} @{$re_checks{basename}{allow}}) {
            $git->error($PKG, "File '$file' basename was denied.");
            ++$errors;
            next FILE;          # Don't botter checking the contents of invalid files
        }

        if (any  {$file =~ $_} @{$re_checks{path}{deny}} and
            none {$file =~ $_} @{$re_checks{path}{allow}}) {
            $git->error($PKG, "File '$file' path was denied.");
            ++$errors;
            next FILE;          # Don't botter checking the contents of invalid files
        }

        my $size = $git->file_size($commit, $file);
        if ($sizelimit && $sizelimit < $size) {
            $git->error($PKG, "File '$file' has $size bytes but the current limit is just $sizelimit bytes.");
            ++$errors;
            next FILE;    # Don't botter checking the contents of huge files
        }

        foreach my $command (map {$_->[1]} grep {$basename =~ $_->[0]} @name_checks) {
            check_command($git, $commit, $file, $command)
                or ++$errors;
        }
    }

    return $errors == 0;
}

# This routine can act both as an update or a pre-receive hook.
sub check_affected_refs {
    my ($git) = @_;

    return 1 if im_admin($git);

    my $errors = 0;

    foreach my $ref ($git->get_affected_refs()) {
        my ($old_commit, $new_commit) = $git->get_affected_ref_range($ref);
        check_new_files($git, $new_commit, $git->filter_files_in_range('AM', $old_commit, $new_commit))
            or ++$errors;
    }

    return $errors == 0;
}

sub check_commit {
    my ($git) = @_;

    return check_new_files($git, ':0', $git->filter_files_in_index('AM'));
}

sub check_patchset {
    my ($git, $opts) = @_;

    return 1 if im_admin($git);

    return check_new_files($git, $opts->{'--commit'}, $git->filter_files_in_commit('AM', $opts->{'--commit'}));
}

# Install hooks
PRE_COMMIT       \&check_commit;
UPDATE           \&check_affected_refs;
PRE_RECEIVE      \&check_affected_refs;
REF_UPDATE       \&check_affected_refs;
PATCHSET_CREATED \&check_patchset;
DRAFT_PUBLISHED  \&check_patchset;

1;

__END__
=for Pod::Coverage check_command check_new_files check_affected_refs check_commit check_patchset

=head1 NAME

CheckFile - Git::Hooks plugin for checking files

=head1 DESCRIPTION

This Git::Hooks plugin hooks itself to the hooks below to check if the
contents of files added to or modified in the repository meet specified
constraints. If they don't, the commit/push is aborted.

=over

=item * B<pre-commit>

=item * B<update>

=item * B<pre-receive>

=item * B<ref-update>

=item * B<patchset-created>

=item * B<draft-published>

=back

To enable it you should add it to the githooks.plugin configuration
option:

    git config --add githooks.plugin CheckFile

=head1 CONFIGURATION

The plugin is configured by the following git options.

=head2 githooks.checkfile.name PATTERN COMMAND

This directive tells which COMMAND should be used to check files matching
PATTERN.

Only the file's basename is matched against PATTERN.

PATTERN is usually expressed with
L<globbing|https://metacpan.org/pod/File::Glob> to match files based on
their extensions, for example:

    git config githooks.checkfile.name *.pl perlcritic --stern

If you need more power than globs can provide you can match using L<regular
expressions|http://perldoc.perl.org/perlre.html>, using the C<qr//>
operator, for example:

    git config githooks.checkfile.name qr/xpto-\\d+.pl/ perlcritic --stern

COMMAND is everything that comes after the PATTERN. It is invoked once for
each file matching PATTERN with the name of a temporary file containing the
contents of the matching file passed to it as a last argument.  If the
command exits with any code different than 0 it is considered a violation
and the hook complains, rejecting the commit or the push.

If the filename can't be the last argument to COMMAND you must tell where in
the command-line it should go using the placeholder C<{}> (like the argument
to the C<find> command's C<-exec> option). For example:

    git config githooks.checkfile.name *.xpto cmd1 --file {} | cmd2

COMMAND is invoked as a single string passed to C<system>, which means it
can use shell operators such as pipes and redirections.

Some real examples:

    git config --add githooks.checkfile.name *.p[lm] perlcritic --stern --verbose 5
    git config --add githooks.checkfile.name *.pp    puppet parser validate --verbose --debug
    git config --add githooks.checkfile.name *.pp    puppet-lint --no-variable_scope-check
    git config --add githooks.checkfile.name *.sh    bash -n
    git config --add githooks.checkfile.name *.sh    shellcheck --exclude=SC2046,SC2053,SC2086
    git config --add githooks.checkfile.name *.erb   erb -P -x -T - {} | ruby -c

=head2 githooks.checkfile.sizelimit BYTES

This directive specifies a size limit (in bytes) for any file in the
repository. If set explicitly to 0 (zero), no limit is imposed, which is the
same as not specifying it. But it can be useful to override a global
specification in a particular repository.

=head2 githooks.checkfile.basename.deny REGEXP

This directive denies files which basenames match REGEXP.

=head2 githooks.checkfile.basename.allow REGEXP

This directive allows files which basenames match REGEXP. Since by default
all basenames are allowed this directive is useful only to prevent a
B<githooks.checkfile.basename.deny> directive to deny the same basename.

The basename checks are evaluated so that a file is denied only if it's
basename matches any B<basename.deny> directive and none of the
B<basename.allow> directives.  So, for instance, you would apply it like
this to allow the versioning of F<.gitignore> file while denying any other
file with a name beginning with a dot.

    [githooks "checkfile"]
        basename.allow ^\\.gitignore
        basename.deny  ^\\.

=head2 githooks.checkfile.path.deny REGEXP

This directive denies files which full paths match REGEXP.

=head2 githooks.checkfile.path.allow REGEXP

This directive allows files which full paths match REGEXP. It's useful in
the same way that B<githooks.checkfile.basename.deny> is.
