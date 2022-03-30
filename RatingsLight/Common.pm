#
# Ratings Light
#
# (c) 2020-2022 AF-1
#
# GPLv3 license
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
#

package Plugins::RatingsLight::Common;

use strict;
use warnings;
use utf8;

use Data::Dumper;
use Slim::Utils::Log;
use Slim::Schema;
use Slim::Utils::DateTime;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Text;
use File::Basename;
use File::Copy qw(move);
use File::Spec::Functions qw(:ALL);
use File::stat;
use FindBin qw($Bin);
use POSIX qw(strftime);
use Time::HiRes qw(time);
use URI::Escape qw(uri_escape_utf8 uri_unescape);
use Path::Class;

use base 'Exporter';
our %EXPORT_TAGS = (
	all => [qw( getCurrentDBH commit rollback createBackup cleanupBackups importRatingsFromCommentTags isTimeOrEmpty getMusicDirs parse_duration pathForItem)],
);
our @EXPORT_OK = ( @{ $EXPORT_TAGS{all} } );

my $log = logger('plugin.ratingslight');
my $prefs = preferences('plugin.ratingslight');
my $serverPrefs = preferences('server');

sub createBackup {
	my $status_creatingbackup = $prefs->get('status_creatingbackup');
	if ($status_creatingbackup == 1) {
		$log->warn('A backup is already in progress, please wait for the previous backup to finish');
		return;
	}
	$prefs->set('status_creatingbackup', 1);

	my $rlparentfolderpath = $prefs->get('rlparentfolderpath');
	my $backupDir = $rlparentfolderpath.'/RatingsLight';
	mkdir($backupDir, 0755) unless (-d $backupDir);
	chdir($backupDir) or $backupDir = $rlparentfolderpath;

	my ($sql, $sth) = undef;
	my $dbh = getCurrentDBH();
	my ($trackURL, $trackRating, $trackRemote, $trackExtid);
	my $started = time();
	my $backuptimestamp = strftime "%Y-%m-%d %H:%M:%S", localtime time;
	my $filename_timestamp = strftime "%Y%m%d-%H%M", localtime time;

	$sql = "select tracks_persistent.url, tracks_persistent.rating, tracks.remote, tracks.extid from tracks_persistent join tracks on tracks.urlmd5 = tracks_persistent.urlmd5 where tracks_persistent.rating > 0";
	$sth = $dbh->prepare($sql);
	$sth->execute();

	$sth->bind_col(1,\$trackURL);
	$sth->bind_col(2,\$trackRating);
	$sth->bind_col(3,\$trackRemote);
	$sth->bind_col(4,\$trackExtid);

	my @ratedTracks = ();
	while ($sth->fetch()) {
		push (@ratedTracks, {'url' => $trackURL, 'rating' => $trackRating, 'remote' => $trackRemote, 'extid' => $trackExtid});
	}
	$sth->finish();

	if (@ratedTracks) {
		my $PLfilename = 'RL_Backup_'.$filename_timestamp.'.xml';

		my $filename = catfile($backupDir,$PLfilename);
		my $output = FileHandle->new($filename, '>:utf8') or do {
			$log->warn('could not open '.$filename.' for writing.');
			$prefs->set('status_creatingbackup', 0);
			return;
		};
		my $trackcount = scalar(@ratedTracks);
		my $ignoredtracks = 0;
		$log->debug('Found '.$trackcount.($trackcount == 1 ? ' rated track' : ' rated tracks').' in the LMS persistent database');

		print $output "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n";
		print $output "<!-- Backup of Rating Values -->\n";
		print $output "<!-- ".$backuptimestamp." -->\n";
		print $output "<RatingsLight>\n";
		for my $ratedTrack (@ratedTracks) {
			my $BACKUPtrackURL = $ratedTrack->{'url'};
			if (($ratedTrack->{'remote'} == 1) && (!defined($ratedTrack->{'extid'}))) {
				$log->warn('Warning: ignoring this track. Track is remote but not part of online library: '.$BACKUPtrackURL);
				$trackcount--;
				$ignoredtracks++;
				next;
			}
			if (($ratedTrack->{'remote'} != 1) && (!defined(Slim::Schema->resultset('Track')->objectForUrl($BACKUPtrackURL)))) {
				$log->warn('Warning: ignoring this track. Track dead or moved??? Track URL: '.$BACKUPtrackURL);
				$trackcount--;
				$ignoredtracks++;
				next;
			}

			my $rating100ScaleValue = $ratedTrack->{'rating'};
			my $remote = $ratedTrack->{'remote'};
			my $BACKUPrelFilePath = getRelFilePath($BACKUPtrackURL);
			$BACKUPtrackURL = uri_escape_utf8($BACKUPtrackURL);
			$BACKUPrelFilePath = uri_escape_utf8($BACKUPrelFilePath);
			print $output "\t<track>\n\t\t<url>".$BACKUPtrackURL."</url>\n\t\t<relurl>".$BACKUPrelFilePath."</relurl>\n\t\t<rating>".$rating100ScaleValue."</rating>\n\t\t<remote>".$remote."</remote>\n\t</track>\n";
		}
		print $output "</RatingsLight>\n";

		if ($ignoredtracks > 0) {
			print $output "<!-- WARNING: ".$ignoredtracks.($ignoredtracks == 1 ? " track was" : " tracks were")." ignored. Check server.log for more information. -->\n";
		}
		print $output "<!-- This backup contains ".$trackcount.($trackcount == 1 ? " rated track" : " rated tracks")." -->\n";
		close $output;
		my $ended = time() - $started;
		$log->debug('Backup completed after '.$ended.' seconds.');

		cleanupBackups();
	} else {
		$log->debug('Info: no rated tracks in database');
	}
	$prefs->set('status_creatingbackup', 0);
}

