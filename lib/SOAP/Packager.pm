# ======================================================================
#
# Copyright (C) 2000-2004 Paul Kulchenko (paulclinger@yahoo.com)
# SOAP::Lite is free software; you can redistribute it
# and/or modify it under the same terms as Perl itself.
#
# $Id$
#
# ======================================================================

package SOAP::Packager;

use strict;
use vars;

use vars qw($SUPPORTED_TYPES);
$SUPPORTED_TYPES = { };

sub BEGIN {
  no strict 'refs';
  for my $method ( qw(parser headers_http persist_parts) ) {
    my $field = '_' . $method;
    *$method = sub {
      my $self = shift;
      if (@_) { $self->{$field} = shift; return $self }
      return $self->{$field};
    }
  }
}

sub new {
    my($class)  = shift;
    my(%params) = @_;
    bless {
        "_parts"         => [ ],
        "_parser"        => undef,
        "_persist_parts" => 0,
    }, $class;
}

sub is_supported_part {
  my $self = shift;
  return $SUPPORTED_TYPES->{ref $_[0]};
}

sub parts {
  my $self = shift;
  if (@_) {
    $self->{'_parts'} = shift;
  }
  return $self->{'_parts'};
}

# This is a static method that helps find the right Packager
sub find_packager {
   # TODO - Input:
   #        * the mimetype of the data to be decoded raw data that needs
   #        * the data to be decoded
   #        Returns: 
   #        * the proper SOAP::Packager instance
}

sub push_part {
   my $self = shift;
   my ($part) = @_;
   push @{$self->{'_parts'}}, $part;
}

sub package {
    # do nothing
    die "SOAP::Packager::package() must be implemented";
}

sub unpackage {
   my $self = shift;
   $self->{'_parts'} = [] if !$self->persist_parts; # experimental
}

# ======================================================================

package SOAP::Packager::MIME;

use strict;
use vars qw(@ISA);
@ISA = qw(SOAP::Packager);


sub BEGIN {
  no strict 'refs';
  for my $method ( qw(transfer_encoding env_id env_location env_type) ) {
    my $field = '_' . $method;
    *$method = sub {
      my $self = shift;
      if (@_) { $self->{$field} = shift; return $self }
      return $self->{$field};
    }
  }
}

sub new {
    my ($classname) = @_;
    my $self = SOAP::Packager::new(@_);
    $self->{'_content_encoding'} = '8bit';
    $self->{'_env_id'}           = '<main_envelope>';
    $self->{'_env_location'}     = '/main_envelope';
    $self->{'_env_type'}         = 'text/xml';
    # TODO - env_type could be application/soap etc - this needs to get its
    #        value from somewhere else!
    bless $self, $classname;
    $SOAP::Packager::SUPPORTED_TYPES->{"MIME::Entity"} = 1;
    return $self;
}

sub initialize_parser {
  my $self = shift;
  eval "require MIME::Parser;";
  die "Could not find MIME::Parser - is MIME::Tools installed? Aborting." if $@;
  $self->{'_parser'} = MIME::Parser->new;
  $self->{'_parser'}->output_to_core('ALL');
  $self->{'_parser'}->tmp_to_core(1);
  $self->{'_parser'}->ignore_errors(1);
}

sub generate_random_string {
  my ($self,$len) = @_;
  my @chars=('a'..'z','A'..'Z','0'..'9','_');
  my $random_string;
  foreach (1..$len) {
    $random_string .= $chars[rand @chars];
  }
  return $random_string;
}

sub get_multipart_id {
  my ($id) = shift;
  ($id || '') =~ /^<?([^>]+)>?$/; $1 || '';
}
 
sub package {
   my $self = shift;
   my ($envelope) = @_;
   return $envelope if (!$self->parts); # if there are no parts,
                                        # then there is nothing to do
   require MIME::Entity;
   local $MIME::Entity::BOUNDARY_DELIMITER = "\r\n";
   my $top = MIME::Entity->build('Type'     => "Multipart/Related");
   $top->attach('Type'                      => $self->env_type(),
                'Content-Transfer-Encoding' => $self->transfer_encoding(),
                'Content-Location'          => $self->env_location(),
                'Content-ID'                => $self->env_id(),
                'Data'                      => $envelope );
   # consume the attachments that come in as input by 'shift'ing
   no strict 'refs';
   while (my $part = shift(@{$self->parts})) {
      $top->add_part($part);
   }
   # determine MIME boundary
   my $boundary = $top->head->multipart_boundary;
   $self->headers_http({ 'Content-Type' => 'Multipart/Related; type="text/xml"; start="<main_envelope>"; boundary="'.$boundary.'"'});
   return $top->stringify_body;
}

