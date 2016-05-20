use 5.10.0;
use strict;
use warnings;

package Net::Server::Tracker;

use Carp ();
use IO::File;
use SUPER;

sub post_configure_hook {
  my ($self) = @_;
  my $max_servers = $self->{server}{max_servers};
  die "can't cope with 0 max_servers" unless $max_servers;

  my $line_length = $self->{server}{tracker}{line_length} // 80;
  Carp::confess("tracker line length must be at least 80")
    if $line_length < 80;

  $self->{tracker} = {
    array => [ (undef) x $max_servers ],
    slot  => {},
    line_length => $line_length,
    filename    => $self->{server}{tracker}{filename} // "tracker.status",
  };

  my $fh = IO::File->new($self->{tracker}{filename}, ">");
  die "can't open tracker: $!" unless $fh;

  my $line = " " x ($self->{tracker}{line_length} - 1)
           . "\n";

  print {$fh} $line x $max_servers;

  $fh->close;

  return $self->SUPER;
}

sub _tracker_first_empty_index {
  my ($self) = @_;
  my @tracker = @{ $self->{tracker}{array} };
  grep { defined($tracker[$_]) || return $_ } (0 .. $#tracker);
  Carp::confess("no empty slots in tracker!");
}

sub register_child {
  my ($self, $pid) = @_;
  # Almost identical to child_init_hook
  my $slot_idx = $self->_tracker_first_empty_index;
  $self->{tracker}{array}[ $slot_idx ] = $pid;
  $self->{tracker}{slot}{$pid} = $slot_idx;
  return $self->SUPER($pid);
}

sub child_init_hook {
  my ($self, @rest) = @_;
  # Almost identical to register_child
  my $slot_idx = $self->_tracker_first_empty_index;
  $self->{tracker}{array}[ $slot_idx ] = $$;
  $self->{tracker}{slot}{$$} = $slot_idx;

  my $fh = IO::File->new($self->{tracker}{filename}, "+<");
  $fh->autoflush(1);

  $self->{tracker}{fh} = $fh;

  $self->update_tracking("child online");

  return $self->SUPER(@rest);
}

sub post_accept {
  my ($self, @rest) = @_;
  $self->update_tracking("accepted request for processing");
  $self->SUPER(@rest);
}

sub post_process_request_hook {
  my ($self, @rest) = @_;
  $self->update_tracking("request processing complete");
  $self->SUPER(@rest);
}

sub child_finish_hook {
  my ($self, @rest) = @_;
  $self->update_tracking("child shutting down");
  return $self->SUPER(@rest);
}

sub update_tracking {
  my ($self, $message) = @_;
  $message //= 'ping';

  my $slot = $self->{tracker}{slot}{$$};
  unless (defined $slot) {
    warn "!!! can't update tracking for unregistered pid $$";
    return;
  }

  my $len = $self->{tracker}{line_length};
  my $fit = $len - 19;

  # So, this is probably never going to be needed, but let's not get into a
  # place where we're writing the first byte of a multibyte sequence at a line
  # boundary, and then the next byte gets overwritten, etc...
  # -- rjbs, 2016-05-20
  utf8::encode($message);

  if ($message =~ s/\v/ /g) {
    warn "!!! replaced vertical whitespace with horizontal whitespace";
  }

  if (length $message > $fit) {
    warn "!!! truncating message to fit in slot";
    $message = substr $message, 0, $fit;
  }

  $message = sprintf "%-6s %10s %-*s\n", $$, time, $fit, $message;

  my $fh = $self->{tracker}{fh};
  my $offset = $slot * $len;
  seek $fh, $offset, 0;
  print {$fh} $message;

  return;
}

sub delete_child {
  my ($self, $pid) = @_;
  my $slot = delete $self->{tracker}{slot}{$pid};

  if (defined $slot) {
    $self->{tracker}{array}[$slot] = undef;
  } else {
    warn "!!! just reaped an unregistered child, pid $pid";
  }

  return $self->SUPER($pid);
}

1;
