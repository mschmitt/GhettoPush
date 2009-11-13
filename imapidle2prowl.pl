#!/usr/bin/perl -w
use strict;
use diagnostics;
use IO::Socket::INET;
use IO::Socket::SSL;
use POSIX qw(setsid strftime);
use Fcntl qw(:flock);
use Mail::IMAPClient;
use MIME::EncWords qw(:all);
use FindBin qw($Bin);

# Config file syntax, see .cfg-example
my $config = read_config();
my $prowl_app = $config->{'prowl_app'};
my $prowl_key = $config->{'prowl_key'};
my $imap_host = $config->{'imap_host'};
my $imap_port = $config->{'imap_port'};
my $imap_user = $config->{'imap_user'};
my $imap_pass = $config->{'imap_pass'};
my $imap_box  = $config->{'imap_box'};
my $imap_ssl  = $config->{'imap_ssl'};
my $logfile;
if ($config->{'logfile'}){
	$logfile = glob($config->{'logfile'});
}
my $pidfile;
if ($config->{'pidfile'}){
	$pidfile = glob($config->{'pidfile'});
}
my $ssl_verify;
if ($config->{'ssl_verify'}){
	$ssl_verify = $config->{'ssl_verify'};
}
my $ssl_CApath;
if ($config->{'ssl_CApath'}){
	$ssl_CApath = $config->{'ssl_CApath'};
}

# Command line version of prowl.pl
my $prowl = "$Bin/libexec/prowl.pl";
unless (-x $prowl){
	die "$prowl not found or not executable.\n";
}

# Open Pidfile and lock it, if requested.
my $lock_fh;
if ($pidfile){
	open $lock_fh, "+>$pidfile" or die "Could not create $pidfile: $!\n";
	if (flock($lock_fh,LOCK_EX|LOCK_NB)){
		dolog('debug', "Lockfile created: $pidfile");
	}else{
		close $lock_fh;
		die "Abort: Another instance seems to be running!\n";
	}
}

# Fork unless told otherwise 
# set environment NOFORK=1 to run in foreground
# e.g.: NOFORK=1 ./imapidle2prowl.pl config.cfg
unless ($ENV{'NOFORK'}){
        fork && exit;
	dolog('info', "Backgrounding. PID is $$.");
        chdir ('/');
        open STDIN,  "/dev/null"  or die "STDIN </dev/null: $!\n";
        open STDOUT, ">/dev/null" or die "STDOUT >/dev/null: $!\n";
        open STDERR, ">/dev/null" or die "STDERR >/dev/null: $!\n";
        setsid();
}

# Write PID to pidfile, if requested.
if ($pidfile){
	print $lock_fh "$$\n";
	select($lock_fh);
	$| = 1;
	select(STDOUT);
	dolog('debug', "PID $$ written to pidfile: $pidfile");
}

# Holds connections throughout multiple cycles of the main loop.
my $imap;
my $socket;

# The main loop revolves around IDLE-recycling as mandated by RFC 2177
while(1){
	dolog('debug', 'Start main loop.');
	# See if we are connected.
	if ($imap and $imap->noop){
		dolog('debug', 'Connection checked: still alive');
	}else{
		dolog('debug', 'Connection checked: needs reconnect.');
		$imap->disconnect if ($imap);
		dolog('info', 'Connecting to IMAP.');
		# Open IMAP connection.
		my $returned = connect_imap();
		$imap   = $returned->{'imap'};
		$socket = $returned->{'socket'};
		$imap->select($imap_box) or die "Could not select folder $imap_box: $@\n";
		# Peek means, don't change any message flags.
		$imap->Peek(1);
		# Do not use Uids for transactions, so we can work with the 
		# sequence ID from IDLE EXISTS
		$imap->Uid(0);
	}
	# Synchronize message gauge from message count
	dolog('debug', 'Requesting message count from server.');
	my $gauge = $imap->message_count;
	dolog('debug', "$gauge messages on server.");
	# RFC2177 demands re-cycling the connection once in a while.
	my $interval = 25*60; # 25 minutes
	# Send session into idle state
	dolog('debug', 'About to enter IDLE state.');
	my $session = $imap->idle or die "Couldn't idle: $@\n";
	dolog('debug', 'IDLE state entered.');
	# Perl Cookbook 16.21: "Timing Out an Operation"
	$SIG{'ALRM'} = sub { die "__TIMEOUT__" };
	eval {
		alarm($interval);
		dolog('debug', "Start eval. Alarm set. Gauge at $gauge.");
		while(my $in = <$socket>){
			dolog('debug', "read from socket: $in");
			if ($in =~ /\b(\d+) EXPUNGE\b/i){
				dolog('debug', 'Expunge event from socket.'); 
				# EXPUNGE means that one message has been deleted.
				# Lower gauge by 1. Can't count mailbox contents here,
				# as session is in IDLE state.
				$gauge--;
				dolog('debug', "Expunge $1, now at $gauge messages.");
			}elsif (($in =~ /\b(\d+) EXISTS\b/i) and ($1 > $gauge)){
				# EXISTS means that one message has been created.
				# Only act if the reported ID is higher than our gauge.
				# Cancel alarm so we don't get killed while PROWLing.
				alarm(0);
				my $exists_id = $1;
				dolog('debug', "Received $exists_id EXISTS from IMAP.");
				# Bail out of the IDLE session and pick up the new message.
				$imap->done($session);
				# Retrieve and mangle new message headers.
				my $header  = $imap->parse_headers($exists_id, 'Subject', 'From');
				my $subject = decode_mimewords($header->{'Subject'}->[0], Charset => 'utf-8');
				my $from    = decode_mimewords($header->{'From'}->[0],    Charset => 'utf-8');
				dolog('info', "New message from $from, Subject: $subject");
				unless ($header and $subject and $from){
					dolog('warn', 'Empty message details. Skipping prowl, killing IMAP session.');
					$imap->disconnect;
					die "__PROWL_SKIP_EMPTY__";
				}
				# Build the command line for and execute prowl.pl
				my @prowl_cmd;
				push @prowl_cmd, $prowl;
				push @prowl_cmd, "-apikey=$prowl_key";
				push @prowl_cmd, "-application=$prowl_app";
				push @prowl_cmd, "-event=New Mail";
				push @prowl_cmd, "-notification=From $from, Subject: $subject";
				push @prowl_cmd, "-priority=0";
				system(@prowl_cmd);
				dolog('debug', (join ' ', @prowl_cmd));
				my $rc = $?>>8;
				dolog('debug', "Call to prowl.pl returned exitcode: $rc");
				die "__PROWL_FAIL__" unless (0 == $rc);
				# Exit loop and eval from here; let the main loop restart IDLE.
				die "__DONE__";
				# I don't seem to get the hang of eval. "last" doesn't work here.
				# Please, if you can, submit something else. ;-)
			}
		}
	};
	# Executed when the timeout for re-cycling the IDLE session has struck.
	if ($@ =~ /__TIMEOUT__/){
		dolog('info', "Recycling IDLE session after $interval seconds.");
		$imap->done($session);
	}elsif($@ =~ /__DONE__/){
		dolog('info', 'Done, notification sent.');
	}elsif($@ =~ /__PROWL_SKIP_EMPTY__/){
		dolog('warn', 'Skipped bogus message details.');
	}elsif($@ =~ /__PROWL_FAIL__/){
		dolog('warn', 'Call to prowl.pl failed. Better luck next time?');
	}else{
		dolog('warn', 'Socket read loop ended by itself. Disconnected from server?');
	}
}

