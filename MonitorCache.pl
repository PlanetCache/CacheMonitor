#!/usr/bin/perl -W
#########################################################
# MonitorCache.pl					#
# Joseph Harnish					#
# 12/15/2011						#
# Does checks on different parts of the Cache instance	#
#########################################################
#  MonitorCache.pl  [-d] [-h] [-noSNMP]					#
#		-d		Enables Debug							#
#		-h 		Prints this message						#
#		-noSNMP Disables SNMP traps from being sent.	#
#########################################################
use strict;
use Sys::Hostname;
use Data::Dumper;
use LWP::UserAgent;
use HTTP::Request;
use YAML qw( LoadFile );
use File::Copy;
#########################################################
# Configuration											#
#########################################################
my $configfile = "./MonitorCache.conf";
my $config = LoadFile( $configfile );
my $debug = $config->{'debug'};
my $enable_SNMP = $config->{'enable_SNMP'};
my $enable_openviewweb = $config->{'enable_openviewweb'};
my $tempmsg = $config->{'workingdir'} . '/MonitorCacheMsg.txt';

#########################################################
# End Configuration										#
#########################################################
my $hostname = hostname;
my $post_url = "";
my $VERSION = 0.9;
my %Check_Hash = ();
my $OS = `uname`;
chomp($OS);
#########################################################
# Check if another instance is running that isn't me	#
#########################################################
my $pid = $$;
my $program_name = $0;
foreach (@ARGV){
	$debug = 1 if($_ eq '-d');
	Print_Usage($program_name) if($_ eq '-h');
	$enable_openviewweb = 0 if($_ eq '-noOPV');
}
my $pslist = `ps -ef |grep $program_name | grep -v grep | /usr/bin/awk '{print \$1}' | grep -v $pid`;
my @pslist_arr = split(/\n/, $pslist);
if($#pslist_arr > 0){
	if($debug){
		print "Too many copies of this script running:\n";
		foreach(@pslist_arr){
			print "$_\n";
		}
	}
	ALERT("Too Many Monitoring Processes Running");
}

##########################################################
# Check OS Level Things									#
#########################################################

#########################################################
# Check disk space										#
#########################################################
print "Checking Disk Space\n" if ($debug);
#my $filesystems_used = `/usr/bin/df -k | grep -v proc | grep -v Filesystem | /usr/bin/awk '{print $7 " " $4}' | sed '/%/s// /g' 2>&1`;
my $filesystems_used = '';
if($OS eq 'AIX'){
	$filesystems_used = `/usr/bin/df -k | grep -v proc | grep -v Filesystem`;
} elsif ($OS eq 'Linux'){
	$filesystems_used = `/bin/df -P | grep -v proc | grep -v Filesystem`;
} else {
	print "OS $OS is not supported yet\n";
}
my @temp_filesystem = split(/\n/, $filesystems_used);
foreach(@temp_filesystem){
	my @array = split(/\s+/, $_);
	$array[3] =~ s/\%//;
	my $filesystem = '';
	my $used_percent = '';
	if($OS eq 'AIX'){
	  $filesystem = $array[6];
	  $used_percent = $array[3];
	} elsif($OS eq 'Linux'){
	  $filesystem = $array[0];
	  $used_percent = $array[4];
	  chop($used_percent); #remove the % symbol
	} else {
	  print "$OS is not supported\n";
	}
	$Check_Hash{'filesystem'}{$filesystem}{'percent_used'} = $used_percent; 
	$post_url .= "$hostname\^filesystem\^$filesystem\^$used_percent\|";
	if($used_percent >= $config->{'filesystem_size_max_percent'}){
		$Check_Hash{'alert'}{'filesystem'} .= "$filesystem is $used_percent\% full\n";
		$Check_Hash{'filesystem'}{$filesystem}{'Alert'} = 1;
	}
}
print "Finished Checking Disk Space\n" if ($debug);

#########################################################
# Check memory And CPU									#
#########################################################
print "Checking CPU and Memory\n" if($debug);
my $vmstat = `vmstat 1 1| tail -n 1`;
my @vmstat_out = split(/\s+/, $vmstat);  #need to skip one bc the leading space counts as vmstat[0]

my $pages_i_o = $vmstat_out[6] + $vmstat_out[7];
$post_url .= "$hostname\^memory\^paged\^$pages_i_o\|";
#$Check_Hash{'alert'}{'pagedmemory'} = "System is Paging/Swapping\n" if ($pages_i_o > 0);
# Check Idle CPU
$Check_Hash{'cpu'}{'idle'} = $vmstat_out[16];
$post_url .= "$hostname\^cpu\^idle\^$vmstat_out[16]\|";
#$Check_Hash{'alert'}{'cpu'} = "CPU Usage is more that 70 percent\n" if($Check_Hash{'cpu'}{'idle'} < 30);
print "Finished Checking CPU and Memory\n" if($debug);