sub cleanupBackups {
	my $autodeletebackups = $prefs->get('autodeletebackups');
	my $backupFilesMin = $prefs->get('backupfilesmin');
	if (defined $autodeletebackups) {
		my $rlparentfolderpath = $prefs->get('rlparentfolderpath');
		my $backupDir = $rlparentfolderpath.'/RatingsLight';
		return unless (-d $backupDir);
		my $backupsdaystokeep = $prefs->get('backupsdaystokeep');
		my $maxkeeptime = $backupsdaystokeep * 24 * 60 * 60; # in seconds
		my @files;
		opendir(my $DH, $backupDir) or die "Error opening $backupDir: $!";
		@files = grep(/^RL_Backup_.*$/, readdir($DH));
		closedir($DH);
		$log->debug('number of backup files found: '.scalar(@files));
		my $mtime;
		my $etime = int(time());
		my $n = 0;
		if (scalar(@files) > $backupFilesMin) {
			foreach my $file (@files) {
				$mtime = stat($file)->mtime;
				if (($etime - $mtime) > $maxkeeptime) {
					unlink($file) or die "Can\'t delete $file: $!";
					$n++;
					last if ((scalar(@files) - $n) <= $backupFilesMin);
				}
			}
		} else {
			$log->debug('Not deleting any backups. Number of backup files to keep ('.$backupFilesMin.') '.((scalar(@files) - $n) == $backupFilesMin ? '=' : '>').' backup files found ('.scalar(@files).').');
		}
		$log->debug('Deleted '.$n.($n == 1 ? ' backup. ' : ' backups. ').(scalar(@files) - $n).((scalar(@files) - $n) == 1 ? " backup" : " backups")." remaining.");
	}
}

sub importRatingsFromCommentTags {
	$log->debug('starting ratings import from comment tags');
	my $class = shift;
	my $status_importingfromcommenttags = $prefs->get('status_importingfromcommenttags');
	if ($status_importingfromcommenttags == 1) {
		$log->warn('Import is already in progress, please wait for the previous import to finish');
		return;
	}
	$prefs->set('status_importingfromcommenttags', 1);
	my $started = time();

	my $rating_keyword_prefix = $prefs->get('rating_keyword_prefix');
	my $rating_keyword_suffix = $prefs->get('rating_keyword_suffix');
	my $plimportct_dontunrate = $prefs->get('plimportct_dontunrate');

	my $dbh = getCurrentDBH();
	if ((!defined $rating_keyword_prefix || $rating_keyword_prefix eq '') && (!defined $rating_keyword_suffix || $rating_keyword_suffix eq '')) {
		$log->warn('Error: no rating keywords found.');
		$prefs->set('status_importingfromcommenttags', 0);
		return
	} else {
		my $sqlunrate = "UPDATE tracks_persistent
			SET rating = NULL
			WHERE (tracks_persistent.rating > 0
				AND tracks_persistent.urlmd5 IN (
					SELECT tracks.urlmd5
					FROM tracks
					LEFT JOIN comments ON comments.track = tracks.id
					WHERE (comments.value NOT LIKE ? OR comments.value IS NULL))
				);";

		my $sqlrate = "UPDATE tracks_persistent
			SET rating = ?
			WHERE tracks_persistent.urlmd5 IN (
				SELECT tracks.urlmd5
					FROM tracks
				JOIN comments ON comments.track = tracks.id
					WHERE comments.value LIKE ?
			);";

		if (!defined $plimportct_dontunrate) {
			# unrate previously rated tracks in LMS if comment tag does no longer contain keyword(s)
			my $ratingkeyword_unrate = "%%".$rating_keyword_prefix."_".$rating_keyword_suffix."%%";

			my $sth = $dbh->prepare($sqlunrate);
			eval {
				$sth->bind_param(1, $ratingkeyword_unrate);
				$sth->execute();
				commit($dbh);
			};
			if ($@) {
				$log->warn("Database error: $DBI::errstr");
				eval {
					rollback($dbh);
				};
			}
			$sth->finish();
		}

		# rate tracks according to comment tag keyword
		my $rating = 1;

		until ($rating > 5) {
			my $rating100scalevalue = ($rating * 20);
			my $ratingkeyword = "%%".$rating_keyword_prefix.$rating.$rating_keyword_suffix."%%";
			my $sth = $dbh->prepare($sqlrate);
			eval {
				$sth->bind_param(1, $rating100scalevalue);
				$sth->bind_param(2, $ratingkeyword);
				$sth->execute();
				commit($dbh);
			};
			if ($@) {
				$log->warn("Database error: $DBI::errstr");
				eval {
					rollback($dbh);
				};
			}
			$rating++;
			$sth->finish();
		}
	}

	my $ended = time() - $started;

	$log->debug('Import completed after '.$ended.' seconds.');
	$prefs->set('status_importingfromcommenttags', 0);
}


