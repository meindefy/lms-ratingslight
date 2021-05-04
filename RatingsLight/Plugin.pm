#
# Ratings Light
#
# (c) 2020-2021 AF-1
#
# GPLv3 license
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#

package Plugins::RatingsLight::Plugin;

use strict;
use warnings;
use utf8;

use base qw(Slim::Plugin::Base);
use base qw(FileHandle);
use Digest::MD5 qw(md5_hex);
use File::Basename;
use File::Copy qw(move);
use File::Spec::Functions qw(:ALL);
use File::stat;
use FindBin qw($Bin);
use POSIX qw(strftime floor);
use Scalar::Util qw(blessed);
use Slim::Control::Request;
use Slim::Player::Client;
use Slim::Player::Source;
use Slim::Utils::DateTime;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Scanner::API;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Text;
use Time::HiRes qw(time);
use Slim::Schema;
use URI::Escape;
use XML::Parser;

use Data::Dumper;

use Plugins::RatingsLight::Settings::Basic;
use Plugins::RatingsLight::Settings::Backup;
use Plugins::RatingsLight::Settings::Import;
use Plugins::RatingsLight::Settings::Export;
use Plugins::RatingsLight::Settings::Menus;
use Plugins::RatingsLight::Settings::DSTM;

my $log = Slim::Utils::Log->addLogCategory({
	'category' => 'plugin.ratingslight',
	'defaultLevel' => 'WARN',
	'description' => 'PLUGIN_RATINGSLIGHT',
});

my $prefs = preferences('plugin.ratingslight');
my $serverPrefs = preferences('server');

my $initialised = 0;
my (%restoreitem, $currentKey, $inTrack, $inValue, $backupParser, $backupParserNB, $restorestarted);
my $opened = 0;

sub initPlugin {
	my $class = shift;
	return if $initialised;

	initPrefs();

	Slim::Music::Import->addImporter('Plugins::RatingsLight::Plugin', {
		'type' => 'post',
		'weight' => 99,
		'use' => 1,
	});

	if (!main::SCANNER) {
		initIR();

		Slim::Control::Request::addDispatch(['ratingslight','setrating','_trackid','_rating','_incremental'], [1, 0, 1, \&setRating]);
		Slim::Control::Request::addDispatch(['ratingslight','setratingpercent', '_trackid', '_rating','_incremental'], [1, 0, 1, \&setRating]);
		Slim::Control::Request::addDispatch(['ratingslight','ratingmenu','_trackid'], [0, 1, 1, \&getRatingMenu]);
		Slim::Control::Request::addDispatch(['ratingslight','moreratedtracksbyartistmenu','_trackid', '_artistid'], [0, 1, 1, \&getMoreRatedTracksbyArtistMenu]);
		Slim::Control::Request::addDispatch(['ratingslight', 'actionsmenu'], [0, 1, 1, \&getActionsMenu]);
		Slim::Control::Request::addDispatch(['ratingslight', 'changedrating', '_url', '_trackid', '_rating', '_ratingpercent'],[0, 0, 0, undef]);
		Slim::Control::Request::addDispatch(['ratingslightchangedratingupdate'],[0, 1, 0, undef]);

		Slim::Web::HTTP::CSRF->protectCommand('ratingslight');

		addTitleFormat('RL_RATING_STARS');
		Slim::Music::TitleFormatter::addFormat('RL_RATING_STARS',\&getTitleFormat_Rating);

		addTitleFormat('RL_RATING_STARS_APPENDED');
		Slim::Music::TitleFormatter::addFormat('RL_RATING_STARS_APPENDED',\&getTitleFormat_Rating_AppendedStars);

		if (main::WEBUI) {
			Plugins::RatingsLight::Settings::Basic->new($class);
			Plugins::RatingsLight::Settings::Backup->new($class);
			Plugins::RatingsLight::Settings::Import->new($class);
			Plugins::RatingsLight::Settings::Export->new($class);
			Plugins::RatingsLight::Settings::Menus->new($class);
			Plugins::RatingsLight::Settings::DSTM->new($class);

			Slim::Web::Pages->addPageFunction('showmoreratedtracklist', \&handleMoreRatedWebTrackList);
		}

		Slim::Menu::TrackInfo->registerInfoProvider(ratingslightrating => (
				before => 'artwork',
				func => \&trackInfoHandlerRating,
		));
		Slim::Menu::TrackInfo->registerInfoProvider(ratingslightmoreratedtracks => (
				after => 'ratingslightrating',
				func => \&showMoreRatedTracksbyArtistInfoHandler,
		));

		if (Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin')) {
			require Slim::Plugin::DontStopTheMusic::Plugin;

			Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_RATINGSLIGHT_DSTM_RATED', sub {
				dontStopTheMusic('rated', @_);
			});
			Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_RATINGSLIGHT_DSTM_TOPRATED', sub {
				dontStopTheMusic('rated_toprated', @_);
			});
			Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_RATINGSLIGHT_DSTM_RATED_GENRE', sub {
				dontStopTheMusic('rated_genre', @_);
			});
			Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_RATINGSLIGHT_DSTM_RATED_GENRE_TOPRATED', sub {
				dontStopTheMusic('rated_genre_toprated', @_);
			});
			Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_RATINGSLIGHT_DSTM_UNRATED_RATED', sub {
				dontStopTheMusic('unrated_rated', @_);
			});
			Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_RATINGSLIGHT_DSTM_UNRATED_RATED_GENRE', sub {
				dontStopTheMusic('unrated_rated_genre', @_);
			});
			Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_RATINGSLIGHT_DSTM_UNRATED_RATED_UNPLAYED', sub {
				dontStopTheMusic('unrated_rated_unplayed', @_);
			});
			Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_RATINGSLIGHT_DSTM_UNRATED_RATED_UNPLAYED_GENRE', sub {
				dontStopTheMusic('unrated_rated_unplayed_genre', @_);
			});
		}

		backupScheduler();
		initExportBaseFilePathMatrix();

		$class->SUPER::initPlugin(@_);
		$initialised = 1;
	}
}

sub initPrefs {
	my $enableIRremotebuttons = $prefs->get('enableIRremotebuttons');

	my $topratedminrating = $prefs->get('topratedminrating');
	if (!defined $topratedminrating) {
		$prefs->set('topratedminrating', '60');
	}

	my $rlparentfolderpath = $prefs->get('rlparentfolderpath');
	if (!defined $rlparentfolderpath) {
		my $playlistdir = $serverPrefs->get('playlistdir');
		$prefs->set('rlparentfolderpath', $playlistdir);
	}

	my $uselogfile = $prefs->get('uselogfile');
	my $userecentlyaddedplaylist = $prefs->get('userecentlyaddedplaylist');

	my $ratethisplaylistid;
	$prefs->set('ratethisplaylistid', '');

	my $ratethisplaylistrating;
	$prefs->set('ratethisplaylistrating', '');

	my $rating_keyword_prefix = $prefs->get('rating_keyword_prefix');
	if ((!defined $rating_keyword_prefix) || ($rating_keyword_prefix eq '')) {
		$prefs->set('rating_keyword_prefix', '');
	}

	my $rating_keyword_suffix = $prefs->get('rating_keyword_suffix');
	if ((!defined $rating_keyword_suffix) || ($rating_keyword_suffix eq '')) {
		$prefs->set('rating_keyword_suffix', '');
	}

	my $autoscan = $prefs->get('autoscan');

	my $exportVL_id;
	$prefs->set('exportVL_id', '');

	my $onlyratingnotmatchcommenttag = $prefs->get('onlyratingnotmatchcommenttag');
	my $exportextension = $prefs->get('exportextension');
	my $scheduledbackups = $prefs->get('scheduledbackups');

	my $backuptime = $prefs->get('backuptime');
	if (!defined $backuptime) {
		$prefs->set('backuptime', '05:28');
	}

	my $backup_lastday = $prefs->get('backup_lastday');
	if (!defined $backup_lastday) {
		$prefs->set('backup_lastday', '');
	}

	my $backupsdaystokeep = $prefs->get('backupsdaystokeep');
	if (!defined $backupsdaystokeep) {
		$prefs->set('backupsdaystokeep', '10');
	}

	my $clearallbeforerestore = $prefs->get('clearallbeforerestore');

	my $restorefile;

	my $showratedtracksmenus = $prefs->get('showratedtracksmenus');
	if (!defined $showratedtracksmenus) {
		$prefs->set('showratedtracksmenus', '0');
	}

	my $browsemenus_sourceVL_id = $prefs->get('browsemenus_sourceVL_id');

	my $displayratingchar = $prefs->get('displayratingchar');
	if (!defined $displayratingchar) {
		$prefs->set('displayratingchar', '0');
	}

	my $ratingcontextmenusethalfstars = $prefs->get('ratingcontextmenusethalfstars');

	my $recentlymaxcount = $prefs->get('recentlymaxcount');
	if (!defined $recentlymaxcount) {
		$prefs->set('recentlymaxcount', '30');
	}

	my $moreratedtracksbyartistweblimit = $prefs->get('moreratedtracksbyartistweblimit');
	if (!defined $moreratedtracksbyartistweblimit) {
		$prefs->set('moreratedtracksbyartistweblimit', '60');
	}

	my $moreratedtracksbyartistcontextmenulimit = $prefs->get('moreratedtracksbyartistcontextmenulimit');
	if (!defined $moreratedtracksbyartistcontextmenulimit) {
		$prefs->set('moreratedtracksbyartistcontextmenulimit', '30');
	}

	my $dstm_minTrackDuration = $prefs->get('dstm_minTrackDuration');
	if (!defined $dstm_minTrackDuration) {
		$prefs->set('dstm_minTrackDuration', '90');
	}

	my $dstm_percentagerated = $prefs->get('dstm_percentagerated');
	if (!defined $dstm_percentagerated) {
		$prefs->set('dstm_percentagerated', '30');
	}

	my $dstm_percentagetoprated = $prefs->get('dstm_percentagetoprated');
	if (!defined $dstm_percentagetoprated) {
		$prefs->set('dstm_percentagetoprated', '30');
	}

	my $excludegenres_namelist = $prefs->get('excludegenres_namelist');

	my $num_seedtracks = $prefs->get('num_seedtracks');
	if (!defined $num_seedtracks) {
		$prefs->set('num_seedtracks', '10');
	}

	my $status_exportingtoplaylistfiles;
	$prefs->set('status_exportingtoplaylistfiles', '0');
	my $status_importingfromcommenttags;
	$prefs->set('status_importingfromcommenttags', '0');
	my $status_batchratingplaylisttracks;
	$prefs->set('status_batchratingplaylisttracks', '0');
	my $status_creatingbackup;
	$prefs->set('status_creatingbackup', '0');
	my $status_restoringfrombackup;
	$prefs->set('status_restoringfrombackup', '0');
	my $status_clearingallratings;
	$prefs->set('status_clearingallratings', '0');

	$prefs->init({
		enableIRremotebuttons => $enableIRremotebuttons,
		topratedminrating => $topratedminrating,
		rlparentfolderpath => $rlparentfolderpath,
		userecentlyaddedplaylist => $userecentlyaddedplaylist,
		recentlymaxcount => $recentlymaxcount,
		uselogfile => $uselogfile,
		ratethisplaylistid => $ratethisplaylistid,
		ratethisplaylistrating => $ratethisplaylistrating,
		rating_keyword_prefix => $rating_keyword_prefix,
		rating_keyword_suffix => $rating_keyword_suffix,
		autoscan => $autoscan,
		exportVL_id => $exportVL_id,
		onlyratingnotmatchcommenttag => $onlyratingnotmatchcommenttag,
		exportextension => $exportextension,
		dstm_percentagerated => $dstm_percentagerated,
		dstm_percentagetoprated => $dstm_percentagetoprated,
		num_seedtracks => $num_seedtracks,
		dstm_minTrackDuration => $dstm_minTrackDuration,
		excludegenres_namelist => $excludegenres_namelist,
		scheduledbackups => $scheduledbackups,
		backuptime => $backuptime,
		backup_lastday => $backup_lastday,
		backupsdaystokeep => $backupsdaystokeep,
		restorefile => $restorefile,
		clearallbeforerestore => $clearallbeforerestore,
		showratedtracksmenus => $showratedtracksmenus,
		browsemenus_sourceVL_id => $browsemenus_sourceVL_id,
		displayratingchar => $displayratingchar,
		ratingcontextmenusethalfstars => $ratingcontextmenusethalfstars,
		moreratedtracksbyartistweblimit => $moreratedtracksbyartistweblimit,
		moreratedtracksbyartistcontextmenulimit => $moreratedtracksbyartistcontextmenulimit,
		status_exportingtoplaylistfiles => $status_exportingtoplaylistfiles,
		status_importingfromcommenttags => $status_importingfromcommenttags,
		status_batchratingplaylisttracks => $status_batchratingplaylisttracks,
		status_creatingbackup => $status_creatingbackup,
		status_restoringfrombackup => $status_restoringfrombackup,
		status_clearingallratings => $status_clearingallratings,
	});

	$prefs->setValidate({
		validator => sub {
			return if $_[1] =~ m|[^a-zA-Z]|;
			return if $_[1] =~ m|[a-zA-Z]{31,}|;
			return 1;
		}
	}, 'rating_keyword_prefix');
	$prefs->setValidate({
		validator => sub {
			return if $_[1] =~ m|[^a-zA-Z]|;
			return if $_[1] =~ m|[a-zA-Z]{31,}|;
			return 1;
		}
	}, 'rating_keyword_suffix');
	$prefs->setValidate({
		validator => sub {
			return if $_[1] =~ m|[^a-zA-Z0-9]|;
			return if $_[1] =~ m|[a-zA-Z0-9]{10,}|;
			return 1;
		}
	}, 'exportextension');
	$prefs->setValidate({ 'validator' => \&isTimeOrEmpty }, 'backuptime');
	$prefs->setValidate({ 'validator' => 'intlimit', 'low' => 1, 'high' => 365 }, 'backupsdaystokeep');
	$prefs->setValidate({ 'validator' => 'intlimit', 'low' => 2, 'high' => 200 }, 'recentlymaxcount');
	$prefs->setValidate({ 'validator' => 'intlimit', 'low' => 5, 'high' => 200 }, 'moreratedtracksbyartistweblimit');
	$prefs->setValidate({ 'validator' => 'intlimit', 'low' => 5, 'high' => 100 }, 'moreratedtracksbyartistcontextmenulimit');
	$prefs->setValidate({ 'validator' => 'intlimit', 'low' => 0, 'high' => 1800 }, 'dstm_minTrackDuration');
	$prefs->setValidate({ 'validator' => 'intlimit', 'low' => 0, 'high' => 100 }, 'dstm_percentagerated');
	$prefs->setValidate({ 'validator' => 'intlimit', 'low' => 0, 'high' => 100 }, 'dstm_percentagetoprated');
	$prefs->setValidate({ 'validator' => 'intlimit', 'low' => 1, 'high' => 20 }, 'num_seedtracks');

	$prefs->setChange(\&initVirtualLibraries, 'browsemenus_sourceVL_id');
	$prefs->setChange(\&initVirtualLibraries, 'showratedtracksmenus');
	$prefs->setChange(\&initIR, 'enableIRremotebuttons');
	$prefs->setChange(sub {
			Slim::Music::Info::clearFormatDisplayCache();
			refreshTitleFormats();
		}, 'displayratingchar');
}

sub postinitPlugin {
	if (!main::SCANNER) {
		initVirtualLibraries();
	}
}

sub shutdownPlugin {
	return if !$initialised;
	$log->debug('Shutting down');
	my $enableIRremotebuttons = $prefs->get('enableIRremotebuttons');
	if (defined $enableIRremotebuttons) {
		Slim::Control::Request::unsubscribe(\&newPlayerCheck, [['client']],[['new']]);
	}
	Slim::Music::Import->useImporter('Plugins::RatingsLight::Plugin',0);
	$initialised = 0;
}


## set ratings