#########################################################
# Check CACHE                                           #
#########################################################
my @cache_instances = Get_Cache_Instances();
print "Checking Instance State\n" if($debug);
foreach (@cache_instances){
	next if(IS_IN_LIST($_, @{$config->{'instaces_to_ignore'}}));
	$Check_Hash{'cache'}{$_}{'Status'} = Get_Cache_Instance_Status($_);
	print "Checking Instance State of $_\n" if($debug);
	if($Check_Hash{'cache'}{$_}{'Status'} ne 'running'){
		$Check_Hash{'alert'}{'cache'} .= "$_ is $Check_Hash{'cache'}{$_}{'Status'}";
		print "$_ is down\n" if($debug);
	} else {
		print "$_ is up\n" if($debug);
		#########################################################
		# Cache is up											#
		#########################################################
		# Check Journaling										#
		#########################################################
		# Check this every day, 1/2 or so.
		print "Checking Journaling in $_\n" if($debug);
		$Check_Hash{'cache'}{$_}{'Journal'} = Get_Journal_Status($_);
		$Check_Hash{'alert'}{'journal'} .= "Journaling is off in $_\n" if($Check_Hash{'cache'}{$_}{'Journal'} ne 'enabled');
		print "Journaling is $Check_Hash{'cache'}{$_}{'Journal'}\n" if($debug);
		#########################################################
		# Check LockTable										#
		#########################################################
		print "Checking Locktable in $_\n" if($debug);
		$Check_Hash{'cache'}{$_}{'Locktable'} = Get_Locktable_Status($_);
		$Check_Hash{'alert'}{'locktable'} .= "Locktable is $Check_Hash{'cache'}{$_}{'Locktable'} percent\n" if($Check_Hash{'cache'}{$_}{'Locktable'} > $config->{'max_lock_table_size'});
		$post_url .= "$_\^locktable\^percent\^$Check_Hash{'cache'}{$_}{'Locktable'}\|";
		#########################################################
		# Check Cache licenses									#
		#########################################################
		# ShowSummary^%LICENSE 
		# do $SYSTEM.License.ShowCounts()
		#print "Check Licenses in $_\n" if($debug);
		#$Check_Hash{'cache'}{$_}{'Licenses'} = Get_License_Status($_);
		#need to test on something with licenses setup.
		#########################################################
		# Check DB Sizes										#
		#########################################################
		print "Checking DB Sizes for $_\n" if($debug); 
		my $dbsize_hashref = Get_Database_Sizes($_);
		foreach  my $dbfile (keys %$dbsize_hashref){
			$Check_Hash{'cache'}{$_}{'dbsize'}{$dbfile}{'MBSize'} = $dbsize_hashref->{$dbfile}{'MBSize'};
			print "  $dbfile => $Check_Hash{'cache'}{$_}{'dbsize'}{$dbfile}{'MBSize'}\n" if($debug);
			$post_url .= "$_\^dbsize\^$dbfile\^$Check_Hash{'cache'}{$_}{'dbsize'}{$dbfile}{'MBSize'}\|";
			$post_url .= "$_\^datasize\^$dbfile\^$dbsize_hashref->{$dbfile}{'MBDataSize'}\|";
			if($dbsize_hashref->{$dbfile}{'Max'} ne 'Unlimited') {
				if (($dbsize_hashref->{$dbfile}{'MBSize'} / $dbsize_hashref->{$dbfile}{'MBMax'}) > 90){
				 $Check_Hash{'alert'}{'dbsize'} .= "$dbfile " . $dbsize_hashref->{$dbfile}{'MBSize'} / $dbsize_hashref->{$dbfile}{'MBMax'} . "\n";
				}
			}
		}
		#########################################################
		# Check log entries										#
		#########################################################
		print "Checking cconsole.log file" if($debug);
		my @bad_cconsole_lines = Check_cconsole($_);
		if($#bad_cconsole_lines >= 0){
			print "\n" if($debug);
			foreach my $line (@bad_cconsole_lines){
				$Check_Hash{'alert'}{'cconsole'} .= "$line\n";
				print "$line\n" if($debug);
			}
		} else {
			print "..... Clean\n" if($debug);
		}
		
	}
}


Send_Alerts(\%Check_Hash) if(defined($Check_Hash{'alert'}));
Send_Host_Stats($post_url);

