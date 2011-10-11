package Net::SFTP::Foreign::Backend::Unix;

our $VERSION = '1.68_08';

use strict;
use warnings;

use Carp;
our @CARP_NOT = qw(Net::SFTP::Foreign);

use Fcntl qw(O_NONBLOCK F_SETFL F_GETFL);
use POSIX ();
use Net::SFTP::Foreign::Helpers qw(_tcroak _ensure_list _debug _hexdump $debug);
use Net::SFTP::Foreign::Constants qw(SSH2_FX_BAD_MESSAGE
				     SFTP_ERR_REMOTE_BAD_MESSAGE);

sub _new { shift }

sub _defaults {
   ( default_queue_size => 32 )
}

sub _init_transport_streams {
    my (undef, $sftp) = @_;
    for my $dir (qw(ssh_in ssh_out)) {
	binmode $sftp->{$dir};
	my $flags = fcntl($sftp->{$dir}, F_GETFL, 0);
	fcntl($sftp->{$dir}, F_SETFL, $flags | O_NONBLOCK);
    }
}

sub _open_dev_null {
    my $sftp = shift;
    my $dev_null;
    unless (open $dev_null, '>', "/dev/null") {
	$sftp->_conn_failed("Unable to redirect stderr to /dev/null");
	return;
    }
    $dev_null
}

sub _fileno_dup_over {
    my ($good_fn, $fh) = @_;
    if (defined $fh) {
        my @keep_open;
        my $fn = fileno $fh;
        for (1..5) {
            $fn >= $good_fn and return $fn;
            $fn = POSIX::dup($fn);
            push @keep_open, $fn;
        }
        POSIX::_exit(255);
    }
    undef;
}

sub _open4 {
    my $backend = shift;
    my $sftp = shift;
    my ($dad_in, $dad_out, $child_in, $child_out);
    unless (pipe ($dad_in, $child_out) and
            pipe ($child_in, $dad_out)) {
        $sftp->_conn_failed("Unable to created pipes: $!");
        return;
    }
    my $pid = fork;
    unless ($pid) {
        unless (defined $pid) {
            $sftp->_conn_failed("Unable to fork new process: $!");
            return;
        }
        close ($dad_in);
        close ($dad_out);

        shift; shift;
        my $child_err = shift;
        my $pty = shift;

        $pty->make_slave_controlling_terminal if defined $pty;

        my $child_err_fno = eval { no warnings; fileno($child_err  ? $child_err : *STDERR) };
        my $child_err_safe; # passed handler may be tied, so we
                            # duplicate it in order to get a plain OS
                            # handler.
        if (defined $child_err_fno and $child_err_fno >= 0) {
            open $child_err_safe, ">&=$child_err_fno" or POSIX::_exit(1);
        }
        else {
            open $child_err_safe, ">/dev/null" or POSIX::_exit(1);
        }

        my $child_in_fno       = _fileno_dup_over(0 => $child_in      );
        my $child_out_fno      = _fileno_dup_over(1 => $child_out     );
        my $child_err_safe_fno = _fileno_dup_over(2 => $child_err_safe);

        unless (($child_in_fno       == 0 or POSIX::dup2($child_in_fno,       0)) and
                ($child_out_fno      == 1 or POSIX::dup2($child_out_fno,      1)) and
                ($child_err_safe_fno == 2 or POSIX::dup2($child_err_safe_fno, 2))) {
            POSIX::_exit(1);
        }
        do { exec @_ };
        POSIX::_exit(1);
    }
    close $child_in;
    close $child_out;

    $_[0] = $dad_in;
    $_[1] = $dad_out;
    $pid;
}

