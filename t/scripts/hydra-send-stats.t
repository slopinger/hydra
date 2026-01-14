use feature 'unicode_strings';
use strict;
use warnings;
use Setup;
use Hydra::Helper::Exec;

my %ctx = test_init();

require Hydra::Schema;
require Hydra::Model::DB;

use Test2::V0;

my $db = Hydra::Model::DB->new;
hydra_setup($db);

my ($res, $stdout, $stderr) = captureStdoutStderr(60, ("hydra-send-stats", "--once"));
is($stdout, "", "hydra-send-stats stdout should be empty");

# Remove `unknown setting` warnings. These can happen in the dev shell with a
# local `nix.conf` or even in tests since the tests are using a local chroot store,
# but hydra-queue-runner sets store config for a remote store.
# hydra-queue-runner initializes stores in its ctor now, so these warnings get propagated
# in the tests to hydra-send-stats.
$stderr = join "\n", grep { 0 != rindex $_, "warning: unknown setting" } split /\n/, $stderr;
is($stderr, "", "hydra-send-stats stderr should be empty");
is($res, 0, "hydra-send-stats --once should exit zero");

done_testing;