sub unpackage {
  my $self = shift;
  my ($raw_input) = @_;
  $self->SUPER::unpackage();

  # Parse the raw input into a MIME::Entity structure.
  #   - fail if the raw_input is not MIME formatted
  $self->initialize_parser() if !defined($self->parser);
  my $entity = eval { $self->parser->parse_data($raw_input) }
    or die "Something wrong with MIME message: @{[$@ || $self->last_error]}\n";

  my $env = undef;
  # major memory bloat below! TODO - fix!
  if (lc($entity->head->mime_type) eq 'multipart/form-data') {
    $env = $self->process_form_data($entity);
  } elsif (lc($entity->head->mime_type) eq 'multipart/related') {
    $env = $self->process_related($entity);
  } elsif (lc($entity->head->mime_type) eq 'text/xml') {
    # I don't think this ever gets called.
    # warn "I am somewhere in the SOAP::Packager::MIME code I didn't know I would be in!";
    $env = $entity->bodyhandle->as_string;
  } else {
    die "Can't handle MIME messsage with specified type (@{[$entity->head->mime_type]})\n";
  }

  # return the envelope
  if ($env) {
    return $env;
  } elsif ($entity->bodyhandle->as_string) {
    return $entity->bodyhandle->as_string;
  } else {
    die "No content in MIME message\n";
  }
}

sub process_form_data { 
  my ($self, $entity) = @_;
  my $env = undef;  
  foreach my $part ($entity->parts) {
    my $name = $part->head->mime_attr('content-disposition.name');
    $name eq 'payload' ? 
      $env = $part->bodyhandle->as_string
	: $self->push_part($part);
  }
  return $env;
}

sub process_related {
  my $self = shift;
  my ($entity) = @_;
  die "Multipart MIME messages MUST declare Multipart/Related content-type"
    if ($entity->head->mime_attr('content-type') !~ /^multipart\/related/i);
  my $start = get_multipart_id($entity->head->mime_attr('content-type.start'))
    || get_multipart_id($entity->parts(0)->head->mime_attr('content-id'));
  my $location = $entity->head->mime_attr('content-location') ||
    'thismessage:/';
  my $env;
  foreach my $part ($entity->parts) {
    next if !UNIVERSAL::isa($part => "MIME::Entity");

    # Weird, the following use of head->get(SCALAR[,INDEX]) doesn't work as
    # expected. Work around is to eliminate the INDEX.
    my $pid = get_multipart_id($part->head->mime_attr('content-id'));

    # If Content-ID is not supplied, then generate a random one (HACK - because
    # MIME::Entity does not do this as it should... content-id is required
    # according to MIME specification)
    $pid = $self->generate_random_string(10) if $pid eq '';
    my $type = $part->head->mime_type;

    # If a Content-Location header cannot be found, this will look for an
    # alternative in the following MIME Header attributes
    my $plocation = $part->head->get('content-location') ||
      $part->head->mime_attr('Content-Disposition.filename') ||
	$part->head->mime_attr('Content-Type.name');
    if ($start && $pid eq $start) {
      $env = $part->bodyhandle->as_string;
    } else {
      $self->push_part($part) if (defined($part->bodyhandle));
    }
  }
  die "Can't find 'start' parameter in multipart MIME message\n"
    if @{$self->parts} > 1 && !$start;
  return $env;
}

# ======================================================================

# TODO - SOAP::Packager::DIME
package SOAP::Packager::DIME;

use strict;
use vars qw(@ISA);
@ISA = qw(SOAP::Packager);

1;
__END__

=pod

=head1 NAME

SOAP::Packager - this class is an abstract class which allows for multiple types of packaging agents such as MIME and DIME.

=head1 DESCRIPTION

The SOAP::Packager class is responsible for managing a set of "parts." Parts are
additional pieces of information, additional documents, or virtually anything that
needs to be associated with the SOAP Envelope/payload. The packager then will take
these parts and encode/decode or "package"/"unpackage" them as they come and go
over the wire.

=head1 METHODS

=over 

=item new

Instantiates a new instance of a SOAP::Packager.

=item parts

Contains an array of parts. The contents of this array and their types are completely
dependant upon the Packager being used. For example, when using MIME, the content
of this array is MIME::Entity's. 

=item push_part

Adds a part to set of parts managed by the current instance of SOAP::Packager.

=item parser

Returns the parser used to parse attachments out of a data stream.

=item headers_http

This is a hook into the HTTP layer. It provides a way for a packager to add and/or modify
HTTP headers in a request/response. For example, most packaging layers will need to
override the Content-Type (e.g. multipart/related, or application/dime).

=back

=head1 ABSTRACT METHODS

If you wish to implement your own SOAP::Packager, then the methods below must be
implemented by you according to the prescribed input and output requirements.

=over 

=item package()

The C<package> subroutine takes as input the SOAP envelope in string/SCALAR form.
This will serve as the content of the root part. The packager then encapsulates the
envelope with the parts contained within C<parts> and returns the properly
encapsulated envelope in string/SCALAR form.