exit;

#################################################
# scans a list to verify if something is in it	#
#################################################
sub IS_IN_LIST{
        my $lookfor = shift;
        my @list = @_;
        foreach (@list){
                return 1 if($lookfor eq $_);
        }
        return 0;
}

#################################################
# Checks the locktable information				#
#    Requires an Instance passed to it			#
#################################################
sub Get_Locktable_Status {
	my $instance = shift || return 1;
	my $val = `ccontrol stat $instance -a0 -u1`;
	my $size = 1;
	my $num = 0;
	foreach (split(/\n/, $val)){
		$size = $1 if ($_ =~ /System's Total Lock Table Size : +(\d+)/);
        $num  = $1 if ($_ =~ /Total lock entries : +(\d+)/);
	}
	print "Locktable size = $size\n" if($debug);
	print "Locks used = $num\n" if($debug);
	$val = `csession $instance -U %SYS <<done
$config->{'cache_user'}
$config->{'cache_password'}
w ##class(SYS.Lock).GetLockSpaceInfo()
h	
done`;
	my $my_line = '';
	foreach (split(/\n/, $val)){
		$my_line =$_ if $_ =~ /\,/;
	}
	my @parts = split(/\,/, $my_line);
	return 1 if(!defined($parts[0]) || $parts[0] <= 0 || ($parts[0] =~ m/\D/));
	print "Total Locktable size => $parts[0]\n" if($debug);
	print "Avail Locktable space => $parts[1]\n" if($debug);
	print "Used  Locktable space => $parts[2]\n" if($debug);
	my $temp = 	int(($parts[2]/$parts[0]) * 100);
	print "Percent of locktable used: $temp \n" if($debug);
	return $temp;
	#	return int(($parts[2]/$parts[0]) * 100);

}

#################################################
# Checks the license information					#
#   IN: Requires an Instance passed to it		#
#   OUT: returns a hash	ref						#
#################################################
sub Get_License_Status {
	my $instance = shift;
	my $val = `csession $instance -U %SYS << done
$config->{'cache_user'}
$config->{'cache_password'}

d \$SYSTEM.License.ShowCounts()
h
done`;	
	my $not_connected_string = "Not connected to License Server";
    return if($val =~ m/$not_connected_string/);
	# %SYS>d ShowSummary^%LICENSE

	# License Server summary view of active key.

		 # Distributed license use:
	# Current License Units Used =     184
	# Maximum License Units Used =     436
	# License Units     Enforced =    1480
	# License Units   Authorized =    1000

		 # Local license use:
	# Current Connections =     60  Maximum Connections =     74
	# Current Users       =      4  Maximum Users       =      5
	my @temp_array = split(/\n/, $val);
	my %temp_hash = ();
	foreach (@temp_array){
		if($_ =~ m/^Current Connections/){
			my @temp_array2 = split(/\s+/, $_);
			$temp_hash{'current_connections'} = $temp_array2[3];
			$temp_hash{'maximum_connections'} = $temp_array2[7];
		} elsif ($_ =~ m/^Current Users/){
			my @temp_array2 = split(/\s+/, $_);
			$temp_hash{'current_users'} = $temp_array2[3];
			$temp_hash{'maximum_users'} = $temp_array2[7];
		} elsif ($_ =~ m/^Current License/){
			my @temp_array2 = split(/\=/, $_);
			$temp_hash{'current_license_used'} = $temp_array2[1];
		} elsif ($_ =~ m/^Maximum License/){
			my @temp_array2 = split(/\=/, $_);
			$temp_hash{'maximum_license_used'} = $temp_array2[1];
		} elsif ($_ =~ m/Enforced/){
			my @temp_array2 = split(/\=/, $_);
			$temp_hash{'license_enforced'} = $temp_array2[1];
		} elsif ($_ =~ m/Authorized/){
			my @temp_array2 = split(/\=/, $_);
			$temp_hash{'license_authorized'} = $temp_array2[1];
		}	
	
	}
	return \%temp_hash;
}

#################################################
# Checks the Journal Status						#
#   IN: Requires an Instance passed to it		#
#   OUT: returns a string with the status		#
#################################################
sub Get_Journal_Status {
	my $instance = shift;
	my $val = `ccontrol stat $instance -a0 -j4`;
	my @lines = split(/\n/, $val);
	my @status_line = split(/\,/, $lines[12]);
	foreach (@status_line) {
		$_ =~ s/\s+//g;
		my ($return, $bool) = split(/\:/, $_);
		return $return if($bool);
	}
}

#################################################
# Checks the Seizes Status						#
#   IN: Requires an Instance passed to it		#
#   OUT: returns nothing yet.					#
#################################################
#  Not Implmeneted yet.							#
#################################################
sub Get_Seizes {
	my $instance = shift;
	my $val = `ccontrol stat $instance -a0 -D10`;
	
}

#################################################
# Checks the Instance Status					#
#   IN:  Requires an Instance passed to it		#
#   OUT:  returns a string with the status		#
#################################################
sub Get_Cache_Instance_Status {
	my $instance = shift;
	my $status_string = `ccontrol list $instance | grep status`;
	my @parts = split(/\s+/, $status_string);
	my $return_string = $parts[2];
	$return_string =~ s/\,//;
	$return_string .= " $parts[3]" if(($return_string ne 'running') && ($return_string ne 'down'));
	return $return_string;
}
#################################################
# Creates a list of Instances					#
#   IN:  Nothing								#
#   OUT:  returns an array of instances			#
#################################################
sub Get_Cache_Instances {

	my $list = `ccontrol list | grep Configuration`;
	my @list_1 = split(/\n/, $list);
	my @return_list = ();
	foreach(@list_1){
		if($_ =~ m/\'(.*)\'/){
			push(@return_list, $1);
		}
	}	
	return @return_list;

}

#################################################
# Sends an immediate message to the admin(s) 	#
#  then dies.									#
#   IN: message									#
#################################################
sub ALERT {
   # Fatal Alert.  Die after wards.
   my $message = shift;
   Send_Message($message, $message);
   # "$message";
   exit;
}

#################################################
# Sends a full message							#
#   IN: message									#
#   OUT: Status of the sends					#
#################################################
sub Send_Alerts {
	my $hash = shift;
	my $message = "";
	
	foreach (keys %{$hash->{'alert'}}) {
			$message .= "$_\n $hash->{'alert'}{$_}\n\n";
	}
	return Send_Message("Problem report for $hostname", $message);
}

#################################################
# Actually sends the message.					#
#   IN: Title, Message							#
#   OUT: sending output							#
#################################################
sub Send_Message {
	my $title = shift;
	my $message = shift;
	my $returns = '';
	open(MSGFILE, ">$tempmsg");
	print MSGFILE $message;
	close MSGFILE;
	foreach (@{$config->{'admins'}}){
		$returns .= `mailx -s \"$title\" $_ < $tempmsg`;
		print "$title\n $message\n" if($debug);
	}
	my $op_group = $debug == 1 ? "OpC" : "Ops";
	# Add Operator Notes
	$message .= "\n Please create a Priority 3 ticket in the Interface Engine Integration queue\n";
	if($enable_openviewweb){
		my $opv_message = qq{
<soap:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
<soap:Body>
<SendMessage xmlns="http://ovinternals.com/OVMessage/ovmessage">
<strApp>Ensemble</strApp>
<strObject>$hostname</strObject>
<nSev>Warning</nSev>
<strGrp>$op_group</strGrp>
<strSvcID></strSvcID>
<strNode>$hostname</strNode>
<strText>$message</strText>
</SendMessage>
</soap:Body>
</soap:Envelope>		
};

		my $userAgent = LWP::UserAgent->new();
		my $request = HTTP::Request->new(POST => $config->{'openviewweb_Server'} . '/OVMessage/ovmsg.asmx');
		
		$request->content($opv_message);
		$request->content_type("text/xml; charset=utf-8");
		print "\nSending OpenView message via SOAP\n" if($debug);
		my $response = $userAgent->request($request);
		print "http response was: \n" if($debug);
		print Dumper($response) if($debug);
		$enable_SNMP = 1 if($response->{'_msg'} ne 'OK');
	}
	if($enable_SNMP){
		print "Failing back to SNMP\n" if($debug);
		if(length($message) > 255){
			$message = substr($message, 0, 254);
		}
		$returns .= `/usr/sbin/snmptrap -h $config->{'SNMP_Server'} -c Public -m $message`;
	}
	return $returns;
}

#################################################
# Sends data for trending						#
#  Sends a string to a webservice for Dan		#
#################################################
sub Send_Host_Stats {
	####### Need to Complete
	my $message = shift;
	chop($message);
	my $stats_message = "\&pInput=$message";
		
	my $userAgent = LWP::UserAgent->new();
	my $url = $config->{'stats_web_service'} . $stats_message;
	my $request = HTTP::Request->new(GET => $url);

	$request->content_type("text/xml; charset=utf-8");
	my $response = $userAgent->request($request);
	#print Dumper($response) if($debug);

	return 1;
}

#################################################
# Usage											#
#################################################
sub Print_Usage {
	my $program_name = shift;
print <<EODUMP;
	$program_name [-d] [-h] [-noOPV]
		-d		Enables Debug. Sends message to OpC (not the NOC) 
					unless Openview SOAP is down.
		-h 		Prints this message
		-noOPV	Does not generate any openview message.

EODUMP

exit;
}

#########################################################
# Gets Database sizes and returns a HASH REF            #
#########################################################
sub Get_Database_Sizes {
         my $instance = shift;
        my %return_hash = ();
        my $val = `csession $instance -U %SYS << done
$config->{'cache_user'}
$config->{'cache_password'}

d ^DATABASE
8
*



h
done`;

        my @lines = split(/\n/, $val);
        my $In_Output = 0;
        my $begin_string = "                           Cache Database Free Space";
        my $counter = 0;
        foreach my $line (@lines){
                chomp($line);
                $In_Output = 1 if($line eq $begin_string);
                next if (! $In_Output);
                $counter++;
                next if($counter <= 3);
                next if($line eq '==');
                if($line eq ''){
                        $In_Output = 0;
                        next;
                }
                my @row = split(/\s+/, $line);
                $return_hash{$row[0]}{'Max'} = $row[1];
		if(length($row[2]) > 8){
			print "Moving row 4 to row 5: $row[4]\n" if( $debug);
			$row[5] = $row[4];
			print "Moving row 3 to row 4: $row[3]\n" if($debug);
			$row[4] = $row[3];
			print "Row 2 was: $row[2]\n" if($debug);
			$row[3] = substr $row[2], 8;
			print "Row 3 is now $row[3]\n" if($debug);
			$row[2] = substr $row[2], 0, 8;
			print "Row 2 is now $row[2]\n" if($debug);
		}
                $return_hash{$row[0]}{'Size'} = $row[2];
                $return_hash{$row[0]}{'Available'} = $row[3];
                $return_hash{$row[0]}{'pctfree'} = $row[4];
                $return_hash{$row[0]}{'dskfree'} = $row[5];
                $return_hash{$row[0]}{'Size'} =~ /(.*)(\wB)/;
                $return_hash{$row[0]}{'MBSize'} = $1;
                $return_hash{$row[0]}{'MBSize'} = ($1 * 1024) if($2 eq 'GB');
		$return_hash{$row[0]}{'Available'} =~ /(.*)(\wB)/;
                $return_hash{$row[0]}{'MBAvailable'} = $1;
                $return_hash{$row[0]}{'MBAvailable'} = ($1 * 1024) if($2 eq 'GB');
		$return_hash{$row[0]}{'MBDataSize'} = $return_hash{$row[0]}{'MBSize'} - $return_hash{$row[0]}{'MBAvailable'};
		if($return_hash{$row[0]}{'Max'} eq 'Unlimited'){
			$return_hash{$row[0]}{'MBMax'} = 999999999;
		} else {
			$return_hash{$row[0]}{'Max'} =~ /(.*)(\w\w)/;
			if($2 eq 'GB'){
				$return_hash{$row[0]}{'MBMax'} = ($1 * 1024);
			} else {
				$return_hash{$row[0]}{'MBMax'} = $1;
			}
		}
        }
        return \%return_hash;
}
#################################################
# Check cconsole.log							#
# This copies the cconsole.log to a tmpdir to 	#
# diff and check for new bad errors				#
#################################################
sub Check_cconsole {
	my $instance = shift;
	my $parseline = `ccontrol list $instance | grep directory`;
	chomp($parseline);
	my @parsed = split(/\:/, $parseline);
	$parsed[1] =~ s/\s+//g;
	my $path = $parsed[1] . '/mgr/cconsole.log';
	my $dir = $config->{'workingdir'} . $instance;
	if(! -d $dir){
		my $junk = `mkdir -p $dir`;
		$junk = `touch $dir/cconsole.log`;
	}
	copy("$dir/cconsole.log", "$dir/cconsole.log.orig") || die "Can't copy file";
	copy($path, "$dir/cconsole.log") || die "Can't copy file1";
	my $diff = `diff $dir/cconsole.log.orig $dir/cconsole.log`;
	my @sev2s = ();
	my @diff_rows = split(/\n/, $diff);
	foreach my $row (@diff_rows){
		my @cols = split(/\s+/, $row);
		next if($#cols < 3);
		push @sev2s, $row if(($cols[3] =~ m/\d/) &&($cols[3] == 2));
		#add more checks here for bad stuff.
	}
	return @sev2s;
}