sub _init_transport {
    my ($backend, $sftp, $opts) = @_;

    my $transport = delete $opts->{transport};

    if (defined $transport) {
	if (ref $transport eq 'ARRAY') {
            @{$sftp}{qw(ssh_in ssh_out pid)} = @$transport;
        }
        else {
            $sftp->{ssh_in} = $sftp->{ssh_out} = $transport;
            $sftp->{_ssh_out_is_not_dupped} = 1;
        }
    }
    else {
        my $pass = delete $opts->{passphrase};
	my $pass_is_passphrase;
        if (defined $pass) {
            $pass_is_passphrase = 1;
        }
        else {
            $pass = delete $opts->{password};
	    defined $pass and $sftp->{_password_authentication} = 1;
        }

        my $expect_log_user = delete $opts->{expect_log_user} || 0;
	my $stderr_discard = delete $opts->{stderr_discard};
	my $stderr_fh = ($stderr_discard ? undef : delete $opts->{stderr_fh});
        my $open2_cmd = delete $opts->{open2_cmd};
        my $ssh_cmd_interface = delete $opts->{ssh_cmd_interface};

	my @open2_cmd;
        if (defined $open2_cmd) {
            @open2_cmd = _ensure_list($open2_cmd);
        }
        else {
            my $host = delete $opts->{host};
            defined $host or croak "sftp target host not defined";

            my $key_path = delete $opts->{key_path};

            my $ssh_cmd = delete $opts->{ssh_cmd};
            $ssh_cmd = 'ssh' unless defined $ssh_cmd;
            @open2_cmd = _ensure_list $ssh_cmd;

            unless (defined $ssh_cmd_interface) {
                $ssh_cmd_interface = ( "@open2_cmd" =~ /\bplink\b/i ? 'plink'  :
                                       "@open2_cmd" =~ /\bsshg3\b/i ? 'tectia' :
                                                                      'ssh'    );
            }

            my $port = delete $opts->{port};
            my $user = delete $opts->{user};
	    my $ssh1 = delete $opts->{ssh1};

            my $more = delete $opts->{more};
            defined $more and !ref($more) and $more =~ /^-\w\s+\S/ and
                warnings::warnif("Net::SFTP::Foreign", "'more' argument looks like it should be split first");
            my @more = _ensure_list $more;

            my @preferred_authentications;
            if (defined $key_path) {
                push @preferred_authentications, 'publickey' if defined $key_path;
                push @open2_cmd, -i => $key_path;
            }

            if ($ssh_cmd_interface eq 'plink') {
                push @open2_cmd, -P => $port if defined $port;
                if (defined $pass and !$pass_is_passphrase) {
                    warnings::warnif("Net::SFTP::Foreign", "using insecure password authentication with plink");
                    push @open2_cmd, -pw => $pass;
                    undef $pass;
                }

            }
            elsif ($ssh_cmd_interface eq 'ssh') {
                push @open2_cmd, -p => $port if defined $port;
		if (defined $pass and !$pass_is_passphrase) {
		    push @open2_cmd, -o => 'NumberOfPasswordPrompts=1';
                    push @preferred_authentications, ('keyboard-interactive', 'password');
		}
                if (@preferred_authentications
                    and not grep { $more[$_] eq '-o' and
                                       $more[$_ + 1] =~ /^PreferredAuthentications\W/ } 0..$#more-1) {
                    push @open2_cmd, -o => 'PreferredAuthentications=' . join(',', @preferred_authentications);
                }
            }
            elsif ($ssh_cmd_interface eq 'tectia') {
            }
            else {
                die "Unsupported ssh_cmd_interface '$ssh_cmd_interface'";
            }

            push @open2_cmd, -l => $user if defined $user;
            push @open2_cmd, @more;
            push @open2_cmd, $host;
	    push @open2_cmd, ($ssh1 ? "/usr/lib/sftp-server" : -s => 'sftp');
        }

        my $redirect_stderr_to_tty = ( defined $pass and
                                       ( delete $opts->{redirect_stderr_to_tty} or $ssh_cmd_interface eq 'tectia' ) );

        $redirect_stderr_to_tty and ($stderr_discard or $stderr_fh)
            and croak "stderr_discard or stderr_fh can not be used together with password/passphrase "
                          . "authentication when Tectia client is used";

	$debug and $debug & 1 and _debug "ssh cmd: @open2_cmd\n";

	%$opts and return; # Net::SFTP::Foreign will find the
                           # unhandled options and croak

	if (${^TAINT} and Scalar::Util::tainted($ENV{PATH})) {
            _tcroak('Insecure $ENV{PATH}')
        }

	if ($stderr_discard) {
	    $stderr_fh = $backend->_open_dev_null($sftp) or return;
	}

        if (defined $pass) {

            # user has requested to use a password or a passphrase for
            # authentication we use Expect to handle that

            eval { require IO::Pty };
            $@ and croak "password authentication is not available, IO::Pty and Expect are not installed";
            eval { require Expect };
            $@ and croak "password authentication is not available, Expect is not installed";

            local ($ENV{SSH_ASKPASS}, $ENV{SSH_AUTH_SOCK}) if $pass_is_passphrase;

            my $name = $pass_is_passphrase ? 'Passphrase' : 'Password';
            my $eto = $sftp->{_timeout} ? $sftp->{_timeout} * 4 : 120;

	    my $child;
	    my $expect;
            my $pty = IO::Pty->new;
            $expect = Expect->init($pty);
            $expect->raw_pty(1);
            $expect->log_user($expect_log_user);

            $redirect_stderr_to_tty and $stderr_fh = $pty->slave;

            $child = $backend->_open4($sftp, $sftp->{ssh_in}, $sftp->{ssh_out}, $stderr_fh, $pty, @open2_cmd);
            unless (defined $child) {
                $sftp->_conn_failed("Bad ssh command", $!);
                return;
            }
            $sftp->{pid} = $child;
            $sftp->{_expect} = $expect;

            unless($expect->expect($eto, ':', '?')) {
                $sftp->_conn_failed("$name not requested as expected", $expect->error);
                return;
            }
	    my $before = $expect->before;
	    if ($before =~ /^The authenticity of host /i or
		$before =~ /^Warning: the \w+ host key for /i) {
		$sftp->_conn_failed("the authenticity of the target host can not be established, connect from the command line first");
		return;
	    }
            $expect->send("$pass\n");
	    $sftp->{_password_sent} = 1;

            unless ($expect->expect($eto, "\n")) {
                $sftp->_conn_failed("$name interchange did not complete", $expect->error);
                return;
            }
	    $expect->close_slave();
        }
        else {
	    $sftp->{pid} = $backend->_open4($sftp, $sftp->{ssh_in}, $sftp->{ssh_out}, $stderr_fh, undef, @open2_cmd);
            unless (defined $sftp->{pid}) {
                $sftp->_conn_failed("Bad ssh command", $!);
                return;
            }
        }
    }
    $backend->_init_transport_streams($sftp);
}

