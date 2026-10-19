use strict;
use warnings;
use Setup;
use Test2::V0;
use HTTP::Request::Common;

my %ctx = test_init();
require Hydra::Model::DB;
require Catalyst::Test;
Catalyst::Test->import('Hydra');

my $db = Hydra::Model::DB->new;
hydra_setup($db);
my $jobset = createBaseJobset('basic', 'basic.nix', $ctx{jobsdir});

for my $path ('/', '/project/tests', '/jobset/tests/basic', '/queue', '/machines', '/evals') {
    subtest $path => sub {
        my $res = request(GET $path, Accept => 'text/html');
        ok($res->is_success, 'Standard HTML page works');
        like($res->content, qr/data-live-page="/, 'Enables live updates');
        like($res->content, qr{static/js/live\.js}, 'Loads the refresh script');
        unlike($res->content, qr{static/ui/|/_ui/|type="importmap"}, 'Uses the standard interface');
    };
}

my $html = request(GET '/jobset/tests/basic', Accept => 'text/html');
like($html->content, qr/data-tab-uri="[^"]*jobs-tab"/, 'Lazy tabs declare their URL');
like($html->content, qr/id="live-tabs" data-live-region/, 'Tab navigation can refresh');

my $json = request(GET '/', Accept => 'application/json');
ok($json->is_success, 'Existing JSON API still works');
like($json->header('Content-Type'), qr{application/json}, 'JSON stays JSON');
unlike($json->content, qr/data-live-page/, 'JSON does not get the HTML shell');

my $login = request(GET '/login', Accept => 'text/html');
unlike($login->content, qr{static/js/live\.js}, 'Authentication pages do not refresh');

done_testing;
