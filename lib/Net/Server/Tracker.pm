use strict;
use warnings;

package Net::Server::Tracker;
# ABSTRACT: shared status file for Net::Server children

use Carp ();
use IO::File qw(O_CREAT O_EXLOCK O_NONBLOCK O_RDWR);
use SUPER;

sub post_configure_hook {
  my ($self) = @_;
  my $max_servers = $self->{server}{max_servers};
  die "can't cope with 0 max_servers" unless $max_servers;

  my $line_length = defined $self->{server}{tracker}{line_length}
                  ?  $self->{server}{tracker}{line_length}
                  : 80;

  Carp::confess("tracker line length must be at least 80")
    if $line_length < 80;

  $self->{tracker} = {
    array => [ (undef) x $max_servers ],
    slot  => {},
    line_length => $line_length,
    filename    => defined $self->{server}{tracker}{filename}
                 ? $self->{server}{tracker}{filename}
                 : "tracker.status",
    time_format => defined $self->{server}{tracker}{time_format}
                 ? $self->{server}{tracker}{time_format}
                 : "local",
  };

  Carp::confess("unknown time_format: $self->{tracker}{time_format}")
    unless $self->{tracker}{time_format} =~ /\A(?:local|gm|epoch)\z/;

  my $fh = IO::File->new(
    $self->{tracker}{filename},
    O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK
  );

  die "can't open tracker with exclusive lock: $!" unless $fh;

  $self->{tracker}{lock_fh} = $fh;

  my $line = " " x ($self->{tracker}{line_length} - 1)
           . "\n";

  print {$fh} $line x $max_servers;

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

  $self->{tracker}{write_fh} = $fh;

  $self->update_tracking("child online");

  return $self->SUPER(@rest);
}

sub post_accept_hook {
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
  $message = 'ping' if not defined $message;

  my $tracker = $self->{tracker};

  my $slot = $tracker->{slot}{$$};
  unless (defined $slot) {
    $self->log(1, "!!! can't update tracking for unregistered pid $$");
    return;
  }

  my $ts;
  if ($tracker->{time_format} eq 'epoch') {
    $ts = time;
  } else {
    my @t = $tracker->{time_format} eq 'gm' ? gmtime : localtime;
    $ts = sprintf '%04u-%02u-%02uT%02u:%02u:%02u',
      $t[5] + 1900,
      $t[4] + 1,
      @t[3, 2, 1, 0];
  }

  my $reserved =  7  # pid, space
               + length($ts)
               +  1  # space
               +  1; # newline

  my $len = $self->{tracker}{line_length};
  my $fit = $len - $reserved;

  # This would be \v if we lived in a more civilized time. -- rjbs, 2016-05-23
  if ($message =~ s/[\x0A-\x0D\x85\x{2028}\x{2029}]/ /g) {
    $self->log(1, "!!! replaced vertical whitespace with horizontal");
  }

  # So, this is probably never going to be needed, but let's not get into a
  # place where we're writing the first byte of a multibyte sequence at a line
  # boundary, and then the next byte gets overwritten, etc...
  # -- rjbs, 2016-05-20
  utf8::encode($message);

  if (length $message > $fit) {
    $self->log(1, "!!! truncating message to fit in slot");
    $message = substr $message, 0, $fit;
  }

  $message = sprintf "%-6s %s %-*s\n", $$, $ts, $fit, $message;

  my $fh = $self->{tracker}{write_fh};
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
    $self->log(1, "!!! just reaped an unregistered child, pid $pid");
  }

  return $self->SUPER($pid);
}

1;