sub _after_init {
    my ($backend, $sftp) = @_;
    unless ($sftp->error) {
        # do not propagate signals sent from the terminal to the
        # slave SSH:
        local ($@, $!);
        eval { setpgrp($sftp->{pid}, 0) };
    }
}

sub _do_io {
    my (undef, $sftp, $timeout) = @_;

    $debug and $debug & 32 and _debug(sprintf "_do_io connected: %s", $sftp->{_connected} || 0);

    return undef unless $sftp->{_connected};

    my $fnoout = fileno $sftp->{ssh_out};
    my $fnoin = fileno $sftp->{ssh_in};
    my ($rv, $wv) = ('', '');
    vec($rv, $fnoin, 1) = 1;
    vec($wv, $fnoout, 1) = 1;

    my $bin = \$sftp->{_bin};
    my $bout = \$sftp->{_bout};

    local $SIG{PIPE} = 'IGNORE';

    my $len;
    while (1) {
        my $lbin = length $$bin;
	if (defined $len) {
            return 1 if $lbin >= $len;
	}
	elsif ($lbin >= 4) {
            $len = 4 + unpack N => $$bin;
            if ($len > 256 * 1024) {
                $sftp->_set_status(SSH2_FX_BAD_MESSAGE);
                $sftp->_set_error(SFTP_ERR_REMOTE_BAD_MESSAGE,
                                  "bad remote message received");
                return undef;
            }
            return 1 if $lbin >= $len;
        }

        my $rv1 = $rv;
        my $wv1 = length($$bout) ? $wv : '';

        $debug and $debug & 32 and _debug("_do_io select(-,-,-, ". (defined $timeout ? $timeout : 'undef') .")");

        my $n = select($rv1, $wv1, undef, $timeout);
        if ($n > 0) {
            if (vec($wv1, $fnoout, 1)) {
                my $written = syswrite($sftp->{ssh_out}, $$bout, 64 * 1024);
                if ($debug and $debug & 32) {
		    _debug (sprintf "_do_io write queue: %d, syswrite: %s, max: %d, \$!: %s",
			    length $$bout,
			    (defined $written ? $written : 'undef'),
			    64 * 1024, $!);
		    $debug & 2048 and $written and _hexdump(substr($$bout, 0, $written));
		}
                if ($written) {
                    substr($$bout, 0, $written, '');
                }
                elsif ($! != Errno::EAGAIN() and $! != Errno::EINTR()) {
                    $sftp->_conn_lost;
                    return undef;
                }
            }
            if (vec($rv1, $fnoin, 1)) {
                my $read = sysread($sftp->{ssh_in}, $$bin, 64 * 1024, length($$bin));
                if ($debug and $debug & 32) {
		    _debug (sprintf "_do_io read sysread: %s, total read: %d, \$!: %s",
			    (defined $read ? $read : 'undef'),
			    length $$bin,
			    $!);
		    $debug & 1024 and $read and _hexdump(substr($$bin, -$read));
		}
                if (!$read and $! != Errno::EAGAIN() and $! != Errno::EINTR()) {
                    $sftp->_conn_lost;
                    return undef;
                }
            }
        }
        else {
            $debug and $debug & 32 and _debug "_do_io select failed: $!";
            next if ($n < 0 and ($! == Errno::EINTR() or $! == Errno::EAGAIN()));
            return undef;
        }
    }
}

1;
