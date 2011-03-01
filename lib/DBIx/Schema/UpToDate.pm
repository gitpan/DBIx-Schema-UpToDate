#
# This file is part of DBIx-Schema-UpToDate
#
# This software is copyright (c) 2011 by Randy Stauner.
#
# This is free software; you can redistribute it and/or modify it under
# the same terms as the Perl 5 programming language system itself.
#
package DBIx::Schema::UpToDate;
BEGIN {
  $DBIx::Schema::UpToDate::VERSION = '0.005';
}
BEGIN {
  $DBIx::Schema::UpToDate::AUTHORITY = 'cpan:RWSTAUNER';
}
# ABSTRACT: Helps keep a database schema up to date

use strict;
use warnings;
use Carp qw(croak carp); # core


sub new {
	my $class = shift;
	my $self = {
		auto_update => 1,
		transactions => 1,
		@_ == 1 ? %{$_[0]} : @_
	};
	bless $self, $class;

	# make sure the database schema is current
	$self->up_to_date()
		if $self->{auto_update};

	return $self;
}


sub dbh {
	my ($self) = @_;
	return $self->{dbh};
}


sub current_version {
	my ($self) = @_;
	my $dbh = $self->dbh;
	my $table = $self->version_table_name;
	my $version;

	my $tables = $dbh->table_info('%', '%', $table, 'TABLE')
		->fetchall_arrayref;

	# if table exists query it for current database version
	if( @$tables ){
		my $v = $dbh->selectcol_arrayref(
			"SELECT version from $table ORDER BY version DESC LIMIT 1"
		)->[0];
		$version = $v
			if defined $v;
	}

	return $version;
}


sub initialize_version_table {
	my ($self) = @_;
	my $dbh = $self->dbh;

	$dbh->do('CREATE TABLE ' . $self->version_table_name .
		' (version integer, updated timestamp)'
	)
		or croak $dbh->errstr;

	$self->set_version(0);
}


sub latest_version {
	my ($self) = @_;
	return scalar @{ $self->updates };
}


sub set_version {
	my ($self, $version) = @_;
	my $dbh = $self->dbh;

	$dbh->do('INSERT INTO ' . $self->version_table_name .
		' (version, updated) VALUES(?, ?)',
		{}, $version, time()
	)
		or croak $dbh->errstr;
}


sub updates {
	my ($self) = @_;
	return $self->{updates} ||= [
	];
}


sub update_to_version {
	my ($self, $version) = @_;
	my $dbh = $self->dbh;

	if( $self->{transactions} ){
		$dbh->begin_work()
			or croak $dbh->errstr;
	}

	# execute updates to bring database to $version
	$self->updates->[$version - 1]->($self);

	# save the version now in case we get interrupted before the next commit
	$self->set_version($version);

	if( $self->{transactions} ){
		$dbh->commit()
			or croak $dbh->errstr;
	}
}


sub up_to_date {
	my ($self) = @_;

	my $current = $self->current_version;
	if( !defined($current) ){
		$self->initialize_version_table;
		$current = $self->current_version;
		die("Unable to initialize version table\n")
			if !defined($current);
	}

	my $latest = $self->latest_version;

	# execute each update required to go from current to latest version
	# (starting with next version, obviously (don't redo current))
	$self->update_to_version($_)
		foreach ($current + 1) .. $latest;
}


sub version_table_name {
	'schema_version'
}

1;


__END__
=pod

=for :stopwords Randy Stauner TODO dbh cpan testmatrix url annocpan anno bugtracker rt
cpants kwalitee diff irc mailto metadata placeholders

=head1 NAME

DBIx::Schema::UpToDate - Helps keep a database schema up to date

=head1 VERSION

version 0.005

=head1 SYNOPSIS

	package Local::Database;
	use parent 'DBIx::Schema::UpToDate';

	sub updates {
		my ($self) = @_;
		my $dbh = $self->dbh;
		$self->{updates} ||= [
			sub {
				$dbh->do('-- sql');
				$self->do_something_else;
			},
		];
	}

	package main;

	my $dbh = DBI->connect(@connection_args);
	Local::Database->new(dbh => $dbh);

	# do something with $dbh which now contains the schema you expect

=head1 DESCRIPTION

This module provides a base class for keeping a database schema up to date.
If you need to make changes to the schema
in remote databases in an automated manner
you may not be able to ensure what version of the database is installed
by the time it gets the update.
This module will apply patches sequentially to bring the database schema
up to the latest version from whatever the current version is.

The aim of this module is to enable you to write incredibly simple subclasses
so that all you have to do is define the updates you want to apply.
This is done with subs (coderefs) so you can access the object
and its database handle.

It is intentionally simple and is not intended for large scale applications.
It may be a good fit for small embedded databases.
It can also be useful if you need to reference other parts of your application
as the subs allow you to utilize the object (and anything else you can reach).
Check L</SEE ALSO> for alternative solutions
and pick the one that's right for your situation.

=head1 USAGE

Subclasses should overwrite L</updates>
to return an arrayref of subs (coderefs) that will be executed
to bring the schema up to date.