sub setRating {
	my $request = shift;

	if (Slim::Music::Import->stillScanning) {
		$log->warn('Warning: access to rating values blocked until library scan is completed');
		return;
	}

	if (($request->isNotCommand([['ratingslight'],['setrating']])) && ($request->isNotCommand([['ratingslight'],['setratingpercent']]))) {
		$request->setStatusBadDispatch();
		return;
	}
	my $client = $request->client();
	if (!defined $client) {
		$request->setStatusNeedsClient();
		return;
	}

	my $trackId = $request->getParam('_trackid');
	if (defined($trackId) && $trackId =~ /^track_id:(.*)$/) {
		$trackId = $1;
	} elsif (defined($request->getParam('_trackid'))) {
		$trackId = $request->getParam('_trackid');
	}

	my $rating = $request->getParam('_rating');
	if (defined($rating) && $rating =~ /^rating:(.*)$/) {
		$rating = $1;
	} elsif (defined($request->getParam('_rating'))) {
		$rating = $request->getParam('_rating');
	}

	my $incremental = $request->getParam('_incremental');
	if (defined($incremental) && $incremental =~ /^incremental:(.*)$/) {
		$incremental = $1;
	} elsif (defined($request->getParam('_incremental'))) {
		$incremental = $request->getParam('_incremental');
	}

	if (!defined $trackId || $trackId eq '' || !defined $rating || $rating eq '') {
		$request->setStatusBadParams();
		return;
	}

	my $track = Slim::Schema->resultset("Track")->find($trackId);
	my $trackURL = $track->url;
	my $rating100ScaleValue = 0;

	if (defined($incremental) && (($incremental eq '+') || ($incremental eq '-'))) {
		my $currentrating = $track->rating;
		if (!defined $currentrating) {
			$currentrating = 0;
		}
		if ($incremental eq '+') {
			if ($request->isNotCommand([['ratingslight'],['setratingpercent']])) {
				$rating100ScaleValue = $currentrating + int($rating * 20);
			} else {
				$rating100ScaleValue = $currentrating + int($rating);
			}
		} elsif ($incremental eq '-') {
			if ($request->isNotCommand([['ratingslight'],['setratingpercent']])) {
				$rating100ScaleValue = $currentrating - int($rating * 20);
			} else {
				$rating100ScaleValue = $currentrating - int($rating);
			}
		}
	} else {
		if ($request->isNotCommand([['ratingslight'],['setratingpercent']])) {
			$rating100ScaleValue = int($rating * 20);
		} else {
			$rating100ScaleValue = $rating;
		}
	}
	$rating100ScaleValue = ratingSanityCheck($rating100ScaleValue);

	writeRatingToDB($trackURL, $rating100ScaleValue);

	Slim::Music::Info::clearFormatDisplayCache();
	Slim::Control::Request::notifyFromArray($client, ['ratingslight', 'changedrating', $trackURL, $trackId, $rating100ScaleValue/20, $rating100ScaleValue]);
	Slim::Control::Request::notifyFromArray(undef, ['ratingslightchangedratingupdate', $trackURL, $trackId, $rating100ScaleValue/20, $rating100ScaleValue]);
	refreshTitleFormats();

	$request->addResult('rating', $rating100ScaleValue/20);
	$request->addResult('ratingpercentage', $rating100ScaleValue/20);
	$request->setStatusDone();

	refreshVirtualLibraries();
}

sub VFD_deviceRating {
	my ($client, $callback, $params, $trackURL, $trackID, $rating) = @_;

	$log->debug('VFD_deviceRating - trackURL = '.$trackURL);
	$log->debug('VFD_deviceRating - trackID = '.$trackID);
	$log->debug('VFD_deviceRating - rating = '.$rating);
	writeRatingToDB($trackURL, $rating);
	Slim::Music::Info::clearFormatDisplayCache();

	my $cbtext = string('PLUGIN_RATINGSLIGHT_RATING').' '.(getRatingTextLine($rating));
	$callback->([{
		type => 'text',
		name => $cbtext,
		showBriefly => 1, popback => 3,
		favorites => 0, refresh => 1,
	}]);

	Slim::Control::Request::notifyFromArray($client, ['ratingslight', 'changedrating', $trackURL, $trackID, $rating/20, $rating]);
	Slim::Control::Request::notifyFromArray(undef, ['ratingslightchangedratingupdate', $trackURL, $trackID, $rating/20, $rating]);
	refreshTitleFormats();

	refreshVirtualLibraries();
}


## infohandlers, context menus

sub trackInfoHandlerRating {
 	my $rating100ScaleValue = 0;
	my $ratingcontextmenusethalfstars = $prefs->get('ratingcontextmenusethalfstars');
	my $text = string('PLUGIN_RATINGSLIGHT_RATING');

	my ($client, $url, $track, $remoteMeta, $tags) = @_;
	$tags ||= {};

	if (Slim::Music::Import->stillScanning) {
		if ($tags->{menuMode}) {
			my $jive = {};
			return {
				type => '',
				name => $text.' '.string('PLUGIN_RATINGSLIGHT_BLOCKED'),
				jive => $jive,
			};
		} else {
			return {
				type => 'text',
				name => $text.' '.string('PLUGIN_RATINGSLIGHT_BLOCKED'),
			};
		}
	}

	$rating100ScaleValue = getRatingFromDB($track);
	$text = string('PLUGIN_RATINGSLIGHT_RATING').' '.(getRatingTextLine($rating100ScaleValue));

	if ($tags->{menuMode}) {
		my $jive = {};
		my $actions = {
			go => {
				player => 0,
				cmd => ['ratingslight', 'ratingmenu', $track->id],
			},
		};
		$jive->{actions} = $actions;

		return {
			type => 'redirect',
			name => $text,
			jive => $jive,
		};
	} else {
		my $item = {
			type => 'text',
			name => $text,
			itemvalue => $rating100ScaleValue,
			itemvalue5starexact => $rating100ScaleValue/20,
			itemid => $track->id,
			web => {
				'type' => 'htmltemplate',
				'value' => 'plugins/RatingsLight/html/trackratinginfo.html'
			},
		};

		delete $item->{type};
		my @ratingValues = ();
		if (defined $ratingcontextmenusethalfstars) {
			@ratingValues = qw(100 90 80 70 60 50 40 30 20 10 0);
		} else {
			@ratingValues = qw(100 80 60 40 20 0);
		}

		my @items = ();
		foreach my $ratingValue (@ratingValues) {
			push(@items,
			{
				name => getRatingTextLine($ratingValue),
				url => \&VFD_deviceRating,
				passthrough => [$url, $track->id, $ratingValue],
			});
		}
		$item->{items} = \@items;
		return $item;
	}
}

sub getRatingMenu {
	my $request = shift;
	my $client = $request->client();
	my $ratingcontextmenusethalfstars = $prefs->get('ratingcontextmenusethalfstars');

	if (!$request->isQuery([['ratingslight'],['ratingmenu']])) {
		$log->warn('incorrect command');
		$request->setStatusBadDispatch();
		return;
	}
	if (!defined $client) {
		$log->warn('client required');
		$request->setStatusNeedsClient();
		return;
	}
	my $track_id = $request->getParam('_trackid');

	my $baseMenu = {
		'actions' => {
			'do' => {
				'cmd' => ['ratingslight', 'setratingpercent', $track_id],
				'itemsParams' => 'params',
			},
			'play' => {
				'cmd' => ['ratingslight', 'setratingpercent', $track_id],
				'itemsParams' => 'params',
			},
		}
	};
	$request->addResult('base', $baseMenu);
	my $cnt = 0;

	my @ratingValues = ();
	if (defined $ratingcontextmenusethalfstars) {
		@ratingValues = qw(100 90 80 70 60 50 40 30 20 10 0);
	} else {
		@ratingValues = qw(100 80 60 40 20 0);
	}

	foreach my $rating (@ratingValues) {
		my %itemParams = (
			'rating' => $rating,
		);
		$request->addResultLoop('item_loop',$cnt,'params',\%itemParams);
		my $text = getRatingTextLine($rating);

		$request->addResultLoop('item_loop',$cnt,'text',$text);
		$request->addResultLoop('item_loop',$cnt,'nextWindow','parent');
		$cnt++;
	}

	$request->addResult('offset',0);
	$request->addResult('count',$cnt);
	$request->setStatusDone();
}

sub showMoreRatedTracksbyArtistInfoHandler {
	my ($client, $url, $track, $remoteMeta, $tags) = @_;
	$tags ||= {};

	if (Slim::Music::Import->stillScanning) {
		$log->warn('Warning: not available until library scan is completed');
		return;
	}
	my ($text, $wtitle);
	my $trackID = $track->id;
	my $artistID = $track->primary_artist->id;

	my $artistname = $track->primary_artist->name;
	$artistname = trimString($artistname, 50);

	my $curTrackRating = getRatingFromDB($track);
	if ($curTrackRating > 0) {
		$text = string('PLUGIN_RATINGSLIGHT_MENUS_MORERATEDTRACKSBYARTIST').' '.$artistname;
		$wtitle = 1;
	} else {
		$text = string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKSBYARTIST').' '.$artistname;
		$wtitle = 0;
	}
	my $trackcount = 0;
	my $dbh = getCurrentDBH();

	my $currentLibrary = Slim::Music::VirtualLibraries->getLibraryIdForClient($client);
	$log->debug('current client VlibID = '.$currentLibrary);

	my $sqlstatement;
	if ((defined $currentLibrary) && ($currentLibrary ne '')) {
		$sqlstatement = "select count (*) from tracks left join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating > 0 left join library_track library_track on library_track.track = tracks.id where primary_artist = $artistID and tracks.id != $trackID and library_track.library = \"$currentLibrary\"";
	} else {
		$sqlstatement = "select count (*) from tracks join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating > 0 where primary_artist = $artistID and tracks.id != $trackID";
	}

	eval{
		my $sth = $dbh->prepare($sqlstatement);
		$sth->execute() or do {	$sqlstatement = undef;};
		$trackcount = $sth->fetchrow;
	};
	if ($@) {$log->debug("error: $@");}

	if ($trackcount > 0) {
		if ($tags->{menuMode}) {
			my $jive = {};
			my $actions = {
				go => {
					player => 0,
					cmd => ['ratingslight', 'moreratedtracksbyartistmenu', $trackID, $artistID, $artistname],
				},
			};
			$jive->{actions} = $actions;
			return {
				type => 'redirect',
				name => $text,
				jive => $jive,
			};
		} else {

			my $item = {
				type => 'text',
				name => $text,
				trackid => $trackID,
				artistname => $artistname,
				artistid => $artistID,
				wtitle => $wtitle,
				web => {
					'type' => 'htmltemplate',
					'value' => 'plugins/RatingsLight/html/showmoreratedtracks.html'
				},
			};

			delete $item->{type};
			my @items = ();
			my $ratedsongsbyartist = VFD_moreratedtracksbyartist($client, $trackID, $artistID, $artistname);
			$item->{items} = \@{$ratedsongsbyartist};
			return $item;
		}
	} else {
		return;
	}
}

sub handleMoreRatedWebTrackList {
	my $moreratedtracksbyartistweblimit = $prefs->get('moreratedtracksbyartistweblimit');
	my ($client, $params, $callback, $httpClient, $response) = @_;

	my $artistID = $params->{artistid};
	my $trackID = $params->{trackid};

	my $moreratedtracks = getMoreRatedTracks($client, $trackID, $artistID, $moreratedtracksbyartistweblimit);

	my $artistname = (@{$moreratedtracks})[0]->artist->name;
	$artistname = trimString($artistname, 50);
	$params->{artistname} = $artistname;

	my @moreratedtracks_webpage = ();
 	my $alltrackids = '';

	foreach my $ratedtrack (@{$moreratedtracks}) {

		if ($alltrackids eq '') {
			$alltrackids = $ratedtrack->id;
		} else {
			$alltrackids .= ','.($ratedtrack->id);
		}

 		my $track_id = $ratedtrack->id;
 		my $tracktitle = trimString($ratedtrack->title, 70);

		my $albumname = 'Album: '.$ratedtrack->album->name;
		$albumname = trimString($albumname, 80);
		my $albumID = $ratedtrack->album->id;
		my $artworkID = $ratedtrack->album->artwork;

		my $rating = getRatingFromDB($ratedtrack);
		my $ratingtext = getRatingTextLine($rating, 'appended');
		$tracktitle = $tracktitle.$ratingtext;

		push (@moreratedtracks_webpage, {trackid => $track_id, tracktitle => $tracktitle, albumname => $albumname, albumid => $albumID, artworkid => $artworkID});

		if ($alltrackids eq '') {
			$alltrackids = $track_id;
		} else {
			$alltrackids .= ','.$track_id;
		}
	}

	$params->{trackcount} = scalar(@moreratedtracks_webpage);
	$params->{alltrackids} = $alltrackids;
	$params->{moreratedtracks} = \@moreratedtracks_webpage;
	return Slim::Web::HTTP::filltemplatefile('plugins/RatingsLight/showmoreratedtracklist.html', $params);
}

sub getMoreRatedTracksbyArtistMenu {
	my $moreratedtracksbyartistcontextmenulimit = $prefs->get('moreratedtracksbyartistcontextmenulimit');
	my $request = shift;
	my $client = $request->client();

	if (!$request->isQuery([['ratingslight'],['moreratedtracksbyartistmenu']])) {
		$log->warn('incorrect command');
		$request->setStatusBadDispatch();
		return;
	}
	if (!defined $client) {
		$log->warn('client required!');
		$request->setStatusNeedsClient();
		return;
	}
	my $trackID = $request->getParam('_trackid');
	my $artistID = $request->getParam('_artistid');

	my $moreratedtracks = getMoreRatedTracks($client, $trackID, $artistID, $moreratedtracksbyartistcontextmenulimit);

	my %menuStyle = ();
	$menuStyle{'titleStyle'} = 'mymusic';
	$menuStyle{'menuStyle'} = 'album';
	$menuStyle{'windowStyle'} = 'icon_list';
	$request->addResult('window',\%menuStyle);

	my $cnt = 0;
 	my $trackcount = scalar(@{$moreratedtracks});
	if ($trackcount > 1) {
		$cnt = 1;
	}
	my $alltrackids = '';

	foreach my $ratedtrack (@{$moreratedtracks}) {
		$request->addResultLoop('item_loop',$cnt,'icon-id',$ratedtrack->coverid);

		if ($alltrackids eq '') {
			$alltrackids = $ratedtrack->id;
		} else {
			$alltrackids .= ','.($ratedtrack->id);
		}

		my ($tracktitle, $albumname, $ratingtext) = '';
		my $rating = getRatingFromDB($ratedtrack);
		$tracktitle = trimString($ratedtrack->title, 60);

		$albumname = 'Album: '.$ratedtrack->album->name;
		$albumname = trimString($albumname, 70);

		$ratingtext = getRatingTextLine($rating, 'appended');
		my $returntext = $tracktitle.$ratingtext."\n".$albumname;

		my $actions = {
			'go' => {
				'player' => 0,
				'cmd' => ['ratingslight', 'actionsmenu', 'track_id:'.$ratedtrack->id, 'allsongs:0'],
			},
		};

		$request->addResultLoop('item_loop',$cnt,'type','redirect');
		$request->addResultLoop('item_loop',$cnt,'actions',$actions);
		$request->addResultLoop('item_loop',$cnt,'text',$returntext);
		$cnt++;
	}

	if ($trackcount > 1) {
		my $actions = {
			'go' => {
				'player' => 0,
				'cmd' => ['ratingslight', 'actionsmenu', 'track_id:'.$alltrackids, 'allsongs:1'],
			},
		};
		$request->addResultLoop('item_loop',0,'type','redirect');
		$request->addResultLoop('item_loop',0,'actions',$actions);
		$request->addResultLoop('item_loop',0,'icon', 'plugins/RatingsLight/html/images/coverplaceholder.png');
		$request->addResultLoop('item_loop',0,'text',string('PLUGIN_RATINGSLIGHT_MENUS_MORERATEDTRACKSBYARTIST_MENU_ALLSONGS').' ('.$trackcount.')');
		$cnt++;
	}

	$request->addResult('offset',0);
	$request->addResult('count',$cnt);
	$request->setStatusDone();
}