sub getRelFilePath {
	$log->debug('Getting relative file url/path.');
	my $fullTrackURL = shift;
	my $relFilePath;
	my $lmsmusicdirs = getMusicDirs();
	$log->debug('Valid LMS music dirs = '.Dumper($lmsmusicdirs));

	foreach (@{$lmsmusicdirs}) {
		my $dirSep = File::Spec->canonpath("/");
		my $mediaDirPath = $_.$dirSep;
		my $fullTrackPath = Slim::Utils::Misc::pathFromFileURL($fullTrackURL);
		my $match = checkInFolder($fullTrackPath, $mediaDirPath);

		$log->debug("Full file path \"$fullTrackPath\" is".($match == 1 ? "" : " NOT")." part of media dir \"".$mediaDirPath."\"");
		if ($match == 1) {
			$relFilePath = file($fullTrackPath)->relative($_);
			$relFilePath = Slim::Utils::Misc::fileURLFromPath($relFilePath);
			$relFilePath =~ s/^(file:)?\/+//isg;
			$log->debug('Saving RELATIVE file path: '.$relFilePath);
			last;
		}
	}
	if (!$relFilePath) {
		$log->debug("Couldn't get relative file path for \"$fullTrackURL\".");
	}
	return $relFilePath;
}

sub checkInFolder {
	my $path = shift || return;
	my $checkdir = shift;

	$path = Slim::Utils::Misc::fixPath($path) || return 0;
	$path = Slim::Utils::Misc::pathFromFileURL($path) || return 0;
	$log->debug('path = '.$path.' -- checkdir = '.$checkdir);

	if ($checkdir && $path =~ /^\Q$checkdir\E/) {
		return 1;
	} else {
		return 0;
	}
}

sub getMusicDirs {
	my $mediadirs = $serverPrefs->get('mediadirs');
	my $ignoreInAudioScan = $serverPrefs->get('ignoreInAudioScan');
	my $lmsmusicdirs = [];
	my %musicdircount;
	my $thisdir;
	foreach $thisdir (@{$mediadirs}, @{$ignoreInAudioScan}) {$musicdircount{$thisdir}++}
	foreach $thisdir (keys %musicdircount) {
		if ($musicdircount{$thisdir} == 1) {
			push (@{$lmsmusicdirs}, $thisdir);
		}
	}
	return $lmsmusicdirs;
}

sub parse_duration {
	use integer;
	sprintf("%02dh:%02dm", $_[0]/3600, $_[0]/60%60);
}

sub isTimeOrEmpty {
	my $name = shift;
	my $arg = shift;
	if (!$arg || $arg eq '') {
		return 1;
	} elsif ($arg =~ m/^([0\s]?[0-9]|1[0-9]|2[0-4]):([0-5][0-9])\s*(P|PM|A|AM)?$/isg) {
		return 1;
	}
	return 0;
}

sub pathForItem {
	my $item = shift;
	if (Slim::Music::Info::isFileURL($item) && !Slim::Music::Info::isFragment($item)) {
		my $path = Slim::Utils::Misc::fixPath($item) || return 0;
		return Slim::Utils::Misc::pathFromFileURL($path);
	}
	return $item;
}

sub getCurrentDBH {
	return Slim::Schema->storage->dbh();
}

sub commit {
	my $dbh = shift;
	if (!$dbh->{'AutoCommit'}) {
		$dbh->commit();
	}
}

sub rollback {
	my $dbh = shift;
	if (!$dbh->{'AutoCommit'}) {
		$dbh->rollback();
	}
}

1;