The rest of the methods are small in the hopes that you
can overwrite the ones you need to get the customization you require.

The updates can be run individually (outside of L</up_to_date>)
for testing your subs...

	my $dbh = DBI->connect(@in_memory_database);
	my $schema = DBIx::Schema::UpToDate->new(dbh => $dbh, auto_update => 0);

	# don't forget this:
	$schema->initialize_version_table;

	$schema->update_to_version(1);
	# execute calls on $dbh to test changes
	$schema->dbh->do( @something );
	# test row output or column information or whatever
	ok( $test_something, $here );

	$schema->update_to_version(2);
	# test things

	$schema->update_to_version(3);
	# test changes

	...

	is($schema->current_version, $schema->latest_version, 'updated to latest version');
	done_testing;

=head1 METHODS

=head2 new

Constructor;  Accepts a hash or hashref of options.

Options used by the base module:

=over 4

=item *

C<dbh> - A B<d>ataB<b>ase B<h>andle (as returned from C<< DBI->connect >>)

Database commands will be executed against this handle.

=item *

C<auto_update> - Boolean

By default L</up_to_date> is called at initialization
(just after being blessed).
Set this value to false to disable this if you need to do something else
before updating.  You will have to call L</up_to_date> yourself.

=item *

C<transactions> - Boolean

By default L</update_to_version> does its work in a transaction.
Set this value to false to disable this behavior
(in case your database doesn't support transactions).

=back

=head2 dbh

Returns the object's database handle.

=head2 current_version

Determine the current version of the database schema.

=head2 initialize_version_table

Create the version metadata table in the database and
insert initial version record.

=head2 latest_version

Returns the latest [possible] version of the database schema.

=head2 set_version

	$cache->set_version($verison);

Sets the current database version to C<$version>.
Called from L</update_to_version> after executing the appropriate update.

=head2 updates

Returns an arrayref of subs (coderefs)
that can be used to update the database from one version to the next.
This is used by L</up_to_date> to replay a recorded database history
on the L</dbh> until the database schema is up to date.

=head2 update_to_version

	$cache->update_to_version($version);

Executes the update associated with C<$version>
in order to bring database up to that version.

=head2 up_to_date

Ensures that the database is up to date.
If it is not it will apply updates
after L</current_version> up to L</latest_version>
to bring the schema up to date.

=head2 version_table_name

The name to use the for the schema version metadata.

Defaults to C<'schema_version'>.

=head1 TODO

=over 4

=item *

Come up with a better name (too late).

=item *

Use L<DBI/quote_identifier> on the table name

=item *

Add an initial_version attribute to allow altering the history

=back

=head1 RATIONALE

I had already written most of the logic for this module in another project
when I realized I should abstract it.
Then I went looking and found the modules listed in L</SEE ALSO>
but didn't find one that fit my needs, so I released what I had made.

=head1 SEE ALSO

=over 4

=item *

L<DBIx::VersionedSchema>

Was close to what I was looking for, but not customizable enough.
Were I to subclass it I would have needed to overwrite the two main methods.

=item *

L<DBIx::VersionedDDL>

Much bigger scale than what I was looking for.
Needed something without L<Moose>.

=item *

L<ORLite::Migrate> (L<http://use.perl.org/~Alias/journal/38087>)

Much bigger scale than what I was looking for.
Wasn't using L<ORLite>, and didn't want to use separate script files.

=back

=head1 SUPPORT

=head2 Perldoc

You can find documentation for this module with the perldoc command.

  perldoc DBIx::Schema::UpToDate

=head2 Websites

The following websites have more information about this module, and may be of help to you. As always,
in addition to those websites please use your favorite search engine to discover more resources.

=over 4

=item *

Search CPAN

L<http://search.cpan.org/dist/DBIx-Schema-UpToDate>

=item *

RT: CPAN's Bug Tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=DBIx-Schema-UpToDate>

=item *

AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/DBIx-Schema-UpToDate>

=item *

CPAN Ratings

L<http://cpanratings.perl.org/d/DBIx-Schema-UpToDate>

=item *

CPAN Forum

L<http://cpanforum.com/dist/DBIx-Schema-UpToDate>

=item *

CPANTS Kwalitee

L<http://cpants.perl.org/dist/overview/DBIx-Schema-UpToDate>

=item *

CPAN Testers Results

L<http://cpantesters.org/distro/D/DBIx-Schema-UpToDate.html>

=item *

CPAN Testers Matrix

L<http://matrix.cpantesters.org/?dist=DBIx-Schema-UpToDate>

=back

=head2 Bugs / Feature Requests

Please report any bugs or feature requests by email to C<bug-dbix-schema-uptodate at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=DBIx-Schema-UpToDate>. You will be automatically notified of any
progress on the request by the system.

=head2 Source Code


L<http://github.com/magnificent-tears/DBIx-Schema-UpToDate/tree>

  git clone git://github.com/magnificent-tears/DBIx-Schema-UpToDate.git

=head1 AUTHOR

Randy Stauner <rwstauner@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2011 by Randy Stauner.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