sub getActionsMenu {
	my $request = shift;
	if (!$request->isQuery([['ratingslight'],['actionsmenu']])) {
		$log->warn('incorrect command');
		$request->setStatusBadDispatch();
		return;
	}

	my $trackID = $request->getParam('track_id');
	my $allsongs = $request->getParam('allsongs');

	$request->addResult('window', {
		menustyle => 'album',
	});

	my $actionsmenuitems = [
		{
			itemtext => string('PLUGIN_RATINGSLIGHT_MENUS_MORERATEDTRACKSBYARTIST_MENU_PLAYNOW'),
			itemcmd1 => 'playlistcontrol',
			itemcmd2 => 'load'
		},
		{
			itemtext => string('PLUGIN_RATINGSLIGHT_MENUS_MORERATEDTRACKSBYARTIST_MENU_PLAYNEXT'),
			itemcmd1 => 'playlistcontrol',
			itemcmd2 => 'insert'
		},
		{
			itemtext => string('PLUGIN_RATINGSLIGHT_MENUS_MORERATEDTRACKSBYARTIST_MENU_APPEND'),
			itemcmd1 => 'playlistcontrol',
			itemcmd2 => 'add'
		},
		{
			itemtext => string('PLUGIN_RATINGSLIGHT_MENUS_MORERATEDTRACKSBYARTIST_MENU_MOREINFO'),
			itemcmd1 => 'trackinfo',
			itemcmd2 => 'items',
		}];

	my $cnt = 0;
	foreach my $menuitem (@{$actionsmenuitems}) {
		my $menuitemtext = $menuitem->{'itemtext'};
		my $menuitemcmd1 = $menuitem->{'itemcmd1'};
		my $menuitemcmd2 = $menuitem->{'itemcmd2'};
		my $actions;

		unless (($menuitemcmd1 eq 'trackinfo') && ($allsongs == 1)) {
			my $thisitem->{'actionParam'} = 'track_id';

			if ($menuitemcmd1 eq 'trackinfo') {
				my %itemParams = (
					'track_id' => $trackID,
					'menu' => 1,
					'usecontextmenu' => 1,
				);
				$actions = {
					'player' => 0,
					'go' => {
						'cmd' => [$menuitemcmd1, $menuitemcmd2],
						'params' => {
							'menu' => 1,
							$thisitem->{'actionParam'} => $trackID,
						},
					},
					'player' => 0,
					'play' => {
						'cmd' => [$menuitemcmd1, $menuitemcmd2],
						'params' => {
							'menu' => 1,
							$thisitem->{'actionParam'} => $trackID,
						},
					}
				};
			} else {
				$actions = {
					'player' => 0,
					'go' => {
						'cmd' => [$menuitemcmd1, 'cmd:'.$menuitemcmd2, 'track_id:'.$trackID],
					},
					'player' => 0,
					'play' => {
						'cmd' => [$menuitemcmd1, 'cmd:'.$menuitemcmd2, 'track_id:'.$trackID],
					}
				};
				$request->addResultLoop('item_loop',$cnt,'nextWindow','parent');
			}

			$request->addResultLoop('item_loop',$cnt,'actions',$actions);
			$request->addResultLoop('item_loop',$cnt,'text',$menuitemtext);
			$cnt++;
		}
	}
	$request->addResult('offset',0);
	$request->addResult('count',$cnt);
	$request->setStatusDone();
}

sub VFD_moreratedtracksbyartist {
	my ($client, $trackID, $artistID) = @_;
	my $moreratedtracksbyartistcontextmenulimit = $prefs->get('moreratedtracksbyartistcontextmenulimit');
 	$log->debug('VFD_moreratedtracksbyartist - trackID = '.$trackID);
 	$log->debug('VFD_moreratedtracksbyartist - artistID = '.$artistID);

	my $moreratedtracks = getMoreRatedTracks($client, $trackID, $artistID, $moreratedtracksbyartistcontextmenulimit);
	my @vfd_moreratedtracks = ();
	my $alltrackids = '';

	foreach my $ratedtrack (@{$moreratedtracks}) {

		if ($alltrackids eq '') {
			$alltrackids = $ratedtrack->id;
		} else {
			$alltrackids .= ','.($ratedtrack->id);
		}

 		my $track_id = $ratedtrack->id;
 		my $tracktitle = $ratedtrack->title;
		$tracktitle = trimString($tracktitle, 70);

		my $rating = getRatingFromDB($ratedtrack);
		my $ratingtext = getRatingTextLine($rating, 'appended');
		$tracktitle = $tracktitle.$ratingtext;
		push (@vfd_moreratedtracks, {
			type => 'redirect',
			name => $tracktitle,
			items => [
				{	name => string('PLUGIN_RATINGSLIGHT_MENUS_MORERATEDTRACKSBYARTIST_MENU_PLAYNOW'),
					type => 'redirect',
					url => \&VFD_execActions,
					passthrough => [$track_id, 'load', 'Playing track now'],
				},
				{	name => string('PLUGIN_RATINGSLIGHT_MENUS_MORERATEDTRACKSBYARTIST_MENU_PLAYNEXT'),
					type => 'redirect',
					url => \&VFD_execActions,
					passthrough => [$track_id, 'insert', 'Track will be played next'],
				},
				{	name => string('PLUGIN_RATINGSLIGHT_MENUS_MORERATEDTRACKSBYARTIST_MENU_APPEND'),
					type => 'redirect',
					url => \&VFD_execActions,
					passthrough => [$track_id, 'add', 'Added track to end of queue'],
				},
			]
		});
	}
	my $trackcount = scalar(@vfd_moreratedtracks);
	if ($trackcount > 1) {
		unshift @vfd_moreratedtracks, {
			type => 'redirect',
			name => string('PLUGIN_RATINGSLIGHT_MENUS_MORERATEDTRACKSBYARTIST_MENU_ALLSONGS'),
			items => [
				{	name => string('PLUGIN_RATINGSLIGHT_MENUS_MORERATEDTRACKSBYARTIST_MENU_PLAYNOW'),
					type => 'redirect',
					url => \&VFD_execActions,
					passthrough => [$alltrackids, 'load', 'Playing tracks now'],
				},
				{	name => string('PLUGIN_RATINGSLIGHT_MENUS_MORERATEDTRACKSBYARTIST_MENU_PLAYNEXT'),
					type => 'redirect',
					url => \&VFD_execActions,
					passthrough => [$alltrackids, 'insert', 'Tracks will be played next'],
				},
				{	name => string('PLUGIN_RATINGSLIGHT_MENUS_MORERATEDTRACKSBYARTIST_MENU_APPEND'),
					type => 'redirect',
					url => \&VFD_execActions,
					passthrough => [$alltrackids, 'add', 'Added tracks to end of queue'],
				},
			]
		};

	}
	return \@vfd_moreratedtracks;
}

sub VFD_execActions {
	my ($client, $callback, $params, $trackID, $action, $cbtext) = @_;
 	$log->debug('action = '.$action);

	my @actionargs = ('playlistcontrol', 'cmd:'.$action, 'track_id:'.$trackID);
	$client->execute(\@actionargs);

	$callback->([{
		type => 'text',
		name => $cbtext,
		showBriefly => 1, popback => 2,
		favorites => 0, refresh => 1
	}]);
}

sub getMoreRatedTracks {
	my $moreratedtracksbyartistcontextmenulimit = $prefs->get('moreratedtracksbyartistcontextmenulimit');
	my ($client, $trackID, $artistID, $listlimit) = @_;
	$log->debug('getting more rated tracks - sql query');

	my @moreratedtracks = ();
	my $dbh = getCurrentDBH();
	my $currentLibrary = Slim::Music::VirtualLibraries->getLibraryIdForClient($client);

	my $sqlstatement;
	if ((defined $currentLibrary) && ($currentLibrary ne '')) {
		$sqlstatement = "select tracks.url from tracks join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating > 0 left join library_track library_track on library_track.track = tracks.id where primary_artist = $artistID and tracks.id != $trackID and library_track.library = \"$currentLibrary\" limit $listlimit";
	} else {
		$sqlstatement = "select tracks.url from tracks join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating > 0 where primary_artist = $artistID and tracks.id != $trackID limit $listlimit";
	}

	my $sth = $dbh->prepare($sqlstatement);
	$sth->execute() or do {	$sqlstatement = undef;};

	my ($trackURL, $track);
	$sth->bind_col(1,\$trackURL);

	while ($sth->fetch()) {
		$track = Slim::Schema->resultset("Track")->objectForUrl($trackURL);
		push @moreratedtracks,$track;
	}
	$sth->finish();
	return \@moreratedtracks;
}


## import, export

sub startScan {
	my $enableautoscan = $prefs->get('autoscan');
	if (defined $enableautoscan) {
		importRatingsFromCommentTags();
	}
	Slim::Music::Import->endImporter(__PACKAGE__);
}

sub importRatingsFromCommentTags {
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

	refreshVirtualLibraries();

	$log->debug('Import completed after '.$ended.' seconds.');
	$prefs->set('status_importingfromcommenttags', 0);
}

sub importRatingsFromPlaylist {
	if (Slim::Music::Import->stillScanning) {
		$log->warn('Warning: access to rating values blocked until library scan is completed');
		return;
	}
	my $status_batchratingplaylisttracks = $prefs->get('status_batchratingplaylisttracks');
	if ($status_batchratingplaylisttracks == 1) {
		$log->warn('Import is already in progress, please wait for the previous import to finish');
		return;
	}
	$prefs->set('status_batchratingplaylisttracks', 1);
	my $started = time();

	my $playlistid = $prefs->get('ratethisplaylistid');
	my $rating = $prefs->get('ratethisplaylistrating');

	my $queryresult = Slim::Control::Request::executeRequest(undef, ['playlists', 'tracks', '0', '1000', 'playlist_id:'.$playlistid, 'tags:u']);

	my $playlisttrackcount = $queryresult->getResult('count');
	if ($playlisttrackcount > 0) {
		my $trackURL;
		my $playlisttracksarray = $queryresult->getResult('playlisttracks_loop');

		for my $playlisttrack (@{$playlisttracksarray}) {
			$trackURL = $playlisttrack->{url};
			writeRatingToDB($trackURL, $rating, 0);
		}
	}
	my $ended = time() - $started;

	refreshVirtualLibraries();

	$log->debug('Rating playlist tracks completed after '.$ended.' seconds.');
	$prefs->set('ratethisplaylistid', '');
	$prefs->set('ratethisplaylistrating', '');
	$prefs->set('status_batchratingplaylisttracks', 0);
}

sub exportRatingsToPlaylistFiles {
	my $status_exportingtoplaylistfiles = $prefs->get('status_exportingtoplaylistfiles');
	if ($status_exportingtoplaylistfiles == 1) {
		$log->warn('Export is already in progress, please wait for the previous export to finish');
		return;
	}
	$prefs->set('status_exportingtoplaylistfiles', 1);

	my $rlparentfolderpath = $prefs->get('rlparentfolderpath');
	my $exportDir = $rlparentfolderpath.'/RatingsLight';
	my $started = time();
	mkdir($exportDir, 0755) unless (-d $exportDir);
	chdir($exportDir) or $exportDir = $rlparentfolderpath;

	my $onlyratingnotmatchcommenttag = $prefs->get('onlyratingnotmatchcommenttag');
	my $rating_keyword_prefix = $prefs->get('rating_keyword_prefix');
	my $rating_keyword_suffix = $prefs->get('rating_keyword_suffix');
	my ($sql, $sth) = undef;
	my $dbh = getCurrentDBH();
	my $rating100ScaleValueCeil = 0;
	my $rating100ScaleValue = 10;
	my $exporttimestamp = strftime "%Y-%m-%d %H:%M:%S", localtime time;
	my $filename_timestamp = strftime "%Y%m%d-%H%M", localtime time;
	my $exportVL_id = $prefs->get('exportVL_id');
	$log->debug('exportVL_id = '.$exportVL_id);
	my $totaltrackcount = 0;
	until ($rating100ScaleValue > 100) {
		$rating100ScaleValueCeil = $rating100ScaleValue + 9;
		if (defined $onlyratingnotmatchcommenttag) {
			if ((!defined $rating_keyword_prefix || $rating_keyword_prefix eq '') && (!defined $rating_keyword_suffix || $rating_keyword_suffix eq '')) {
				$log->warn('Error: no rating keywords found.');
				return
			} else {
				if ((defined $exportVL_id) && ($exportVL_id ne '')) {
						$sql = "SELECT tracks.url FROM tracks LEFT JOIN tracks_persistent persistent ON persistent.urlmd5 = tracks.urlmd5 LEFT JOIN library_track library_track ON library_track.track = tracks.id WHERE tracks.audio = 1 AND (persistent.rating >= $rating100ScaleValue AND persistent.rating <= $rating100ScaleValueCeil) AND persistent.urlmd5 IN (SELECT tracks.urlmd5 FROM tracks LEFT JOIN comments ON comments.track = tracks.id WHERE (comments.value NOT LIKE ? OR comments.value IS NULL)) AND library_track.library = \"$exportVL_id\"";
				} else {
						$sql = "SELECT tracks_persistent.url FROM tracks_persistent WHERE (tracks_persistent.rating >= $rating100ScaleValue AND tracks_persistent.rating <= $rating100ScaleValueCeil AND tracks_persistent.urlmd5 IN (SELECT tracks.urlmd5 FROM tracks LEFT JOIN comments ON comments.track = tracks.id WHERE (comments.value NOT LIKE ? OR comments.value IS NULL)));";
				}
				$sth = $dbh->prepare($sql);
				my $ratingkeyword = "%%".$rating_keyword_prefix.($rating100ScaleValue/20).$rating_keyword_suffix."%%";
				$sth->bind_param(1, $ratingkeyword);
			}
		} else {
			if ((defined $exportVL_id) && ($exportVL_id ne '')) {
				$sql = "SELECT tracks.url FROM tracks LEFT JOIN tracks_persistent persistent ON persistent.urlmd5 = tracks.urlmd5 LEFT JOIN library_track library_track ON library_track.track = tracks.id WHERE tracks.audio = 1 AND (persistent.rating >= $rating100ScaleValue AND persistent.rating <= $rating100ScaleValueCeil) AND library_track.library = \"$exportVL_id\"";
			} else {
				$sql = "SELECT tracks_persistent.url FROM tracks_persistent WHERE (tracks_persistent.rating >= $rating100ScaleValue AND tracks_persistent.rating <= $rating100ScaleValueCeil);";
			}
			$sth = $dbh->prepare($sql);
		}
		$sth->execute();

		my $trackURL;
		$sth->bind_col(1,\$trackURL);

		my @trackURLs = ();
		while ($sth->fetch()) {
			push @trackURLs,$trackURL;
		}
		$sth->finish();
		my $trackcount = scalar(@trackURLs);
		$log->debug('number of tracks rated $rating100ScaleValue to export: '.$trackcount);
		$totaltrackcount = $totaltrackcount + $trackcount;

		if (@trackURLs) {
			my $PLfilename = (($rating100ScaleValue/20) == 1 ? 'RL_Export_'.$filename_timestamp.'__Rated_'.($rating100ScaleValue/20).'_star.m3u.txt' : 'RL_Export_'.$filename_timestamp.'__Rated_'.($rating100ScaleValue/20).'_stars.m3u.txt');

			my $filename = catfile($exportDir,$PLfilename);
			my $output = FileHandle->new($filename, '>:utf8') or do {
				$log->warn('could not open '.$filename.' for writing.');
				$prefs->set('status_exportingtoplaylistfiles', 0);
				return;
			};
			my $trackcount = scalar(@trackURLs);
			print $output '#EXTM3U'."\n";
			print $output '# exported with \'Ratings Light\' LMS plugin ('.$exporttimestamp.")\n";
			if ((defined $exportVL_id) && ($exportVL_id ne '')) {
				my $exportVL_name = Slim::Music::VirtualLibraries->getNameForId($exportVL_id);
				print $output '# tracks from library (view): '.$exportVL_name."\n";
			}
			print $output '# contains '.$trackcount.($trackcount == 1 ? ' track' : ' tracks').' rated '.(($rating100ScaleValue/20) == 1 ? ($rating100ScaleValue/20).' star' : ($rating100ScaleValue/20).' stars')."\n\n";
			if (defined $onlyratingnotmatchcommenttag) {
				print $output "# *** This export only contains rated tracks whose ratings differ from the rating value derived from their comment tag keywords. ***\n";
				print $output "# *** If you want to export ALL rated tracks change the preference on the Ratings Light settings page. ***\n\n";
			}
			for my $PLtrackURL (@trackURLs) {
				$PLtrackURL = changeExportFilePath($PLtrackURL);
				print $output "#EXTURL:".$PLtrackURL."\n";
				my $unescapedURL = uri_unescape($PLtrackURL);
				print $output $unescapedURL."\n";
			}
			close $output;
		}
		$rating100ScaleValue = $rating100ScaleValue + 10;
	}

	$log->debug('TOTAL number of tracks exported: '.$totaltrackcount);
	$prefs->set('status_exportingtoplaylistfiles', 0);
	my $ended = time() - $started;
	$prefs->set('exportVL_id', '');
	$log->debug('Export completed after '.$ended.' seconds.');
}