sub connect_imap{
	# Wee need the IMAP object for IMAP transaction
	# as well as the raw socket for listening in on IDLE state.
	# This subroutine returns them both.
	my $return;
	# Instantiate Socket in plain or in SSL, depending on 
	# configuration. 
	if ($imap_ssl and ($imap_ssl =~ /^(yes|true|1)$/i)){
		dolog('info', "Starting SSL connection to $imap_host:$imap_port.");
		my %ssl_verify_opts;
		if ($ssl_verify and ($ssl_verify =~ /^(yes|true|1)$/i)){
			%ssl_verify_opts = ( 
				SSL_verify_mode => 1,
				SSL_ca_path     => $ssl_CApath
			);
		}
			
		$return->{'socket'} = IO::Socket::SSL->new(
			PeerAddr => $imap_host,
			PeerPort => $imap_port,
			Timeout  => 30,
			%ssl_verify_opts
		) or die "Can't connect to $imap_host: $@";
		my $subject_cn = $return->{'socket'}->peer_certificate('owner');
		my $issuer_cn  = $return->{'socket'}->peer_certificate('authority');
		dolog('info', "SSL subject: $subject_cn");
		dolog('info', "SSL issuer: $issuer_cn");
	}else{
		dolog('info', "Starting plaintext connection to $imap_host:$imap_port.");
		$return->{'socket'} = IO::Socket::INET->new(
			PeerAddr => $imap_host,
			PeerPort => $imap_port,
			Timeout  => 30
		) or die "Can't connect to $imap_host: $@";
	}
	$return->{'imap'} = Mail::IMAPClient->new(
		Socket     => $return->{'socket'},
		User       => $imap_user,
		Password   => $imap_pass,
		Timeout    => 60
	) or die "Can't login as $imap_user: $@\n";
	return $return;
}

# Shamelessly copied from the Perl Cookbook, 8.16.
sub read_config {
	die "Please specify configuration file!\n" unless ($ARGV[0]);
	my %cfdata;
	open my $cf_in, "<$ARGV[0]" or die "Can't read $ARGV[0]: $!\n";
	while(<$cf_in>){
		chomp;                  # no newline
		s/^\s*#.*//;            # no comments
		s/^\s+//;               # no leading white
		s/\s+$//;               # no trailing white
		next unless length;     # anything left?
		my ($var, $value) = split(/\s*=\s*/, $_, 2);
		$cfdata{$var} = $value;
	}
	close $cf_in;
	return \%cfdata;
}

sub dolog {
	my $lvl = shift;
	my $msg = shift;
	chomp $msg;
	if ($lvl eq "debug"){
		return unless ($ENV{'DEBUG'});
	}
	print STDERR "[$lvl] $msg\n";
	if ($logfile){
		open my $log_out, ">>$logfile" or die "Can't write to $logfile: $!\n";
		print $log_out strftime("%Y-%m-%d %H:%M:%S [$lvl] $msg\n",localtime(time));
		close $log_out;
	}
}
