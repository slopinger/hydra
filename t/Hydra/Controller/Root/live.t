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
        like($res->content, qr{static/js/common\.js\?v=}, 'Versions the shared handlers');
        like($res->content, qr{static/js/live\.js\?v=}, 'Versions the refresh script');
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


subtest 'Stream authorization uses Hydra access rules' => sub {
    is(request(GET '/_live/authorize')->code, 204, 'Public Hydra permits streams');
    local Hydra->config->{private} = 1;
    is(request(GET '/_live/authorize', Accept => 'application/json')->code, 403,
       'Private Hydra rejects anonymous streams');
};

subtest 'Stream-enabled build and log pages' => sub {
    local Hydra->config->{live_updates} = 1;
    ok(evalSucceeds($jobset), 'Stream fixture evaluates');
    my $build = queuedBuildsForJobset($jobset)->first;
    $build->buildsteps->create({stepnr => 1, type => 0, busy => 1,
        drvpath => $build->drvpath, starttime => time});
    my $page = request(GET '/build/' . $build->id, Accept => 'text/html');
    is($page->code, 200, 'Build renders with streams enabled');
    like($page->content, qr/hydra-live-events/, 'Subscribes to build events');
    like($page->content, qr/data-live-log/, 'Embeds streamed log');
    unlike($page->content, qr/data-log-url="[^"]*\?step=/,
        'Build stream follows steps instead of capturing a template loop variable');
    like($page->content, qr/data-live-preserve/, 'Preserves log across status updates');
    my $log = request(GET '/build/' . $build->id . '/log', Accept => 'text/html');
    is($log->code, 200, 'Pretty log renders');
    like($log->content, qr/data-live-log/, 'Pretty log uses streaming component');
};

done_testing;