=item unpackage()

The C<unpackage> subroutines takes as input raw data that needs to be parsed into
a set of parts. It is responsible for extracting the envelope from the input, and
populating C<parts> with an ARRAY of parts extracted from the input. It then returns
the SOAP Envelope in string/SCALAR form so that SOAP::Lite can parse it.

=back

=head1 SUPPORTED PACKAGING FORMATS

=head2 SOAP::Packager::MIME

C<SOAP::Packager::MIME> utilizes L<MIME::Tools> to provides the ability to send
and receive Multipart/Related and Multipart/Form-Data formatted requests and
responses.

=head3 METHODS

The following methods are used when composing a MIME formatted message.

=over

=item transfer_encoding

The value of the root part's Content-Transfer-Encoding MIME Header. Default is: 8bit.

=item env_id

The value of the root part's Content-Id MIME Header. Default is: <main_envelope>.

=item env_location

The value of the root part's Content-Location MIME Header. Default is: /main_envelope.

=item env_type

The value of the root part's Content-Type MIME Header. Default is: text/xml.

=back

=head3 OPTIMIZING THE MIME PARSER

The use of attachments can often result in a heavy drain on system resources depending
upon how your MIME parser is configured. For example, you can instruct the parser to
store attachments in memory, or to use temp files. Using one of the other can affect
performance, disk utilization, and/or reliability. Therefore you should consult the
following URL for optimization techniques and trade-offs:

http://search.cpan.org/dist/MIME-tools/lib/MIME/Parser.pm#OPTIMIZING_YOUR_PARSER

To modify the parser's configuration options consult the following code sample,
which incidentally shows how to minimize memory utilization:

  my $packager = SOAP::Packager::MIME->new;
  # $packager->parser->decode_headers(1); # no difference
  # $packager->parser->extract_nested_messages(1); # no difference
  $packager->parser->output_to_core(0); # much less memory
  $packager->parser->tmp_to_core(0); # much less memory
  $packager->parser->tmp_recycling(0); # promotes faster garbage collection
  $packager->parser->use_inner_files(1); # no difference
  my $client = SOAP::Lite->uri($NS)->proxy($URL)->packager($packager);
  $client->someMethod();

=head3 CLIENT SIDE EXAMPLE

The following code sample shows how to use attachments within the context of a
SOAP::Lite client.

  #!/usr/bin/perl
  use SOAP::Lite;
  use MIME::Entity;
  my $ent = build MIME::Entity
    Type        => "text/plain",
    Path        => "attachment.txt",
    Filename    => "attachment.txt",
    Disposition => "attachment";
  $NS = "urn:Majordojo:TemperatureService";
  $HOST = "http://localhost/cgi-bin/soaplite.cgi";
  my $client = SOAP::Lite
    ->packager(SOAP::Packager::MIME->new)
    ->parts([ $ent ])
    ->uri($NS)
    ->proxy($HOST);
  $response = $client->c2f(SOAP::Data->name("temperature" => '100'));
  print $response->valueof('//c2fResponse/foo');

=head3 SERVER SIDE EXAMPLE

The following code shows how to use attachments within the context of a CGI
script. It shows how to read incoming attachments, and to return attachments to
the client.

  #!/usr/bin/perl -w
  use SOAP::Transport::HTTP;
  use MIME::Entity;
  SOAP::Transport::HTTP::CGI
    ->packager(SOAP::Packager::MIME->new)
    ->dispatch_with({'urn:Majordojo:TemperatureService' => 'TemperatureService'})
    ->handle;
                                                                                                         
  BEGIN {
    package TemperatureService;
    use vars qw(@ISA);
    @ISA = qw(Exporter SOAP::Server::Parameters);
    use SOAP::Lite;
    sub c2f {
      my $self = shift;
      my $envelope = pop;
      my $temp = $envelope->dataof("//c2f/temperature");
      use MIME::Entity;
      my $ent = build MIME::Entity
        Type        => "text/plain",
        Path        => "printenv",
        Filename    => "printenv",
        Disposition => "attachment";
      # read attachments                                                                                                         
      foreach my $part (@{$envelope->parts}) {
        print STDERR "soaplite.cgi: attachment found! (".ref($part).")\n";
        print STDERR "soaplite.cgi: contents => ".$part->stringify."\n";
      }
      # send attachments                                                                                                         
      return SOAP::Data->name('convertedTemp' => (((9/5)*($temp->value)) + 32)),
        $ent;
    }
  }

=head2 SOAP::Packager::DIME

TODO

=head1 SEE ALSO

L<MIME::Tools>, L<DIME::Tools> 

=head1 COPYRIGHT

Copyright (C) 2000-2004 Paul Kulchenko. All rights reserved.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHORS

Byrne Reese (byrne@majordojo.com)

=cut