sub changeExportFilePath {
	my $trackURL = shift;
	my $oldtrackURL = $trackURL;
	my $exportbasefilepathmatrix = $prefs->get('exportbasefilepathmatrix');
	my $exportextension = $prefs->get('exportextension');

	if (scalar @{$exportbasefilepathmatrix} > 0) {
		foreach my $thispath (@{$exportbasefilepathmatrix}) {
			if (($trackURL =~ ($thispath->{'lmsbasepath'})) && (defined ($thispath->{'substitutebasepath'})) && (($thispath->{'substitutebasepath'}) ne '')) {
				my $lmsbasepath = $thispath->{'lmsbasepath'};
				my $substitutebasepath = $thispath->{'substitutebasepath'};
				if (defined $exportextension) {
					$trackURL =~ s/\.[^.]*$/\.$exportextension/isg;
				}
				$lmsbasepath =~ s/\\/\//isg;
				$lmsbasepath =~ s/(^\/*)|(\/*$)//isg;
				$substitutebasepath =~ s/\\/\//isg;
				$substitutebasepath =~ s/(^\/*)|(\/*$)//isg;
				$substitutebasepath = escape($substitutebasepath);
				$trackURL =~ s/$lmsbasepath/$substitutebasepath/isg;
				$trackURL =~ s/\/{2,}/\//isg;
				$trackURL =~ s/file:\//file:\/\/\//isg;
				$log->debug("old url: ".$oldtrackURL."\nlmsbasepath = ".$lmsbasepath."\nsubstitutebasepath = ".$substitutebasepath."\nnew url = ".$trackURL);
			}
		}
	}
	return $trackURL;
}

sub initExportBaseFilePathMatrix {
	# get LMS music dirs
	my $mediadirs = $serverPrefs->get('mediadirs');
	my $ignoreInAudioScan = $serverPrefs->get('ignoreInAudioScan');
	my $lmsmusicdirs = [];
	my %musicdircount;
	my $thisdir;
	foreach $thisdir (@{$mediadirs}, @{$ignoreInAudioScan}) { $musicdircount{$thisdir}++ }
	foreach $thisdir (keys %musicdircount) {
		if ($musicdircount{$thisdir} == 1) {
			push (@{$lmsmusicdirs}, $thisdir);
		}
	}

	my $exportbasefilepathmatrix = $prefs->get('exportbasefilepathmatrix');
	if (!defined $exportbasefilepathmatrix) {
		my $n = 0;
		foreach my $musicdir (@{$lmsmusicdirs}) {
			push(@{$exportbasefilepathmatrix}, { lmsbasepath => $musicdir, substitutebasepath => ''});
			$n++;
		}
		$prefs->set('exportbasefilepathmatrix', $exportbasefilepathmatrix);
	} else {
		# add new music dirs as options if not in list
		my @currentlmsbasefilepaths;
		foreach my $thispath (@{$exportbasefilepathmatrix}) {
			push (@currentlmsbasefilepaths, $thispath->{'lmsbasepath'});
		}

		my %seen;
		@seen{@currentlmsbasefilepaths} = ();

		foreach my $newdir (@{$lmsmusicdirs}) {
			push (@{$exportbasefilepathmatrix}, { lmsbasepath => $newdir, substitutebasepath => ''}) unless exists $seen{$newdir};
		}
		$prefs->set('exportbasefilepathmatrix', \@{$exportbasefilepathmatrix});
	}
}


## backup, restore

sub createBackup {
	if (Slim::Music::Import->stillScanning) {
		$log->warn('Warning: access to rating values blocked until library scan is completed');
		return;
	}

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
	my ($trackURL, $rating100ScaleValue, $track);
	my $started = time();
	my $backuptimestamp = strftime "%Y-%m-%d %H:%M:%S", localtime time;
	my $filename_timestamp = strftime "%Y%m%d-%H%M", localtime time;

	$sql = "SELECT tracks_persistent.url FROM tracks_persistent WHERE tracks_persistent.rating > 0";
	$sth = $dbh->prepare($sql);
	$sth->execute();

	$sth->bind_col(1,\$trackURL);

	my @trackURLs = ();
	while ($sth->fetch()) {
		push @trackURLs,$trackURL;
	}
	$sth->finish();

	if (@trackURLs) {
		my $PLfilename = 'RL_Backup_'.$filename_timestamp.'.xml';

		my $filename = catfile($backupDir,$PLfilename);
		my $output = FileHandle->new($filename, '>:utf8') or do {
			$log->warn('could not open '.$filename.' for writing.');
			$prefs->set('status_creatingbackup', 0);
			return;
		};
		my $trackcount = scalar(@trackURLs);
		my $ignoredtracks = 0;
		$log->debug("Found ".$trackcount.($trackcount == 1 ? " rated track" : " rated tracks")." in the LMS persistent database");

		print $output "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n";
		print $output "<!-- Backup of Rating Values -->\n";
		print $output "<!-- ".$backuptimestamp." -->\n";
		print $output "<RatingsLight>\n";
		for my $BACKUPtrackURL (@trackURLs) {
			$track = Slim::Schema->resultset("Track")->objectForUrl($BACKUPtrackURL);
			if (!defined $track) {
				$log->warn("Warning: ignoring this track, not found in LMS database:\n".$BACKUPtrackURL);
				$trackcount--;
				$ignoredtracks++;
			} else {
				$rating100ScaleValue = getRatingFromDB($track);
				$BACKUPtrackURL = escape($BACKUPtrackURL);
				print $output "\t<track>\n\t\t<url>".$BACKUPtrackURL."</url>\n\t\t<rating>".$rating100ScaleValue."</rating>\n\t</track>\n";
			}
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

sub backupScheduler {
	my $scheduledbackups = $prefs->get('scheduledbackups');
	if (defined $scheduledbackups) {
		my $backuptime = $prefs->get('backuptime');
		my $day = $prefs->get('backup_lastday');
		if (!defined($day)) {
			$day = '';
		}

		if (defined($backuptime) && $backuptime ne '') {
			my $time = 0;
			$backuptime =~ s{
				^(0?[0-9]|1[0-9]|2[0-4]):([0-5][0-9])\s*(P|PM|A|AM)?$
			}{
				if (defined $3) {
					$time = ($1 == 12?0:$1 * 60 * 60) + ($2 * 60) + ($3 =~ /P/?12 * 60 * 60:0);
				} else {
					$time = ($1 * 60 * 60) + ($2 * 60);
				}
			}iegsx;
			my ($sec,$min,$hour,$mday,$mon,$year) = localtime(time);

			my $currenttime = $hour * 60 * 60 + $min * 60;

			if (($day ne $mday) && $currenttime>$time) {
				eval {
					createBackup();
				};
				if ($@) {
					$log->error("Scheduled backup failed: $@");
				}
				$prefs->set('backup_lastday',$mday);
			} else {
				my $timesleft = $time-$currenttime;
				if ($day eq $mday) {
					$timesleft = $timesleft + 60*60*24;
				}
				$log->debug(parse_duration($timesleft)." ($timesleft seconds) left until next scheduled backup");
			}
		}
		Slim::Utils::Timers::setTimer(0, Time::HiRes::time() + 3600, \&backupScheduler);
	}
}

sub cleanupBackups {
	my $rlparentfolderpath = $prefs->get('rlparentfolderpath');
	my $backupDir = $rlparentfolderpath.'/RatingsLight';
 	return unless (-d $backupDir);
	my $backupsdaystokeep = $prefs->get('backupsdaystokeep');
	my $maxkeeptime = $backupsdaystokeep * 24 * 60 * 60; # in seconds
	my @files;
	opendir(my $DH, $backupDir) or die "Error opening $backupDir: $!";
	@files = grep(/^RL_Backup_.*$/, readdir($DH));
	closedir($DH);
	my $mtime;
	my $etime = int(time());
	my $n = 0;
	foreach my $file (@files) {
		$mtime = stat($file)->mtime;
		if (($etime - $mtime) > $maxkeeptime) {
			unlink($file) or die "Can\'t delete $file: $!";
			$n++;
		}
	}
	$log->debug("Deleted $n backups.");
}

sub restoreFromBackup {
	if (Slim::Music::Import->stillScanning) {
		$log->warn('Warning: access to rating values blocked until library scan is completed');
		return;
	}

	my $status_restoringfrombackup = $prefs->get('status_restoringfrombackup');
	my $clearallbeforerestore = $prefs->get('clearallbeforerestore');

	if ($status_restoringfrombackup == 1) {
		$log->warn('Restore is already in progress, please wait for the previous restore to finish');
		return;
	}

	$prefs->set('status_restoringfrombackup', 1);
	$restorestarted = time();
	my $restorefile = $prefs->get('restorefile');

	if ($restorefile) {
		if (defined $clearallbeforerestore) {
			clearAllRatings();
		}
		initRestore();
		Slim::Utils::Scheduler::add_task(\&scanFunction);
	} else {
		$log->error('Error: No backup file specified');
		$prefs->set('status_restoringfrombackup', 0);
	}
}

sub initRestore {
	if (defined($backupParserNB)) {
		eval { $backupParserNB->parse_done };
		$backupParserNB = undef;
	}
	$backupParser = XML::Parser->new(
		'ErrorContext' => 2,
		'ProtocolEncoding' => 'UTF-8',
		'NoExpand' => 1,
		'NoLWP' => 1,
		'Handlers' => {
			'Start' => \&handleStartElement,
			'Char' => \&handleCharElement,
			'End' => \&handleEndElement,
		},
	);
}

sub scanFunction {
	my $restorefile = $prefs->get('restorefile');
	if ($opened != 1) {
		open(BACKUPFILE, $restorefile) || do {
			$log->warn('Couldn\'t open backup file: '.$restorefile);
			$prefs->set('status_restoringfrombackup', 0);
			return 0;
		};
		$opened = 1;
		$inTrack = 0;
		$inValue = 0;
		%restoreitem = ();
		$currentKey = undef;

		if (defined $backupParser) {
			$backupParserNB = $backupParser->parse_start();
		} else {
			$log->warn('No backupParser was defined!');
		}
	}

	if (defined $backupParserNB) {
		local $/ = '>';
		my $line;

		for (my $i = 0; $i < 25;) {
			my $singleLine = <BACKUPFILE>;
			if (defined($singleLine)) {
				$line .= $singleLine;
				if ($singleLine =~ /(<\/track>)$/) {
					$i++;
				}
			} else {
				last;
			}
		}
		$line =~ s/&#(\d*);/escape(chr($1))/ge;
		$backupParserNB->parse_more($line);
		return 1;
	}

	$log->warn('No backupParserNB defined!');
	$prefs->set('status_restoringfrombackup', 0);
	return 0;
}

sub doneScanning {
	my $rlparentfolderpath = $prefs->get('rlparentfolderpath');

	if (defined $backupParserNB) {
		eval { $backupParserNB->parse_done };
	}

	$backupParserNB = undef;
	$backupParser = undef;
	$opened = 0;
	close(BACKUPFILE);

	my $ended = time() - $restorestarted;
	$log->debug('Restore completed after '.$ended.' seconds.');

	refreshVirtualLibraries();

	$prefs->set('status_restoringfrombackup', 0);
	Slim::Utils::Scheduler::remove_task(\&scanFunction);
	my $RLfolderpath = $rlparentfolderpath.'/Ratingslight';
	$prefs->set('restorefile', $RLfolderpath);
}

sub handleStartElement {
	my ($p, $element) = @_;

	if ($inTrack) {
		$currentKey = $element;
		$inValue = 1;
	}
	if ($element eq 'track') {
		$inTrack = 1;
	}
}

sub handleCharElement {
	my ($p, $value) = @_;

	if ($inValue && $currentKey) {
		$restoreitem{$currentKey} = $value;
	}
}

sub handleEndElement {
	my ($p, $element) = @_;
	$inValue = 0;

	if ($inTrack && $element eq 'track') {
		$inTrack = 0;

		my $curTrack = \%restoreitem;
		my $trackURL = $curTrack->{'url'};
		$trackURL = unescape($trackURL);
		my $rating = $curTrack->{'rating'};

		writeRatingToDB($trackURL, $rating, 0);

		%restoreitem = ();
	}

	if ($element eq 'RatingsLight') {
		doneScanning();
		return 0;
	}
}


## virtual libraries

sub initVirtualLibraries {
	Slim::Music::VirtualLibraries->unregisterLibrary('RL_RATED');
	Slim::Music::VirtualLibraries->unregisterLibrary('RL_TOPRATED');
	Slim::Menu::BrowseLibrary->deregisterNode('RatingsLightRatedTracksMenuFolder');

	my $showratedtracksmenus = $prefs->get('showratedtracksmenus');
	if ($showratedtracksmenus > 0) {
		my $browsemenus_sourceVL_id = $prefs->get('browsemenus_sourceVL_id');
		$log->debug('browsemenus_sourceVL_id = '.Dumper($browsemenus_sourceVL_id));
		my $topratedminrating = $prefs->get('topratedminrating');

		my $libraries = Slim::Music::VirtualLibraries->getLibraries();
		# check if source virtual library still exists, otherwise use complete library
		if ((defined $browsemenus_sourceVL_id) && ($browsemenus_sourceVL_id ne '')) {
			my $VLstillexists = 0;
			foreach my $thisVLid (keys %{$libraries}) {
				if ($thisVLid eq $browsemenus_sourceVL_id) {
					$VLstillexists = 1;
					$log->debug("VL $browsemenus_sourceVL_id exists!");
				}
			}
			if ($VLstillexists == 0) {
				$prefs->set('browsemenus_sourceVL_id', undef);
				$browsemenus_sourceVL_id = undef;
			}
		}

		$browsemenus_sourceVL_id = $prefs->get('browsemenus_sourceVL_id');
		my @libraries = ();
		if ((!defined $browsemenus_sourceVL_id) || ($browsemenus_sourceVL_id eq '')) {
			push @libraries,{
				id => 'RL_RATED',
				name => 'Ratings Light - Rated Tracks',
				sql => qq{
					INSERT OR IGNORE INTO library_track (library, track)
					SELECT '%s', tracks.id
					FROM tracks
					LEFT JOIN tracks_persistent tracks_persistent ON tracks_persistent.urlmd5 = tracks.urlmd5
					WHERE tracks_persistent.rating > 0
					GROUP by tracks.id
				},
			};
		} else {
			push @libraries,{
				id => 'RL_RATED',
				name => 'Ratings Light - Rated Tracks',
				sql => qq{
					INSERT OR IGNORE INTO library_track (library, track)
					SELECT '%s', tracks.id
					FROM tracks
					LEFT JOIN tracks_persistent tracks_persistent ON tracks_persistent.urlmd5 = tracks.urlmd5
					LEFT JOIN library_track library_track ON library_track.track = tracks.id
					WHERE tracks_persistent.rating > 0
					AND library_track.library = "$browsemenus_sourceVL_id"
					GROUP by tracks.id
				},
			};
		}

		if ($showratedtracksmenus == 2) {
			if ((!defined $browsemenus_sourceVL_id) || ($browsemenus_sourceVL_id eq '')) {
				push @libraries,{
					id => 'RL_TOPRATED',
					name => 'Ratings Light - Top Rated Tracks',
					sql => qq{
						INSERT OR IGNORE INTO library_track (library, track)
						SELECT '%s', tracks.id
						FROM tracks
						LEFT JOIN tracks_persistent tracks_persistent ON tracks_persistent.urlmd5 = tracks.urlmd5
							WHERE tracks_persistent.rating >= $topratedminrating
						GROUP by tracks.id
					}
				};
			} else {
				push @libraries,{
					id => 'RL_TOPRATED',
					name => 'Ratings Light - Top Rated Tracks',
					sql => qq{
						INSERT OR IGNORE INTO library_track (library, track)
						SELECT '%s', tracks.id
						FROM tracks
						LEFT JOIN tracks_persistent tracks_persistent ON tracks_persistent.urlmd5 = tracks.urlmd5
						LEFT JOIN library_track library_track ON library_track.track = tracks.id
							WHERE tracks_persistent.rating >= $topratedminrating
							AND library_track.library = "$browsemenus_sourceVL_id"
						GROUP by tracks.id
					}
				};
			}
		}
		foreach my $library (@libraries) {
			Slim::Music::VirtualLibraries->unregisterLibrary($library);
			Slim::Music::VirtualLibraries->registerLibrary($library);
			Slim::Music::VirtualLibraries->rebuild($library->{id});
		}

			Slim::Menu::BrowseLibrary->deregisterNode('RatingsLightRatedTracksMenuFolder');
			my $browsemenus_sourceVL_name = '';
			if ((defined $browsemenus_sourceVL_id) && ($browsemenus_sourceVL_id ne '')) {
				$browsemenus_sourceVL_name = Slim::Music::VirtualLibraries->getNameForId($browsemenus_sourceVL_id);
				$browsemenus_sourceVL_name = ' (Library View: '.$browsemenus_sourceVL_name.')';
			}
			Slim::Menu::BrowseLibrary->registerNode({
							type => 'link',
							name => 'PLUGIN_RATINGSLIGHT_MENUS_RATED_TRACKS_MENU_FOLDER',
							id => 'RatingsLightRatedTracksMenuFolder',
							feed => sub {
								my ($client, $cb, $args, $pt) = @_;
								my @items = ();

								# Artists with rated tracks
								$pt = { library_id => Slim::Music::VirtualLibraries->getRealId('RL_RATED') };
								push @items,{
									type => 'link',
									name => string('PLUGIN_RATINGSLIGHT_MENUS_ARTISTMENU_RATED').$browsemenus_sourceVL_name,
									url => \&Slim::Menu::BrowseLibrary::_artists,
									icon => 'html/images/artists.png',
									jiveIcon => 'html/images/artists.png',
									id => string('myMusicArtists_RATED_TracksByArtist'),
									condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
									weight => 209,
									cache => 1,
									passthrough => [{
										library_id => $pt->{'library_id'},
										searchTags => [
											'library_id:'.$pt->{'library_id'}
										],
									}],
								};

								# Genres with rated tracks
								$pt = { library_id => Slim::Music::VirtualLibraries->getRealId('RL_RATED') };
								push @items,{
									type => 'link',
									name => string('PLUGIN_RATINGSLIGHT_MENUS_GENREMENU_RATED').$browsemenus_sourceVL_name,
									url => \&Slim::Menu::BrowseLibrary::_genres,
									icon => 'html/images/genres.png',
									jiveIcon => 'html/images/genres.png',
									id => string('myMusicGenres_RATED_TracksByGenres'),
									condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
									weight => 211,
									cache => 1,
									passthrough => [{
										library_id => $pt->{'library_id'},
										searchTags => [
											'library_id:'.$pt->{'library_id'}
										],
									}],
								};

								if ($showratedtracksmenus == 2) {
									# Artists with top rated tracks
									$pt = { library_id => Slim::Music::VirtualLibraries->getRealId('RL_TOPRATED') };
									push @items,{
										type => 'link',
										name => string('PLUGIN_RATINGSLIGHT_MENUS_ARTISTMENU_TOPRATED').$browsemenus_sourceVL_name,
										url => \&Slim::Menu::BrowseLibrary::_artists,
										icon => 'html/images/artists.png',
										jiveIcon => 'html/images/artists.png',
										id => string('myMusicArtists_RATED_TOPRATED_TracksByArtist'),
										condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
										weight => 210,
										cache => 1,
										passthrough => [{
											library_id => $pt->{'library_id'},
											searchTags => [
												'library_id:'.$pt->{'library_id'}
											],
										}],
									};

									# Genres with top rated tracks
									$pt = { library_id => Slim::Music::VirtualLibraries->getRealId('RL_TOPRATED') };
									push @items,{
										type => 'link',
										name => string('PLUGIN_RATINGSLIGHT_MENUS_GENREMENU_TOPRATED').$browsemenus_sourceVL_name,
										url => \&Slim::Menu::BrowseLibrary::_genres,
										icon => 'html/images/genres.png',
										jiveIcon => 'html/images/genres.png',
										id => string('myMusicGenres_RATED_TOPRATED_TracksByGenres'),
										condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
										weight => 212,
										cache => 1,
										passthrough => [{
											library_id => $pt->{'library_id'},
											searchTags => [
												'library_id:'.$pt->{'library_id'}
											],
										}],
									};
								}

								$cb->({
									items => \@items,
								});

							},

							weight => 88,
							cache => 1,
							icon => 'plugins/RatingsLight/html/images/ratedtracksmenuicon.png',
							jiveIcon => 'plugins/RatingsLight/html/images/ratedtracksmenuicon.png',
					});
	}
}

sub refreshVirtualLibraries {
	my $showratedtracksmenus = $prefs->get('showratedtracksmenus');

	if ($showratedtracksmenus > 0) {
		my $started = time();
		my $library_id_rated_all = Slim::Music::VirtualLibraries->getRealId('RL_RATED');
		Slim::Music::VirtualLibraries->rebuild($library_id_rated_all);

		if ($showratedtracksmenus == 2) {
			my $library_id_rated_toprated = Slim::Music::VirtualLibraries->getRealId('RL_TOPRATED');
			Slim::Music::VirtualLibraries->rebuild($library_id_rated_toprated);
		}
		my $ended = time() - $started;
		$log->debug('Refreshing virtual libraries completed after '.$ended.' seconds.');
	}
}

sub getVirtualLibraries {
	my $libraries = Slim::Music::VirtualLibraries->getLibraries();
	my %libraries;

	%libraries = map {
		$_ => $libraries->{$_}->{name}
	} keys %{$libraries} if keys %{$libraries};

	return \%libraries;
}


## IR remote rating

sub initIR {
	my $enableIRremotebuttons = $prefs->get('enableIRremotebuttons');

	if (defined $enableIRremotebuttons) {
		Slim::Control::Request::subscribe(\&newPlayerCheck, [['client']],[['new']]);
		Slim::Buttons::Common::addMode('PLUGIN.RatingsLight::Plugin', getFunctions(),\&Slim::Buttons::Input::Choice::setMode);
	} else {
		Slim::Control::Request::unsubscribe(\&newPlayerCheck, [['client']],[['new']]);
	}
}

sub getFunctions {
	our %menuFunctions = (
		'saveremoteratings' => sub {
			my $rating = undef;
			my $client = shift;
			my $button = shift;
			my $digit = shift;
			$log->debug('IR command - button: '.$button);
			$log->debug('IR command - digit: '.$digit);

			if (Slim::Music::Import->stillScanning) {
				$log->warn('Warning: access to rating values blocked until library scan is completed');
				$client->showBriefly({
					'line' => [$client->string('PLUGIN_RATINGSLIGHT'),$client->string('PLUGIN_RATINGSLIGHT_BLOCKED')]},
					3);
				return;
			}

			return unless $digit>='0' && $digit<='9';

			my $song = Slim::Player::Playlist::song($client);
			my $curtrackinfo = $song->{_column_data};
			my $curtrackURL = @{$curtrackinfo}{url};
			my $curtrackid = @{$curtrackinfo}{id};
			if ($digit >= 0 && $digit <=5) {
				$rating = $digit*20;
			}

			if ($digit >= 6 && $digit <= 9) {
				my $track = Slim::Schema->resultset('Track')->find($curtrackid);
				my $currentrating = $track->rating;
				if (!defined $currentrating) {
					$currentrating = 0;
				}
				if ($digit == 6) {
					$rating = $currentrating - 20;
				}
				if ($digit == 7) {
					$rating = $currentrating + 20;
				}
				if ($digit == 8) {
					$rating = $currentrating - 10;
				}
				if ($digit == 9) {
					$rating = $currentrating + 10;
				}
				$rating = ratingSanityCheck($rating);
			}
			$log->debug('IR command - current track URL = '.$curtrackURL);
			$log->debug('IR command - current track ID = '.$curtrackid);
			$log->debug('IR command - rating = '.$rating);
			VFD_deviceRating($client, undef, undef, $curtrackURL, $curtrackid, $rating);
		},
	);
	return \%menuFunctions;
}

sub newPlayerCheck {
	my ($request) = @_;
	my $client = $request->client();
	my $model = getClientModel($client);

	if ((defined $client) && ($request->{_requeststr} eq 'client,new')) {
		foreach my $button (0..9) {
			Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 2, \&mapKeyHold, $button, "modefunction_PLUGIN.RatingsLight::Plugin->saveremoteratings_$button");
		}
		if ($model eq 'boom') {
			Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 2, \&mapKeyHold, 'arrow_down', "modefunction_PLUGIN.RatingsLight::Plugin->saveremoteratings_6");
			Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 2, \&mapKeyHold, 'arrow_up', "modefunction_PLUGIN.RatingsLight::Plugin->saveremoteratings_7");
		}
	}
}

sub mapKeyHold {
	# from Peter Watkins' plugin AllQuiet
	my $client = shift;
	my $baseKeyName = shift;
	my $function = shift;
	my $logless = 1;
	if (defined($client)) {
		my $mapsAltered = 0;
		my @maps = @{$client->irmaps};
		for (my $i = 0; $i < scalar(@maps) ; ++$i) {
			if (ref($maps[$i]) eq 'HASH') {
				my %mHash = %{$maps[$i]};
				foreach my $key (keys %mHash) {
					if (ref($mHash{$key}) eq 'HASH') {
						my %mHash2 = %{$mHash{$key}};
						# if no $baseKeyName.hold
						if ((!defined($mHash2{$baseKeyName.'.hold'})) || ($mHash2{$baseKeyName.'.hold'} eq 'dead')) {
							unless (defined $logless) {
								$log->debug("mapping $function to ${baseKeyName}.hold for $i-$key");
							}
							if ((defined($mHash2{$baseKeyName}) || (defined($mHash2{$baseKeyName.'.*'}))) && 								 (!defined($mHash2{$baseKeyName.'.single'}))) {
								# make baseKeyName.single = baseKeyName
								$mHash2{$baseKeyName.'.single'} = $mHash2{$baseKeyName};
							}
							# make baseKeyName.hold = $function
							$mHash2{$baseKeyName.'.hold'} = $function;
							# make baseKeyName.repeat = 'dead'
							$mHash2{$baseKeyName.'.repeat'} = 'dead';
							# make baseKeyName.release = 'dead'
							$mHash2{$baseKeyName.'.hold_release'} = 'dead';
							# delete unqualified baseKeyName
							$mHash2{$baseKeyName} = undef;
							# delete baseKeyName.*
							$mHash2{$baseKeyName.'.*'} = undef;
							++$mapsAltered;
						} else {
							unless (defined $logless) {
								$log->debug("${baseKeyName}.hold mapping already exists for $i-$key");
							}
						}
						$mHash{$key} = \%mHash2;
					}
				}
				$maps[$i] = \%mHash;
			}
		}
		if ($mapsAltered > 0) {
			unless (defined $logless) {
				$log->debug("mapping ${baseKeyName}.hold to $function for \"'.$client->name().'\" in $mapsAltered modes");
			}
			$client->irmaps(\@maps);
		}
	}
}


## rating log, playlist

sub addToRecentlyRatedPlaylist {
	my $trackURL = shift;
	my $playlistname = 'Recently Rated Tracks (Ratings Light)';
	my $recentlymaxcount = $prefs->get('recentlymaxcount');
	my $request = Slim::Control::Request::executeRequest(undef, ['playlists', 0, 1, 'search:'.$playlistname]);
	my $existsPL = $request->getResult('count');
	my $playlistid;

 	if ($existsPL == 1) {
 		my $playlistidhash = $request->getResult('playlists_loop');
		foreach my $hashref (@{$playlistidhash}) {
			$playlistid = $hashref->{id};
		}

		my $trackcountRequest = Slim::Control::Request::executeRequest(undef, ['playlists', 'tracks', '0', '1000', 'playlist_id:'.$playlistid, 'tags:count']);
		my $trackcount = $trackcountRequest->getResult('count');
		if ($trackcount > ($recentlymaxcount - 1)) {
			Slim::Control::Request::executeRequest(undef, ['playlists', 'edit', 'cmd:delete', 'playlist_id:'.$playlistid, 'index:0']);
		}

 	} elsif ($existsPL == 0) {
 		my $createplaylistrequest = Slim::Control::Request::executeRequest(undef, ['playlists', 'new', 'name:'.$playlistname]);
 		$playlistid = $createplaylistrequest->getResult('playlist_id');
 	}

	Slim::Control::Request::executeRequest(undef, ['playlists', 'edit', 'cmd:add', 'playlist_id:'.$playlistid, 'url:'.$trackURL]);
}

sub logRatedTrack {
	my ($trackURL, $rating100ScaleValue) = @_;

	my ($previousRating, $newRatring) = 0;
	my $ratingtimestamp = strftime "%Y-%m-%d %H:%M:%S", localtime time;

	my $logFileName = 'RL_Rating-Log.txt';
	my $rlparentfolderpath = $prefs->get('rlparentfolderpath');
	my $logDir = $rlparentfolderpath.'/RatingsLight';
	mkdir($logDir, 0755) unless (-d $logDir);
	chdir($logDir) or $logDir = $rlparentfolderpath;

	# log rotation
	my $fullfilepath = $logDir.'/'.$logFileName;
	if (-f $fullfilepath) {
		my $logfilesize = stat($logFileName)->size;
		if ($logfilesize > 102400) {
			my $filename_oldlogfile = 'RL_Rating-Log.1.txt';
			my $fullpath_oldlogfile = $logDir.'/'.$filename_oldlogfile;
				if (-f $fullpath_oldlogfile) {
					unlink $fullpath_oldlogfile;
				}
			move $fullfilepath, $fullpath_oldlogfile;
		}
	}

	my ($title, $artist, $album, $previousRating100ScaleValue);
	my $query = Slim::Control::Request::executeRequest(undef, ['songinfo', '0', '100', 'url:'.$trackURL, 'tags:alR']);
	my $songinfohash = $query->getResult('songinfo_loop');

	foreach my $elem (@{$songinfohash}) {
		foreach my $key (keys %{$elem}) {
			if ($key eq 'title') {
				$title = $elem->{$key};
			}
			if ($key eq 'artist') {
				$artist = $elem->{$key};
			}
			if ($key eq 'album') {
				$album = $elem->{$key};
			}
			if ($key eq 'rating') {
				$previousRating100ScaleValue = $elem->{$key};
			}
		}
	}

	if (defined $previousRating100ScaleValue) {
		$previousRating = $previousRating100ScaleValue/20;
	}
	my $newRating = $rating100ScaleValue/20;

	my $filename = catfile($logDir,$logFileName);
	my $output = FileHandle->new($filename, '>>:utf8') or do {
		$log->warn('Could not open '.$filename.' for writing.');
		return;
	};

	print $output $ratingtimestamp."\n";
	print $output 'Artist: '.$artist.' ## Title: '.$title.' ## Album: '.$album."\n";
	print $output 'Previous Rating: '.$previousRating.' --> New Rating: '.$newRating."\n\n";

	close $output;
}

sub clearAllRatings {
	if (Slim::Music::Import->stillScanning) {
		$log->warn('Warning: access to rating values blocked until library scan is completed');
		return;
	}

	my $status_clearingallratings = $prefs->get('status_clearingallratings');
	if ($status_clearingallratings == 1) {
		$log->warn('Clearing ratings is already in progress, please wait for the previous action to finish');
		return;
	}
	$prefs->set('status_clearingallratings', 1);
	my $started = time();

	my $status_restoringfrombackup = $prefs->get('status_restoringfrombackup');
	my $sqlunrateall = "UPDATE tracks_persistent SET rating = NULL WHERE tracks_persistent.rating > 0;";
	my $dbh = getCurrentDBH();
	my $sth = $dbh->prepare($sqlunrateall);
	eval {
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

	my $ended = time() - $started;
	$log->debug('Clearing all ratings completed after '.$ended.' seconds.');
	$prefs->set('status_clearingallratings', 0);

	refreshVirtualLibraries();
}


## Dynamic Playlists, DSTM

sub getDynamicPlayLists {
	my ($client) = @_;
	my %result = ();

	### all possible parameters ###

	# % top rated #
	my %parametertop1 = (
			'id' => 1, # 1-10
			'type' => 'list', # album, artist, genre, year, playlist, list or custom
			'name' => 'Select percentage of top rated songs',
			'definition' => '0:0%,10:10%,20:20%,30:30%,40:40%,50:50%,60:60%,70:70%,80:80%,90:90%,100:100%'
	);
	my %parametertop2 = (
			'id' => 2,
			'type' => 'list',
			'name' => 'Select percentage of top rated songs',
			'definition' => '0:0%,10:10%,20:20%,30:30%,40:40%,50:50%,60:60%,70:70%,80:80%,90:90%,100:100%'
	);
	my %parametertop3 = (
			'id' => 3,
			'type' => 'list',
			'name' => 'Select percentage of top rated songs',
			'definition' => '0:0%,10:10%,20:20%,30:30%,40:40%,50:50%,60:60%,70:70%,80:80%,90:90%,100:100%'
	);

	# % rated #
	my %parameterrated1 = (
			'id' => 1,
			'type' => 'list',
			'name' => 'Select percentage of rated songs',
			'definition' => '0:0%,10:10%,20:20%,30:30%,40:40%,50:50%,60:60%,70:70%,80:80%,90:90%,100:100%'
	);
	my %parameterrated2 = (
			'id' => 2,
			'type' => 'list',
			'name' => 'Select percentage of rated songs',
			'definition' => '0:0%,10:10%,20:20%,30:30%,40:40%,50:50%,60:60%,70:70%,80:80%,90:90%,100:100%'
	);
	my %parameterrated3 = (
			'id' => 3,
			'type' => 'list',
			'name' => 'Select percentage of rated songs',
			'definition' => '0:0%,10:10%,20:20%,30:30%,40:40%,50:50%,60:60%,70:70%,80:80%,90:90%,100:100%'
	);

	# genre #
	my %parametergen1 = (
			'id' => 1,
			'type' => 'genre',
			'name' => 'Select genre'
	);

	# decade #
	my %parameterdec1 = (
			'id' => 1,
			'type' => 'custom',
			'name' => 'Select decade',
			'definition' => "select cast(((tracks.year/10)*10) as int),case when tracks.year>0 then cast(((tracks.year/10)*10) as int)||'s' else 'Unknown' end from tracks where tracks.audio=1 group by cast(((tracks.year/10)*10) as int) order by tracks.year desc"
	);
	my %parameterdec2 = (
			'id' => 2,
			'type' => 'custom',
			'name' => 'Select decade',
			'definition' => "select cast(((tracks.year/10)*10) as int),case when tracks.year>0 then cast(((tracks.year/10)*10) as int)||'s' else 'Unknown' end from tracks where tracks.audio=1 group by cast(((tracks.year/10)*10) as int) order by tracks.year desc"
	);

	# % play count #
	my %parameterplaycount1 = (
			'id' => 1,
			'type' => 'list',
			'name' => 'Choose songs to include',
			'definition' => '0:all songs,1:unplayed,2:played'
	);
	my %parameterplaycount2 = (
			'id' => 2,
			'type' => 'list',
			'name' => 'Choose songs to include',
			'definition' => '0:all songs,1:unplayed,2:played'
	);
	my %parameterplaycount3 = (
			'id' => 3,
			'type' => 'list',
			'name' => 'Choose songs to include',
			'definition' => '0:all songs,1:unplayed,2:played'
	);
	my %parameterplaycount4 = (
			'id' => 4,
			'type' => 'list',
			'name' => 'Choose songs to include',
			'definition' => '0:all songs,1:unplayed,2:played'
	);

	#### playlists ###
	my %playlist1 = (
		'name' => 'Rated',
		'url' => 'plugins/RatingsLight/html/dpldesc/rated.html?dummyparam=1',
		'groups' => [['Ratings Light ']]
	);
	my %playlist2 = (
		'name' => 'Rated (with % of top rated)',
		'url' => 'plugins/RatingsLight/html/dpldesc/rated_top.html?dummyparam=1',
		'groups' => [['Ratings Light ']]
	);
	my %playlist3 = (
		'name' => 'Rated - by DECADE',
		'url' => 'plugins/RatingsLight/html/dpldesc/rated_by_decade.html?dummyparam=1',
		'groups' => [['Ratings Light ']]
	);
	my %playlist4 = (
		'name' => 'Rated - by DECADE (with % of top rated)',
		'url' => 'plugins/RatingsLight/html/dpldesc/rated_by_decade_top.html?dummyparam=1',
		'groups' => [['Ratings Light ']]
	);
	my %playlist5 = (
		'name' => 'Rated - by GENRE',
		'url' => 'plugins/RatingsLight/html/dpldesc/rated_by_genre.html?dummyparam=1',
		'groups' => [['Ratings Light ']]
	);
	my %playlist6 = (
		'name' => 'Rated - by GENRE (with % of top rated)',
		'url' => 'plugins/RatingsLight/html/dpldesc/rated_by_genre_top.html?dummyparam=1',
		'groups' => [['Ratings Light ']]
	);
	my %playlist7 = (
		'name' => 'Rated - by GENRE + DECADE',
		'url' => 'plugins/RatingsLight/html/dpldesc/rated_by_decade_and_genre.html?dummyparam=1',
		'groups' => [['Ratings Light ']]
	);
	my %playlist8 = (
		'name' => 'Rated - by GENRE + DECADE (with % of top rated)',
		'url' => 'plugins/RatingsLight/html/dpldesc/rated_by_decade_and_genre_top.html?dummyparam=1',
		'groups' => [['Ratings Light ']]
	);
	my %playlist9 = (
		'name' => 'UNrated (with % of rated songs)',
		'url' => 'plugins/RatingsLight/html/dpldesc/unrated_rated.html?dummyparam=1',
		'groups' => [['Ratings Light ']]
	);
	my %playlist10 = (
		'name' => 'UNrated by DECADE (with % of rated songs)',
		'url' => 'plugins/RatingsLight/html/dpldesc/unrated_by_decade_rated.html?dummyparam=1',
		'groups' => [['Ratings Light ']]
	);
	my %playlist11 = (
		'name' => 'UNrated by GENRE (with % of rated songs)',
		'url' => 'plugins/RatingsLight/html/dpldesc/unrated_by_genre_rated.html?dummyparam=1',
		'groups' => [['Ratings Light ']]
	);
	my %playlist12 = (
		'name' => 'UNrated by GENRE + DECADE (with % of rated songs)',
		'url' => 'plugins/RatingsLight/html/dpldesc/unrated_by_decade_and_genre_rated.html?dummyparam=1',
		'groups' => [['Ratings Light ']]
	);
	my %playlist13 = (
		'name' => 'Rated (un/played)',
		'url' => 'plugins/RatingsLight/html/dpldesc/rated_unplayed.html?dummyparam=1',
		'groups' => [['Ratings Light ']]
	);

	# Playlist1: "Rated"
	$result{'ratingslight_rated'} = \%playlist1;

	# Playlist2: "Rated (with % of top rated, un/played)"
	my %parametersPL2 = (
		1 => \%parametertop1,
		2 => \%parameterplaycount2
	);
	$playlist2{'parameters'} = \%parametersPL2;
	$result{'ratingslight_rated-with_top_percentage'} = \%playlist2;

	# Playlist3: "Rated - by DECADE (un/played)"
	my %parametersPL3 = (
		1 => \%parameterdec1,
		2 => \%parameterplaycount2
	);
	$playlist3{'parameters'} = \%parametersPL3;
	$result{'ratingslight_rated-by_decade'} = \%playlist3;

	# Playlist4: "Rated - by DECADE (with % of top rated, un/played)"
	my %parametersPL4 = (
		1 => \%parameterdec1,
		2 => \%parametertop2,
		3 => \%parameterplaycount3
	);
	$playlist4{'parameters'} = \%parametersPL4;
	$result{'ratingslight_rated-by_decade_with_top_percentage'} = \%playlist4;

	# Playlist5: "Rated - by GENRE"
	my %parametersPL5 = (
		1 => \%parametergen1,
		2 => \%parameterplaycount2
	);
	$playlist5{'parameters'} = \%parametersPL5;
	$result{'ratingslight_rated-by_genre'} = \%playlist5;

	# Playlist6: "Rated - by GENRE (with % of top rated, un/played)"
	my %parametersPL6 = (
		1 => \%parametergen1,
		2 => \%parametertop2,
		3 => \%parameterplaycount3
	);
	$playlist6{'parameters'} = \%parametersPL6;
	$result{'ratingslight_rated-by_genre_with_top_percentage'} = \%playlist6;

	# Playlist7: "Rated - by GENRE + DECADE (un/played)"
	my %parametersPL7 = (
		1 => \%parametergen1,
		2 => \%parameterdec2,
		3 => \%parameterplaycount3
	);
	$playlist7{'parameters'} = \%parametersPL7;
	$result{'ratingslight_rated-by_genre_and_decade'} = \%playlist7;

	# Playlist8: "Rated - by GENRE + DECADE (with % of top rated, un/played)"
	my %parametersPL8 = (
		1 => \%parametergen1,
		2 => \%parameterdec2,
		3 => \%parametertop3,
		4 => \%parameterplaycount4
	);
	$playlist8{'parameters'} = \%parametersPL8;
	$result{'ratingslight_rated-by_genre_and_decade_with_top_percentage'} = \%playlist8;

	# Playlist9: "UNrated (with % of rated songs, un/played)"
	my %parametersPL9 = (
		1 => \%parameterrated1,
		2 => \%parameterplaycount2,
	);
	$playlist9{'parameters'} = \%parametersPL9;
	$result{'ratingslight_unrated-with_rated_percentage'} = \%playlist9;

	# Playlist10: "UNrated by DECADE (with % of rated songs, un/played)"
	my %parametersPL10 = (
		1 => \%parameterdec1,
		2 => \%parameterrated2,
		3 => \%parameterplaycount3
	);
	$playlist10{'parameters'} = \%parametersPL10;
	$result{'ratingslight_unrated-by_decade_with_rated_percentage'} = \%playlist10;

	# Playlist11: "UNrated by GENRE (with % of rated songs, un/played)"
	my %parametersPL11 = (
		1 => \%parametergen1,
		2 => \%parameterrated2,
		3 => \%parameterplaycount3
	);
	$playlist11{'parameters'} = \%parametersPL11;
	$result{'ratingslight_unrated-by_genre_with_rated_percentage'} = \%playlist11;

	# Playlist12: "UNrated by GENRE + DECADE (with % of rated songs, un/played)"
	my %parametersPL12 = (
		1 => \%parametergen1,
		2 => \%parameterdec2,
		3 => \%parameterrated3,
		4 => \%parameterplaycount4
	);
	$playlist12{'parameters'} = \%parametersPL12;
	$result{'ratingslight_unrated-by_genre_and_decade_with_rated_percentage'} = \%playlist12;

	# Playlist13: "Rated (un/played)"
	my %parametersPL13 = (
		1 => \%parameterplaycount1
	);
	$playlist13{'parameters'} = \%parametersPL13;
	$result{'ratingslight_rated-unplayed'} = \%playlist13;

	return \%result;
}

sub getNextDynamicPlayListTracks {
	my ($client,$playlist,$limit,$offset,$parameters) = @_;
	my $clientID = $client->id;
	my $DPLid = @{$playlist}{dynamicplaylistid};
	$log->debug('DynamicPlaylist name = '.$DPLid);
	my $dstm_minTrackDuration = $prefs->get('dstm_minTrackDuration');
	my $topratedminrating = $prefs->get('topratedminrating');
	my $excludedgenrelist = getExcludedGenreList();
	$log->debug('excludedgenrelist = '.$excludedgenrelist);
	my $currentLibrary = Slim::Music::VirtualLibraries->getLibraryIdForClient($client);
	$log->debug('current client VlibID = '.$currentLibrary);

	my @result = ();
	my $sqlstatement;

	### shared sql
	# exclude comment, track min duration, DPL history, library view
	my $shared_curlib_sql = " left join comments as excludecomments on tracks.id=excludecomments.track and excludecomments.value like '%%never%%' left join dynamicplaylist_history on tracks.id=dynamicplaylist_history.id and dynamicplaylist_history.client='$clientID' left join library_track library_track on library_track.track = tracks.id where audio=1 and dynamicplaylist_history.id is null and excludecomments.id is null and library_track.library = \"$currentLibrary\" and tracks.secs >= $dstm_minTrackDuration";
	# exclude comment, track min duration, DPL history
	my $shared_completelib_sql = " left join comments as excludecomments on tracks.id=excludecomments.track and excludecomments.value like '%%never%%' left join dynamicplaylist_history on tracks.id=dynamicplaylist_history.id and dynamicplaylist_history.client='$clientID' where audio=1 and dynamicplaylist_history.id is null and excludecomments.id is null and tracks.secs >= $dstm_minTrackDuration";

	my $excludegenre_sql = " and not exists (select * from tracks t2,genre_track,genres where t2.id=tracks.id and tracks.id=genre_track.track and genre_track.genre=genres.id and genres.name in ($excludedgenrelist))";
	my $playcount_unplayed_sql = " and (tracks_persistent.playCount = 0 or tracks_persistent.playCount is null)";
	my $playcount_played_sql = " and (tracks_persistent.playCount > 0)";

	### DPL smart playlists
	# Playlist1: "Rated"
	if ($DPLid eq 'ratingslight_rated') {
		$sqlstatement = "select tracks.url from tracks join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating > 0";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit $limit;";
	}

	# Playlist2: "Rated (with % of top rated, un/played)"
	if ($DPLid eq 'ratingslight_rated-with_top_percentage') {
		my $percentagevalue = $parameters->{1}->{'value'};
		my $playcountvalue = $parameters->{2}->{'value'};
		$sqlstatement = "DROP TABLE IF EXISTS randomweightedratingshigh;
DROP TABLE IF EXISTS randomweightedratingslow;
DROP TABLE IF EXISTS randomweightedratingscombined;
create temporary table randomweightedratingslow as select tracks.url as url from tracks join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating < $topratedminrating";
		if ($playcountvalue == 1) {
			$sqlstatement .= $playcount_unplayed_sql;
		}
		if ($playcountvalue == 2) {
			$sqlstatement .= $playcount_played_sql;
		}
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}

		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit (100-$percentagevalue);
";

		$sqlstatement .= "create temporary table randomweightedratingshigh as select tracks.url as url from tracks join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating >= $topratedminrating";
		if ($playcountvalue == 1) {
			$sqlstatement .= $playcount_unplayed_sql;
		}
		if ($playcountvalue == 2) {
			$sqlstatement .= $playcount_played_sql;
		}
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}

		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit $percentagevalue;
";

		$sqlstatement .= "create temporary table randomweightedratingscombined as SELECT * FROM randomweightedratingslow UNION SELECT * from randomweightedratingshigh;
SELECT * from randomweightedratingscombined ORDER BY random() limit $limit;
DROP TABLE randomweightedratingshigh;
DROP TABLE randomweightedratingslow;
DROP TABLE randomweightedratingscombined;";
	}

	# Playlist3: "Rated - by DECADE (un/played)"
	if ($DPLid eq 'ratingslight_rated-by_decade') {
		my $decade = $parameters->{1}->{'value'};
		my $playcountvalue = $parameters->{2}->{'value'};
		$sqlstatement = "select tracks.url from tracks join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating > 0";
		if ($playcountvalue == 1) {
			$sqlstatement .= $playcount_unplayed_sql;
		}
		if ($playcountvalue == 2) {
			$sqlstatement .= $playcount_played_sql;
		}
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		$sqlstatement .= " and tracks.year>=$decade and tracks.year<$decade+10";

		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit $limit;";
	}

	# Playlist4: "Rated - by DECADE (with % of top rated, un/played)"
	if ($DPLid eq 'ratingslight_rated-by_decade_with_top_percentage') {
		my $decade = $parameters->{1}->{'value'};
		my $percentagevalue = $parameters->{2}->{'value'};
		my $playcountvalue = $parameters->{3}->{'value'};
		$sqlstatement = "DROP TABLE IF EXISTS randomweightedratingshigh;
DROP TABLE IF EXISTS randomweightedratingslow;
DROP TABLE IF EXISTS randomweightedratingscombined;
create temporary table randomweightedratingslow as select tracks.url as url from tracks join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating < $topratedminrating";
		if ($playcountvalue == 1) {
			$sqlstatement .= $playcount_unplayed_sql;
		}
		if ($playcountvalue == 2) {
			$sqlstatement .= $playcount_played_sql;
		}
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		$sqlstatement .= " and tracks.year>=$decade and tracks.year<$decade+10";

		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit (100-$percentagevalue);
";

		$sqlstatement .= "create temporary table randomweightedratingshigh as select tracks.url as url from tracks join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating >= $topratedminrating";
		if ($playcountvalue == 1) {
			$sqlstatement .= $playcount_unplayed_sql;
		}
		if ($playcountvalue == 2) {
			$sqlstatement .= $playcount_played_sql;
		}
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		$sqlstatement .= " and tracks.year>=$decade and tracks.year<$decade+10";

		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit $percentagevalue;
";

		$sqlstatement .= "create temporary table randomweightedratingscombined as SELECT * FROM randomweightedratingslow UNION SELECT * from randomweightedratingshigh;
SELECT * from randomweightedratingscombined ORDER BY random()limit $limit;
DROP TABLE randomweightedratingshigh;
DROP TABLE randomweightedratingslow;
DROP TABLE randomweightedratingscombined;";
	}

	# Playlist5: "Rated - by GENRE (un/played)"
	if ($DPLid eq 'ratingslight_rated-by_genre') {
		my $genre = $parameters->{1}->{'value'};
		my $playcountvalue = $parameters->{2}->{'value'};
		$sqlstatement = "select tracks.url from tracks join genre_track on tracks.id=genre_track.track join genres on genre_track.genre=genres.id and genre_track.genre=$genre join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating > 0";
		if ($playcountvalue == 1) {
			$sqlstatement .= $playcount_unplayed_sql;
		}
		if ($playcountvalue == 2) {
			$sqlstatement .= $playcount_played_sql;
		}
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit $limit;";
	}

	# Playlist6: "Rated - by GENRE (with % of top rated, un/played)"
	if ($DPLid eq 'ratingslight_rated-by_genre_with_top_percentage') {
		my $genre = $parameters->{1}->{'value'};
		my $percentagevalue = $parameters->{2}->{'value'};
		my $playcountvalue = $parameters->{3}->{'value'};
		$sqlstatement = "DROP TABLE IF EXISTS randomweightedratingshigh;
DROP TABLE IF EXISTS randomweightedratingslow;
DROP TABLE IF EXISTS randomweightedratingscombined;
create temporary table randomweightedratingslow as select tracks.url as url from tracks join genre_track on tracks.id=genre_track.track join genres on genre_track.genre=genres.id and genre_track.genre=$genre join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating < $topratedminrating";
		if ($playcountvalue == 1) {
			$sqlstatement .= $playcount_unplayed_sql;
		}
		if ($playcountvalue == 2) {
			$sqlstatement .= $playcount_played_sql;
		}
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		$sqlstatement .= " order by random() limit (100-$percentagevalue);
create temporary table randomweightedratingshigh as select tracks.url as url from tracks join genre_track on tracks.id=genre_track.track join genres on genre_track.genre=genres.id and genre_track.genre=$genre join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating >= $topratedminrating";
		if ($playcountvalue == 1) {
			$sqlstatement .= $playcount_unplayed_sql;
		}
		if ($playcountvalue == 2) {
			$sqlstatement .= $playcount_played_sql;
		}
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		$sqlstatement .= " order by random() limit $percentagevalue;
create temporary table randomweightedratingscombined as SELECT * FROM randomweightedratingslow UNION SELECT * from randomweightedratingshigh;
SELECT * from randomweightedratingscombined ORDER BY random() limit $limit;
DROP TABLE randomweightedratingshigh;
DROP TABLE randomweightedratingslow;
DROP TABLE randomweightedratingscombined;";
	}

	# Playlist7: "Rated - by GENRE + DECADE, un/played"
	if ($DPLid eq 'ratingslight_rated-by_genre_and_decade') {
		my $genre = $parameters->{1}->{'value'};
		my $decade = $parameters->{2}->{'value'};
		my $playcountvalue = $parameters->{3}->{'value'};
		$sqlstatement = "select tracks.url from tracks join genre_track on tracks.id=genre_track.track join genres on genre_track.genre=genres.id and genre_track.genre=$genre join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating > 0";
		if ($playcountvalue == 1) {
			$sqlstatement .= $playcount_unplayed_sql;
		}
		if ($playcountvalue == 2) {
			$sqlstatement .= $playcount_played_sql;
		}
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		$sqlstatement .= " and tracks.year>=$decade and tracks.year<$decade+10 group by tracks.id order by random() limit $limit;";
	}

	# Playlist8: "Rated - by GENRE + DECADE (with % of top rated, un/played)"
	if ($DPLid eq 'ratingslight_rated-by_genre_and_decade_with_top_percentage') {
		my $genre = $parameters->{1}->{'value'};
		my $decade = $parameters->{2}->{'value'};
		my $percentagevalue = $parameters->{3}->{'value'};
		my $playcountvalue = $parameters->{4}->{'value'};
		$sqlstatement = "DROP TABLE IF EXISTS randomweightedratingshigh;
DROP TABLE IF EXISTS randomweightedratingslow;
DROP TABLE IF EXISTS randomweightedratingscombined;
create temporary table randomweightedratingslow as select tracks.url as url from tracks join genre_track on tracks.id=genre_track.track join genres on genre_track.genre=genres.id and genre_track.genre=$genre join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating < $topratedminrating";
		if ($playcountvalue == 1) {
			$sqlstatement .= $playcount_unplayed_sql;
		}
		if ($playcountvalue == 2) {
			$sqlstatement .= $playcount_played_sql;
		}
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		$sqlstatement .= " and tracks.year>=$decade and tracks.year<$decade+10 order by random() limit (100-$percentagevalue);
create temporary table randomweightedratingshigh as select tracks.url as url from tracks join genre_track on tracks.id=genre_track.track join genres on genre_track.genre=genres.id and genre_track.genre=$genre join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating >= $topratedminrating";
		if ($playcountvalue == 1) {
			$sqlstatement .= $playcount_unplayed_sql;
		}
		if ($playcountvalue == 2) {
			$sqlstatement .= $playcount_played_sql;
		}
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		$sqlstatement .= " and tracks.year>=$decade and tracks.year<$decade+10 order by random() limit $percentagevalue;
create temporary table randomweightedratingscombined as SELECT * FROM randomweightedratingslow UNION SELECT * from randomweightedratingshigh;
SELECT * from randomweightedratingscombined ORDER BY random() limit $limit;
DROP TABLE randomweightedratingshigh;
DROP TABLE randomweightedratingslow;
DROP TABLE randomweightedratingscombined;";
	}

	# Playlist9: "UNrated (with % of RATED Songs, un/played)"
	if ($DPLid eq 'ratingslight_unrated-with_rated_percentage') {
		my $percentagevalue = $parameters->{1}->{'value'};
		my $playcountvalue = $parameters->{2}->{'value'};
		$sqlstatement = "DROP TABLE IF EXISTS randomweightedratingsrated;
DROP TABLE IF EXISTS randomweightedratingsunrated;
DROP TABLE IF EXISTS randomweightedratingscombined;
create temporary table randomweightedratingsunrated as select tracks.url as url from tracks join tracks_persistent on tracks.url=tracks_persistent.url and (tracks_persistent.rating = 0 or tracks_persistent.rating is null)";
		if ($playcountvalue == 1) {
			$sqlstatement .= $playcount_unplayed_sql;
		}
		if ($playcountvalue == 2) {
			$sqlstatement .= $playcount_played_sql;
		}
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}

		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit (100-$percentagevalue);
";

		$sqlstatement .= "create temporary table randomweightedratingsrated as select tracks.url as url from tracks join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating > 0";
		if ($playcountvalue == 1) {
			$sqlstatement .= $playcount_unplayed_sql;
		}
		if ($playcountvalue == 2) {
			$sqlstatement .= $playcount_played_sql;
		}
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}

		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit $percentagevalue;
";

		$sqlstatement .= "create temporary table randomweightedratingscombined as SELECT * FROM randomweightedratingsunrated UNION SELECT * from randomweightedratingsrated;
SELECT * from randomweightedratingscombined ORDER BY random() limit $limit;
DROP TABLE randomweightedratingsrated;
DROP TABLE randomweightedratingsunrated;
DROP TABLE randomweightedratingscombined;";
	}

	# Playlist10: "UNrated by DECADE (with % of RATED Songs, un/played)"
	if ($DPLid eq 'ratingslight_unrated-by_decade_with_rated_percentage') {
		my $decade = $parameters->{1}->{'value'};
		my $percentagevalue = $parameters->{2}->{'value'};
		my $playcountvalue = $parameters->{3}->{'value'};
		$sqlstatement = "DROP TABLE IF EXISTS randomweightedratingsrated;
DROP TABLE IF EXISTS randomweightedratingsunrated;
DROP TABLE IF EXISTS randomweightedratingscombined;
create temporary table randomweightedratingsunrated as select tracks.url as url from tracks join tracks_persistent on tracks.url=tracks_persistent.url and (tracks_persistent.rating = 0 or tracks_persistent.rating is null)";
		if ($playcountvalue == 1) {
			$sqlstatement .= $playcount_unplayed_sql;
		}
		if ($playcountvalue == 2) {
			$sqlstatement .= $playcount_played_sql;
		}
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		$sqlstatement .= " and tracks.year>=$decade and tracks.year<$decade+10";

		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit (100-$percentagevalue);
";

		$sqlstatement .= "create temporary table randomweightedratingsrated as select tracks.url as url from tracks join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating > 0";
		if ($playcountvalue == 1) {
			$sqlstatement .= $playcount_unplayed_sql;
		}
		if ($playcountvalue == 2) {
			$sqlstatement .= $playcount_played_sql;
		}
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		$sqlstatement .= " and tracks.year>=$decade and tracks.year<$decade+10";

		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit $percentagevalue;
";

		$sqlstatement .= "create temporary table randomweightedratingscombined as SELECT * FROM randomweightedratingsunrated UNION SELECT * from randomweightedratingsrated;
SELECT * from randomweightedratingscombined ORDER BY random() limit $limit;
DROP TABLE randomweightedratingsrated;
DROP TABLE randomweightedratingsunrated;
DROP TABLE randomweightedratingscombined;";
	}

	# Playlist11: "UNrated by GENRE (with % of RATED songs, un/played)"
	if ($DPLid eq 'ratingslight_unrated-by_genre_with_rated_percentage') {
		my $genre = $parameters->{1}->{'value'};
		my $percentagevalue = $parameters->{2}->{'value'};
		my $playcountvalue = $parameters->{3}->{'value'};
		$sqlstatement = "DROP TABLE IF EXISTS randomweightedratingsrated;
DROP TABLE IF EXISTS randomweightedratingsunrated;
DROP TABLE IF EXISTS randomweightedratingscombined;
create temporary table randomweightedratingsunrated as select tracks.url as url from tracks join genre_track on tracks.id=genre_track.track join genres on genre_track.genre=genres.id and genre_track.genre=$genre join tracks_persistent on tracks.url=tracks_persistent.url and (tracks_persistent.rating = 0 or tracks_persistent.rating is null)";
		if ($playcountvalue == 1) {
			$sqlstatement .= $playcount_unplayed_sql;
		}
		if ($playcountvalue == 2) {
			$sqlstatement .= $playcount_played_sql;
		}
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		$sqlstatement .= " order by random() limit (100-$percentagevalue);
create temporary table randomweightedratingsrated as select tracks.url as url from tracks join genre_track on tracks.id=genre_track.track join genres on genre_track.genre=genres.id and genre_track.genre=$genre join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating > 0";
		if ($playcountvalue == 1) {
			$sqlstatement .= $playcount_unplayed_sql;
		}
		if ($playcountvalue == 2) {
			$sqlstatement .= $playcount_played_sql;
		}
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		$sqlstatement .= " order by random() limit $percentagevalue;
create temporary table randomweightedratingscombined as SELECT * FROM randomweightedratingsunrated UNION SELECT * from randomweightedratingsrated;
SELECT * from randomweightedratingscombined ORDER BY random() limit $limit;
DROP TABLE randomweightedratingsrated;
DROP TABLE randomweightedratingsunrated;
DROP TABLE randomweightedratingscombined;";
	}

	# Playlist12: "UNrated by GENRE + DECADE (with % of RATED songs, un/played)"
	if ($DPLid eq 'ratingslight_unrated-by_genre_and_decade_with_rated_percentage') {
		my $genre = $parameters->{1}->{'value'};
		my $decade = $parameters->{2}->{'value'};
		my $percentagevalue = $parameters->{3}->{'value'};
		my $playcountvalue = $parameters->{4}->{'value'};
		$sqlstatement = "DROP TABLE IF EXISTS randomweightedratingsrated;
DROP TABLE IF EXISTS randomweightedratingsunrated;
DROP TABLE IF EXISTS randomweightedratingscombined;
create temporary table randomweightedratingsunrated as select tracks.url as url from tracks join genre_track on tracks.id=genre_track.track join genres on genre_track.genre=genres.id and genre_track.genre=$genre join tracks_persistent on tracks.url=tracks_persistent.url and (tracks_persistent.rating = 0 or tracks_persistent.rating is null)";
		if ($playcountvalue == 1) {
			$sqlstatement .= $playcount_unplayed_sql;
		}
		if ($playcountvalue == 2) {
			$sqlstatement .= $playcount_played_sql;
		}
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		$sqlstatement .= " and tracks.year>=$decade and tracks.year<$decade+10 order by random() limit (100-$percentagevalue);
create temporary table randomweightedratingsrated as select tracks.url as url from tracks join genre_track on tracks.id=genre_track.track join genres on genre_track.genre=genres.id and genre_track.genre=$genre join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating > 0";
		if ($playcountvalue == 1) {
			$sqlstatement .= $playcount_unplayed_sql;
		}
		if ($playcountvalue == 2) {
			$sqlstatement .= $playcount_played_sql;
		}
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		$sqlstatement .= " and tracks.year>=$decade and tracks.year<$decade+10 order by random() limit $percentagevalue;
create temporary table randomweightedratingscombined as SELECT * FROM randomweightedratingsunrated UNION SELECT * from randomweightedratingsrated;
SELECT * from randomweightedratingscombined ORDER BY random() limit $limit;
DROP TABLE randomweightedratingsrated;
DROP TABLE randomweightedratingsunrated;
DROP TABLE randomweightedratingscombined;";
	}

	# Playlist13: "Rated (un/played)"
	if ($DPLid eq 'ratingslight_rated-unplayed') {
		my $playcountvalue = $parameters->{1}->{'value'};
		$sqlstatement = "select tracks.url from tracks join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating > 0";
		if ($playcountvalue == 1) {
			$sqlstatement .= $playcount_unplayed_sql;
		}
		if ($playcountvalue == 2) {
			$sqlstatement .= $playcount_played_sql;
		}
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}

		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit $limit;";
	}

	my $dbh = getCurrentDBH();
	for my $sql (split(/[\n\r]/,$sqlstatement)) {
		eval {
			my $sth = $dbh->prepare($sql);
			$sth->execute() or do {
				$sql = undef;
			};
			if ($sql =~ /^\(*SELECT+/oi) {
				my $trackURL;
				$sth->bind_col(1,\$trackURL);

				while ($sth->fetch()) {
					my $track = Slim::Schema->resultset('Track')->objectForUrl($trackURL);
					push @result,$track;
				}
			}
			$sth->finish();
		};
	}
	my $trackcount = scalar(@result);
	$log->debug('RL Dynamic Playlist: tracks found = '.$trackcount);
	return \@result;
}

sub dontStopTheMusic {
	my ($mixtype, $client, $cb) = @_;
	return unless $client;
	$log->debug('DSTM mixtype = '.$mixtype);

	my $topratedminrating = $prefs->get('topratedminrating');
	my $tracks = [];
	my $sql_limit = 30;

	my $excludedgenrelist = getExcludedGenreList();
	$log->debug('excludedgenrelist = '.$excludedgenrelist);
	my $dstm_minTrackDuration = $prefs->get('dstm_minTrackDuration');
	my $dstm_percentagerated = $prefs->get('dstm_percentagerated');
	my $dstm_percentagetoprated = $prefs->get('dstm_percentagetoprated');
	my $currentLibrary = Slim::Music::VirtualLibraries->getLibraryIdForClient($client);
	$log->debug('current client VlibID = '.$currentLibrary);

	my $sqlstatement;

	### shared sql
	# exclude comment, track min duration, library view
	my $shared_curlib_sql = " left join comments as excludecomments on tracks.id=excludecomments.track and excludecomments.value like '%%never%%' left join library_track library_track on library_track.track = tracks.id where audio=1 and excludecomments.id is null and library_track.library = \"$currentLibrary\" and tracks.secs >= $dstm_minTrackDuration";
	# exclude comment, track min duration
	my $shared_completelib_sql = " left join comments as excludecomments on tracks.id=excludecomments.track and excludecomments.value like '%%never%%' where audio=1 and excludecomments.id is null and tracks.secs >= $dstm_minTrackDuration";
	# excluded genres
	my $excludegenre_sql = " and not exists (select * from tracks t2,genre_track,genres where t2.id=tracks.id and tracks.id=genre_track.track and genre_track.genre=genres.id and genres.name in ($excludedgenrelist))";

	### Mix sql
	# Mix: Rated
	if ($mixtype eq 'rated') {
		$sqlstatement = "select tracks.url from tracks join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating > 0";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit $sql_limit;";
	}

	# Mix: "Rated (with % of top rated)"
	if ($mixtype eq 'rated_toprated') {
		$sqlstatement = "DROP TABLE IF EXISTS randomweightedratingshigh;
DROP TABLE IF EXISTS randomweightedratingslow;
DROP TABLE IF EXISTS randomweightedratingscombined;
";
		$sqlstatement .="create temporary table randomweightedratingslow as select tracks.url as url from tracks join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating < $topratedminrating";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit (100-$dstm_percentagetoprated);
";

		$sqlstatement .= "create temporary table randomweightedratingshigh as select tracks.url as url from tracks join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating >= $topratedminrating";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit $dstm_percentagetoprated;
";
		$sqlstatement .= "create temporary table randomweightedratingscombined as SELECT * FROM randomweightedratingslow UNION SELECT * from randomweightedratingshigh;
SELECT * from randomweightedratingscombined ORDER BY random() limit $sql_limit;
DROP TABLE randomweightedratingshigh;
DROP TABLE randomweightedratingslow;
DROP TABLE randomweightedratingscombined;";
	}

	# Mix: "Rated (seed genres)"
	if ($mixtype eq 'rated_genre') {
		my $dstm_includegenres = getSeedGenres($client);
		$sqlstatement = "select tracks.url from tracks join genre_track on tracks.id=genre_track.track join genres on genre_track.genre=genres.id and genre_track.genre in ($dstm_includegenres) join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating > 0";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit $sql_limit;";
	}

	# Mix: "Rated (seed genres with % of top rated)"
	if ($mixtype eq 'rated_genre_toprated') {
		my $dstm_includegenres = getSeedGenres($client);
		$sqlstatement = "DROP TABLE IF EXISTS randomweightedratingshigh;
DROP TABLE IF EXISTS randomweightedratingslow;
DROP TABLE IF EXISTS randomweightedratingscombined;
create temporary table randomweightedratingslow as select tracks.url as url from tracks join genre_track on tracks.id=genre_track.track join genres on genre_track.genre=genres.id and genre_track.genre in ($dstm_includegenres) join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating < $topratedminrating";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit (100-$dstm_percentagetoprated);
";
		$sqlstatement .="create temporary table randomweightedratingshigh as select tracks.url as url from tracks join genre_track on tracks.id=genre_track.track join genres on genre_track.genre=genres.id and genre_track.genre in ($dstm_includegenres) join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating >= $topratedminrating";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit $dstm_percentagetoprated;
";
		$sqlstatement .= "create temporary table randomweightedratingscombined as SELECT * FROM randomweightedratingslow UNION SELECT * from randomweightedratingshigh;
SELECT * from randomweightedratingscombined ORDER BY random() limit $sql_limit;
DROP TABLE randomweightedratingshigh;
DROP TABLE randomweightedratingslow;
DROP TABLE randomweightedratingscombined;";
	}

	# Mix: "Unrated (with % of rated songs)"
	if ($mixtype eq 'unrated_rated') {
		$sqlstatement = "DROP TABLE IF EXISTS randomweightedratingsrated;
DROP TABLE IF EXISTS randomweightedratingsunrated;
DROP TABLE IF EXISTS randomweightedratingscombined;
create temporary table randomweightedratingsunrated as select tracks.url as url from tracks join tracks_persistent on tracks.url=tracks_persistent.url and (tracks_persistent.rating = 0 or tracks_persistent.rating is null)";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit (100-$dstm_percentagerated);
";

		$sqlstatement .= "create temporary table randomweightedratingsrated as select tracks.url as url from tracks join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating > 0";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit $dstm_percentagerated;
";
		$sqlstatement .= "create temporary table randomweightedratingscombined as SELECT * FROM randomweightedratingsunrated UNION SELECT * from randomweightedratingsrated;
SELECT * from randomweightedratingscombined ORDER BY random() limit $sql_limit;
DROP TABLE randomweightedratingsrated;
DROP TABLE randomweightedratingsunrated;
DROP TABLE randomweightedratingscombined;";
	}

	# Mix: "Unrated (seed genres with % of rated songs)"
	if ($mixtype eq 'unrated_rated_genre') {
		my $dstm_includegenres = getSeedGenres($client);
		$sqlstatement = "DROP TABLE IF EXISTS randomweightedratingsrated;
DROP TABLE IF EXISTS randomweightedratingsunrated;
DROP TABLE IF EXISTS randomweightedratingscombined;
create temporary table randomweightedratingsunrated as select tracks.url as url from tracks join genre_track on tracks.id=genre_track.track join genres on genre_track.genre=genres.id and genre_track.genre in ($dstm_includegenres) join tracks_persistent on tracks.url=tracks_persistent.url and (tracks_persistent.rating = 0 or tracks_persistent.rating is null)";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit (100-$dstm_percentagerated);
";

		$sqlstatement .= "create temporary table randomweightedratingsrated as select tracks.url as url from tracks join genre_track on tracks.id=genre_track.track join genres on genre_track.genre=genres.id and genre_track.genre in ($dstm_includegenres) join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating > 0";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit $dstm_percentagerated;
";
		$sqlstatement .= "create temporary table randomweightedratingscombined as SELECT * FROM randomweightedratingsunrated UNION SELECT * from randomweightedratingsrated;
SELECT * from randomweightedratingscombined ORDER BY random() limit $sql_limit;
DROP TABLE randomweightedratingsrated;
DROP TABLE randomweightedratingsunrated;
DROP TABLE randomweightedratingscombined;";
	}

	# Mix: "Unrated (unplayed, with % of rated songs)"
	if ($mixtype eq 'unrated_rated_unplayed') {
		$sqlstatement = "DROP TABLE IF EXISTS randomweightedratingsrated;
DROP TABLE IF EXISTS randomweightedratingsunrated;
DROP TABLE IF EXISTS randomweightedratingscombined;
create temporary table randomweightedratingsunrated as select tracks.url as url from tracks join tracks_persistent on tracks.url=tracks_persistent.url and (tracks_persistent.rating = 0 or tracks_persistent.rating is null) and (tracks_persistent.playCount = 0 or tracks_persistent.playCount is null)";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit (100-$dstm_percentagerated);
";

		$sqlstatement .= "create temporary table randomweightedratingsrated as select tracks.url as url from tracks join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating > 0 and (tracks_persistent.playCount = 0 or tracks_persistent.playCount is null)";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit $dstm_percentagerated;
";
		$sqlstatement .= "create temporary table randomweightedratingscombined as SELECT * FROM randomweightedratingsunrated UNION SELECT * from randomweightedratingsrated;
SELECT * from randomweightedratingscombined ORDER BY random() limit $sql_limit;
DROP TABLE randomweightedratingsrated;
DROP TABLE randomweightedratingsunrated;
DROP TABLE randomweightedratingscombined;";
	}

	# Mix: "Unrated (unplayed, seed genres with % of rated songs)"
	if ($mixtype eq 'unrated_rated_unplayed_genre') {
		my $dstm_includegenres = getSeedGenres($client);
		$sqlstatement = "DROP TABLE IF EXISTS randomweightedratingsrated;
DROP TABLE IF EXISTS randomweightedratingsunrated;
DROP TABLE IF EXISTS randomweightedratingscombined;
create temporary table randomweightedratingsunrated as select tracks.url as url from tracks join genre_track on tracks.id=genre_track.track join genres on genre_track.genre=genres.id and genre_track.genre in ($dstm_includegenres) join tracks_persistent on tracks.url=tracks_persistent.url and (tracks_persistent.rating = 0 or tracks_persistent.rating is null) and (tracks_persistent.playCount = 0 or tracks_persistent.playCount is null)";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit (100-$dstm_percentagerated);
";

		$sqlstatement .= "create temporary table randomweightedratingsrated as select tracks.url as url from tracks join genre_track on tracks.id=genre_track.track join genres on genre_track.genre=genres.id and genre_track.genre in ($dstm_includegenres) join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating > 0 and (tracks_persistent.playCount = 0 or tracks_persistent.playCount is null)";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit $dstm_percentagerated;
";
		$sqlstatement .= "create temporary table randomweightedratingscombined as SELECT * FROM randomweightedratingsunrated UNION SELECT * from randomweightedratingsrated;
SELECT * from randomweightedratingscombined ORDER BY random() limit $sql_limit;
DROP TABLE randomweightedratingsrated;
DROP TABLE randomweightedratingsunrated;
DROP TABLE randomweightedratingscombined;";
	}

	my $dbh = getCurrentDBH();
	for my $sql (split(/[\n\r]/,$sqlstatement)) {
		eval {
			my $sth = $dbh->prepare($sql);
			$sth->execute() or do {
				$sql = undef;
			};
			if ($sql =~ /^\(*SELECT+/oi) {
				my $trackURL;
				$sth->bind_col(1,\$trackURL);

				while ($sth->fetch()) {
					my $track = Slim::Schema->resultset('Track')->objectForUrl($trackURL);
					push @{$tracks}, $track;
				}
			}
			$sth->finish();
		};
	}
	my $tracksfound = scalar @{$tracks} || 0;
	$log->debug('RL DSTM - tracks found/used: '.$tracksfound);
	# Prune previously played playlist tracks
	my $songIndex = Slim::Player::Source::streamingSongIndex($client);
	my $songsToKeep = 5;
	if ($songIndex && $songsToKeep ne '') {
		for (my $i = 0; $i < $songIndex - $songsToKeep; $i++) {
			my $request = $client->execute(['playlist', 'delete', 0]);
			$request->source('PLUGIN_RATINGSLIGHT');
		}
	}

	$cb->($client, $tracks);
}

sub getSeedGenres {
	my $client = shift;
	my $num_seedtracks = $prefs->get('num_seedtracks');
	my $seedTracks = Slim::Plugin::DontStopTheMusic::Plugin->getMixableProperties($client, $num_seedtracks);

	if ($seedTracks && ref $seedTracks && scalar @{$seedTracks}) {
		my @seedIDs = ();
		my @seedsToUse = ();
		foreach my $seedTrack (@{$seedTracks}) {
			my ($trackObj) = Slim::Schema->find('Track', $seedTrack->{id});
			if ($trackObj) {
				push @seedsToUse, $trackObj;
				push @seedIDs, $seedTrack->{id};
			}
		}

		if (scalar @seedsToUse > 0) {
			my $genrelist;
			foreach my $thisID (@seedIDs) {
				my $track = Slim::Schema->resultset('Track')->find($thisID);
				my $thisgenreid = $track->genre->id;
				$log->debug('seed genrename = '.$track->genre->name.' -- genre ID: '.$thisgenreid);
				push @{$genrelist},$thisgenreid;
			}
			my @filteredgenrelist = sort (uniq(@{$genrelist}));

			my $includedgenrelist = '';
			foreach my $thisincludedgenre (@filteredgenrelist) {
				if ($includedgenrelist eq '') {
					$includedgenrelist = $thisincludedgenre;
				} else {
					$includedgenrelist = $includedgenrelist.','.$thisincludedgenre;
				}
			}
			return $includedgenrelist;
		}
	}
}


######  helpers  ######

sub writeRatingToDB {
	my ($trackURL, $rating100ScaleValue, $logthis) = @_;

	if (($rating100ScaleValue < 0) || ($rating100ScaleValue > 100)) {
		$rating100ScaleValue = ratingSanityCheck($rating100ScaleValue);
	}

	unless (defined $logthis) {
		my $userecentlyaddedplaylist = $prefs->get('userecentlyaddedplaylist');
		my $uselogfile = $prefs->get('uselogfile');
		if (defined $userecentlyaddedplaylist) {
			addToRecentlyRatedPlaylist($trackURL);
		}
		if (defined $uselogfile) {
			logRatedTrack($trackURL, $rating100ScaleValue);
		}
	}

	my $urlmd5 = md5_hex($trackURL);
	my $sql = "UPDATE tracks_persistent set rating=$rating100ScaleValue where urlmd5 = ?";
	my $dbh = getCurrentDBH();
	my $sth = $dbh->prepare($sql);
	eval {
		$sth->bind_param(1, $urlmd5);
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

sub getRatingFromDB {
	my $track = shift;
	my $rating = 0;

	if (Slim::Music::Import->stillScanning) {
		$log->warn('Warning: access to rating values blocked until library scan is completed');
		return $rating;
	}

	if (!blessed($track)) {
		$log->debug('track is not blessed');
		$track = Slim::Schema->rs('Track')->find($track);
	}

	my $thisrating = $track->rating;
	if (defined $thisrating) {
		$rating = $thisrating;
	}
	return $rating;
}

sub getRatingTextLine {
	my $rating = shift;
	my $appended = shift;
	my $displayratingchar = $prefs->get('displayratingchar'); # 0 = common text star *, 1 = blackstar 2605
	my $ratingchar = ' *';
	my $fractionchar = HTML::Entities::decode_entities('&#xbd;'); # "vulgar fraction one half" - HTML Entity (hex): &#xbd;

	if ($displayratingchar == 1) {
		$ratingchar = HTML::Entities::decode_entities('&#x2605;'); # "blackstar" - HTML Entity (hex): &#x2605;
	}
	my $text = string('PLUGIN_RATINGSLIGHT_UNRATED');

	if ($rating > 0) {
		my $detecthalfstars = ($rating/2)%2;
		my $ratingstars = $rating/20;
		my $spacechar = ' ';
		my $maxlength = 22;
		my $spacescount = 0;

		if ($detecthalfstars == 1) {
			$ratingstars = floor($ratingstars);
			if ($displayratingchar == 1) {
				$text = ($ratingchar x $ratingstars).$fractionchar;
			} else {
				$text = ($ratingchar x $ratingstars).' '.$fractionchar;
			}
		} else {
			$text = ($ratingchar x $ratingstars);
		}
	}
	if (defined $appended) {
		if ($displayratingchar == 1) {
			my $sepchar = HTML::Entities::decode_entities('&#x2022;'); # "bullet" - HTML Entity (hex): &#x2022;
			$text = ' '.$sepchar.' '.$text;
		} else {
			$text = ' ('.$text.' )';
		}
	}
	return $text;
}

sub getExcludedGenreList {
	my $excludegenres_namelist = $prefs->get('excludegenres_namelist');
	my $excludedgenreString = '';
	if ((defined $excludegenres_namelist) && (scalar @{$excludegenres_namelist} > 0)) {
		foreach my $thisgenre (@{$excludegenres_namelist}) {
			if ($excludedgenreString eq '') {
				$excludedgenreString = "'".$thisgenre."'";
			} else {
				$excludedgenreString = $excludedgenreString.", '".$thisgenre."'";
			}
		}
	}
	return $excludedgenreString;
}

# title format

sub getTitleFormat_Rating {
	my $track = shift;
	my $appended = shift;
	my $ratingtext = HTML::Entities::decode_entities('&#xa0;'); # "NO-BREAK SPACE" - HTML Entity (hex): &#xa0;
	my $rating100ScaleValue = 0;
	$rating100ScaleValue = getRatingFromDB($track);
	if ($rating100ScaleValue > 0) {
		if (defined $appended) {
			$ratingtext = getRatingTextLine($rating100ScaleValue, 'appended');
		} else {
			$ratingtext = getRatingTextLine($rating100ScaleValue);
		}
	}
	return $ratingtext;
}

sub getTitleFormat_Rating_AppendedStars {
	my $track = shift;
	my $ratingtext = getTitleFormat_Rating($track, 'appended');
	return $ratingtext;
}

sub addTitleFormat {
	my $titleformat = shift;
	my $titleFormats = $serverPrefs->get('titleFormat');
	foreach my $format (@{$titleFormats}) {
		if ($titleformat eq $format) {
			return;
		}
	}
	push @{$titleFormats},$titleformat;
	$serverPrefs->set('titleFormat',$titleFormats);
}

sub refreshTitleFormats {
	for my $client (Slim::Player::Client::clients()) {
		next unless $client && $client->controller();
		$client->currentPlaylistUpdateTime(Time::HiRes::time());
	}
}

# Custom Skip

sub getCustomSkipFilterTypes {
	my @result = ();
	my %rated = (
		'id' => 'ratingslight_rated',
		'name' => 'Rated low',
		'description' => 'Skip tracks with ratings below specified value',
		'mixtype' => 'track',
		'parameters' => [
			{
				'id' => 'rating',
				'type' => 'singlelist',
				'name' => 'Skip if rated less than',
				'data' => '20=*,40=**,60=***,80=****,100=*****',
				'value' => 60
			}
		]
	);
	push @result, \%rated;

	my %notrated = (
		'id' => 'ratingslight_notrated',
		'name' => 'Not rated',
		'description' => 'Skip tracks without a rating',
		'mixtype' => 'track'
	);
	push @result, \%notrated;

	return \@result;
}

sub checkCustomSkipFilterType {
	my $client = shift;
	my $filter = shift;
	my $track = shift;

	my $parameters = $filter->{'parameter'};

	if ($filter->{'id'} eq 'ratingslight_rated') {
		my $rating100ScaleValue = getRatingFromDB($track);
		for my $parameter (@{$parameters}) {
			if ($parameter->{'id'} eq 'rating') {
				my $ratings = $parameter->{'value'};
				my $rating = $ratings->[0] if (defined($ratings) && scalar(@{$ratings})>0);
				if ($rating100ScaleValue < $rating) {
					return 1;
				}
				last;
			}
		}
	}elsif ($filter->{'id'} eq 'ratingslight_notrated') {
		my $rating100ScaleValue = getRatingFromDB($track);
		if ($rating100ScaleValue == 0) {
			return 1;
		}
	}
	return 0;
}

# misc

sub isTimeOrEmpty {
	my $name = shift;
	my $arg = shift;
	if (!$arg || $arg eq '') {
		return 1;
	}elsif ($arg =~ m/^([0\s]?[0-9]|1[0-9]|2[0-4]):([0-5][0-9])\s*(P|PM|A|AM)?$/isg) {
		return 1;
	}
	return 0;
}

sub ratingSanityCheck {
	my $rating = shift;
	if ((!defined $rating) || ($rating < 0)) {
		return 0;
	}
	if ($rating > 100) {
		return 100;
	}
	return $rating;
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

sub parse_duration {
	use integer;
	sprintf("%02dh:%02dm", $_[0]/3600, $_[0]/60%60);
}

sub trimString {
	my ($thisString, $maxlength) = @_;
	if (length($thisString) > $maxlength) {
		$thisString = substr($thisString, 0, $maxlength).'...';
	}
	return $thisString;
}

sub getClientModel {
	my $client = shift;
	unless (!defined($client)) {
		my $model = Slim::Player::Client::getClient($client->id)->model;
		return $model;
	}
	return '';
}

sub uniq {
	my %seen;
	grep !$seen{$_}++, @_;
}

*escape = \&URI::Escape::uri_escape_utf8;

sub unescape {
	my $in = shift;
	my $isParam = shift;

	$in =~ s/\+/ /g if $isParam;
	$in =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;

	return $in;
}

1;
