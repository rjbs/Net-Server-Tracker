use strict;
use warnings;
package TestServer;
use parent 'Net::Server::Tracker', 'Net::Server::PreFork';

my $n = 0;
sub process_request {
  my ($self) = @_;
  $self->update_tracking("handled request number " . $n++);
  return;
}

1;
