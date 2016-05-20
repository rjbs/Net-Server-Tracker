# First, a warning!

This library relies on [a patch to
Net::Server](https://rt.cpan.org/Ticket/Display.html?id=111356) which has not
yet been integrated and released.

# Net::Server::Tracker

This package is a shim to stick between a Net::Server personality and your
server code.  It creates a tracking file for the server and every worker can
update one line in the file.  By looking at this file, you can see which
servers are active, whether some are stuck, and maybe what they're stuck on.

Sometimes this sort of thing is done by updating the contents of `$0`, but this
isn't portable (to Solaris, for example).

    package Your::Cool::Server;
    use parent 'Net::Server::Tracker', 'Net::Server::PreFork';

    sub process_request ($self) {
      # ... do some stuff
      $self->update_tracking("just did some stuff");

      # ... more stuff
      $self->update_tracking("did some more stuff, okay?");

      # ... finish up
    }

...and in your runner...

    use Your::Cool::Server;

    my $server = Your::Cool::Server->new({
      # ... your usual configuration ...
      tracker => { filename => "/var/run/cool.tracker" }
    });

    $server->run;

In `/var/run/cool.tracker` you'll find a file something like this:

    20466  2016-05-20T16:46:01 child online
    20467  2016-05-20T16:46:01 child online
    20468  2016-05-20T16:46:01 child online
    20469  2016-05-20T16:46:02 child online
    20470  2016-05-20T16:46:02 child online
    20472  2016-05-20T16:46:02 child online

(There will be lots of trailing spaces and blank lines.  Don't sweat it.)

The lines will be updated by processes as they run, and will be reused by new
servers when old servers exit after processing all the requests in their
lifetime.
