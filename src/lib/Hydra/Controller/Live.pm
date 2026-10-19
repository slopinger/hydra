package Hydra::Controller::Live;

use strict;
use warnings;
use base 'Hydra::Base::Controller::REST';

__PACKAGE__->config->{namespace} = '_live';

# Root::begin applies the private-instance, session and readonly-IP rules.
# The async stream service checks this endpoint before opening a stream.
sub authorize :Local :Args(0) {
    my ($self, $c) = @_;
    $c->response->status(204);
    $c->response->body('');
    $c->response->headers->header('Cache-Control', 'no-store');
}

1;
