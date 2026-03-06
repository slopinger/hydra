package Hydra::Controller::User;

use utf8;
use strict;
use warnings;
use base 'Hydra::Base::Controller::REST';
use File::Slurper qw(read_text);
use Crypt::RandPasswd;
use Digest::SHA1 qw(sha1_hex);
use Hydra::Config qw(getLDAPConfigAmbient getOIDCConfig);
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;
use Hydra::Helper::Email;
use OIDC::Lite::Client::WebServer;
use OIDC::Lite::Model::IDToken;
use Crypt::PK::RSA;
use Crypt::JWT qw(decode_jwt);
use LWP::UserAgent;
use JSON::MaybeXS;
use HTML::Entities;
use UUID4::Tiny;
use Encode qw(decode);
use Data::Dumper;


__PACKAGE__->config->{namespace} = '';

my $oidcConfig = getOIDCConfig();
sub get_oidc_client {
    return OIDC::Lite::Client::WebServer->new(
        id               => $oidcConfig->{client_id},
        secret           => $oidcConfig->{client_secret},
        authorize_uri    => $oidcConfig->{authorization_endpoint},
        access_token_uri => $oidcConfig->{token_endpoint},
    );
}


sub login :Local :Args(0) :ActionClass('REST') { }

sub login_POST {
    my ($self, $c) = @_;

    my $username = $c->stash->{params}->{username} // "";
    my $password = $c->stash->{params}->{password} // "";

    badRequest($c, "You must specify a user name.") if $username eq "";
    badRequest($c, "You must specify a password.") if $password eq "";

    if ($c->get_auth_realm('ldap') && $c->authenticate({username => $username, password => $password}, 'ldap')) {
        doLDAPLogin($self, $c, $username);
    } elsif ($c->authenticate({username => $username, password => $password})) {}
    else {
        accessDenied($c, "Bad username or password.")
    }

    $self->status_found(
        $c,
        location => $c->uri_for("current-user"),
        entity => $c->model("DB::Users")->find($c->user->username)
    );
}


sub logout :Local :Args(0) :ActionClass('REST') { }

sub logout_GET {
    my ($self, $c) = @_;

    $c->flash->{flashMsg} = "You are no longer signed in." if $c->user_exists();
    $c->logout;

    my $type = $c->session->{type};
    $c->delete_session("Logout");
    if ($type eq "oidc" && defined $oidcConfig->{end_session_endpoint}) {
        $c->res->redirect($oidcConfig->{end_session_endpoint});
    } else {
        $c->res->redirect($c->uri_for("/"));
    }
}

sub doLDAPLogin {
    my ($self, $c, $username) = @_;
    my $user = $c->find_user({ username => $username });
    my $LDAPUser = $c->find_user({ username => $username }, 'ldap');
    my @LDAPRoles = $LDAPUser->roles;
    my $role_mapping = getLDAPConfigAmbient()->{"role_mapping"};

    if (!$user) {
        $c->model('DB::Users')->create(
            { username => $username
            , fullname => decode('UTF-8', $LDAPUser->cn)
            , password => "!"
            , emailaddress => $LDAPUser->mail
            , type => "LDAP"
        });
        $user = $c->find_user({ username => $username }) or die;
    } else {
        $user->update(
            { fullname => decode('UTF-8', $LDAPUser->cn)
            , password => "!"
            , emailaddress => $LDAPUser->mail
            , type => "LDAP"
        });
    }
    $user->userroles->delete;
    foreach my $ldap_role (@LDAPRoles) {
        if (defined($role_mapping->{$ldap_role})) {
            my $roles = $role_mapping->{$ldap_role};
            for my $mapped_role (@$roles) {
                $user->userroles->create({ role => $mapped_role });
            }
        }
    }
    $c->set_authenticated($user);
}

sub doEmailLogin {
    my ($self, $c, $type, $email, $fullName) = @_;

    die "No email address provided.\n" unless defined $email;

    # Be paranoid about the email address format, since we do use it
    # in URLs.
    die "Illegal email address.\n" unless $email =~ /^[a-zA-Z0-9\.\-\_]+@[a-zA-Z0-9\.\-\_]+$/;

    # If allowed_domains is set, check if the email address
    # returned is on these domains.  When not configured, allow all
    # domains.
    my $allowed_domains = $c->config->{allowed_domains} // ($c->config->{persona_allowed_domains} // "");
    if ($allowed_domains ne "") {
        my $email_ok = 0;
        my @domains = split /,/, $allowed_domains;
        map { $_ =~ s/^\s*(.*?)\s*$/$1/ } @domains;

        foreach my $domain (@domains) {
            $email_ok = $email_ok || ((split /@/, $email)[1] eq $domain);
        }
        error($c, "Your email address does not belong to a domain that is allowed to log in.\n")
            unless $email_ok;
    }

    my $user = $c->find_user({ username => $email });

    if ($user) {
        die "You cannot login via login type '$type'.\n" if $user->type ne $type;
    } else {
        $c->model('DB::Users')->create(
            { username => $email
            , fullname => $fullName,
            , password => "!"
            , emailaddress => $email,
            , type => $type
            });
        $user = $c->find_user({ username => $email }) or die;
    }

    $c->set_authenticated($user);

    $c->flash->{successMsg} = "You are now signed in as <tt>" . encode_entities($email) . "</tt>.";
}

sub oidc_login :Path('/oidc-login') Args(0) {
    my ($self, $c) = @_;

    error($c, "Logging in via OIDC is not enabled.", 404) unless $oidcConfig->{enable};
    my $oidc_client = get_oidc_client($c);

    error($c, q{OIDC state mismatch. Is this a CSRF attack?}) unless $c->session->{oidc_state} && $c->session->{oidc_state} eq $c->request->param("state");

    my $code = $c->request->param("code");
    my $token_response = $oidc_client->get_access_token(
        code => $code,
        redirect_uri => $c->uri_for('/oidc-login'),
    ) or error($c, $oidc_client->errstr);

    my $id_token = OIDC::Lite::Model::IDToken->load($token_response->id_token);
    my $finalKey;
    my $alg;
    foreach my $key (@{$oidcConfig->{jwks}->{keys}}) {
        if ($key->{kid} eq $id_token->header->{kid}) {
            $alg = $key->{alg};
            $finalKey = Crypt::PK::RSA->new;
            $finalKey->import_key($key);
            last;
        }
    }

    unless (defined $finalKey && defined $alg) {
        error($c, "No such known key for kid $id_token->{header}->{kid}");
    }

    my $decoded_token = eval {
        decode_jwt(
            token => $token_response->{id_token},
            key => $finalKey,
            accepted_alg => [$alg],
            verify_aud => sub {
                my ($aud) = @_;
                return $aud eq $oidcConfig->{client_id};
            },
            verify_iat => 1,
        )
    };
    if ($@) {
        error($c, "Failed to verify ID token: $@");
    }

    # Crypt::JWT already uses time() to make sure this isn't from the future.
    # So making sure it's actually UTC won't help here anyways, hence continuing
    # to use `time()`. Server-time should be UTC anyways.
    if (($decoded_token->{iat} // 0) < time() - $oidcConfig->{iat_leeway}) {
        error($c, "iat too far in the past");
    }

    my $res = LWP::UserAgent->new->get(
        $oidcConfig->{userinfo_endpoint},
        Authorization => sprintf(q{Bearer %s}, $token_response->access_token)
    );

    my $claims = decode_json($res->decoded_content) or error($c, q{Could not decode claims.}, 401);

    unless ($claims->{sub} eq $decoded_token->{sub}) {
        error($c, "ID token subject doesn't match userinfo subject", 401);
    }

    if (defined $claims->{email_verified} and !$claims->{email_verified}) {
        error($c, "Email address is not verified", 401)
    }

    $c->session->{access_token} = $token_response->access_token;
    $c->session->{expires_at} = time() + $token_response->expires_in;
    $c->session->{refresh_token} = $token_response->refresh_token;
    $c->session->{type} = "oidc";

    doEmailLogin($self, $c, "oidc", $claims->{email}, $claims->{name} // undef);

    if ($oidcConfig->{groups_to_roles}) {
        $c->user->userroles->delete;
        my @groups = @{ $claims->{groups} // [] };
        foreach my $group ( @groups ) {
            next unless defined($oidcConfig->{groups_to_roles}->{$group});
            my @mapping = @{$oidcConfig->{groups_to_roles}->{$group}};
            for my $mapped_role (@mapping) {
                next unless $mapped_role;
                $c->user->userroles->create({ role => $mapped_role });
            }
        }
    }

    $c->res->redirect($c->uri_for($c->session->{oidc_after}));
}

sub github_login :Path('/github-login') Args(0) {
    my ($self, $c) = @_;

    my $client_id = $c->config->{github_client_id} or die "github_client_id not configured.";
    my $client_secret = $c->config->{github_client_secret} // do {
        my $client_secret_file = $c->config->{github_client_secret_file} or die "github_client_secret nor github_client_secret_file is configured.";
        my $client_secret = read_text($client_secret_file);
        $client_secret =~ s/\s+//;
        $client_secret;
    };
    die "No github secret configured" unless $client_secret;

    my $ua = LWP::UserAgent->new();
    my $response = $ua->post(
        'https://github.com/login/oauth/access_token',
        {
            client_id => $client_id,
            client_secret => $client_secret,
            code => ($c->req->params->{code} // die "No token."),
        }, Accept => 'application/json');
    error($c, "Did not get a response from GitHub.") unless $response->is_success;

    my $data = decode_json($response->decoded_content) or die;
    my $access_token = $data->{access_token} // die "No access_token in response from GitHub.";

    $response = $ua->get('https://api.github.com/user/emails', Accept => 'application/vnd.github.v3+json', Authorization => "token $access_token");
    error($c, "Did not get a response from GitHub for email info.") unless $response->is_success;

    $data = decode_json($response->decoded_content) or die;
    my $email;

    foreach my $eml (@{$data}) {
        $email = $eml->{email} if $eml->{verified} && $eml->{primary};
    }

    die "No primary email for this GitHub profile" unless $email;

    $response = $ua->get('https://api.github.com/user', Authorization => "token $access_token");
    error($c, "Did not get a response from GitHub for user info.") unless $response->is_success;
    $data = decode_json($response->decoded_content) or die;

    doEmailLogin($self, $c, "github", $email, $data->{name} // undef);

    $c->res->redirect($c->uri_for($c->res->cookies->{'after_github'}));
}

sub github_redirect :Path('/github-redirect') Args(0) {
    my ($self, $c) = @_;

    my $client_id = $c->config->{github_client_id} or die "github_client_id not configured.";

    my $after = "/" . $c->req->params->{after};

    $c->res->cookies->{'after_github'} = {
        name => 'after_github',
        value => $after,
    };

    $c->res->redirect("https://github.com/login/oauth/authorize?client_id=$client_id&scope=user:email");
}

sub oidc_redirect :Path('/oidc-redirect') Args(0) {

    my ($self, $c) = @_;

    my $after = "/" . ($c->req->params->{after} // "");

    $c->session->{oidc_after} = $after;

    my $oidc_client = get_oidc_client($c);
    my $state = UUID4::Tiny::create_uuid_string();
    $c->session->{oidc_state} = $state;
    my $redirect_url = $oidc_client->uri_to_redirect(
        redirect_uri => $c->uri_for('/oidc-login'),
        scope        => $oidcConfig->{scopes},
        state        => $state,
    );

    $c->res->redirect( $redirect_url );
}


sub captcha :Local Args(0) {
    my ($self, $c) = @_;
    $c->create_captcha();
}


sub isValidPassword {
    my ($password) = @_;
    return length($password) >= 6;
}


sub register :Local Args(0) {
    my ($self, $c) = @_;

    accessDenied($c, "User registration is currently not implemented.") unless isAdmin($c);

    if ($c->request->method eq "GET") {
        $c->stash->{template} = 'user.tt';
        $c->stash->{create} = 1;
        return;
    }

    die unless $c->request->method eq "PUT";

    my $userName = trim $c->stash->{params}->{username};
    $c->stash->{username} = $userName;

    error($c, "You did not enter the correct digits from the security image.")
        unless isAdmin($c) || $c->validate_captcha($c->req->param('captcha'));

    error($c, "Your user name is invalid. It must start with a lower-case letter followed by lower-case letters, digits, dots or underscores.")
        if $userName !~ /^$userNameRE$/;

    error($c, "Your user name is already taken.")
        if $c->find_user({ username => $userName });

    $c->model('DB')->schema->txn_do(sub {
        my $user = $c->model('DB::Users')->create(
            { username => $userName
            , password => "!"
            , emailaddress => "",
            , type => "hydra"
            });
        updatePreferences($c, $user);
    });

    unless ($c->user_exists) {
        $c->set_authenticated({username => $userName})
            or error($c, "Unable to authenticate the new user!");
    }

    $c->flash->{successMsg} = "User <tt>$userName</tt> has been created.";
    $self->status_no_content($c);
}


sub updatePreferences {
    my ($c, $user) = @_;

    my $fullName = trim($c->stash->{params}->{fullname} // "");
    error($c, "Your must specify your full name.") if $fullName eq "";

    my $password = trim($c->stash->{params}->{password} // "");
    if ($user->type eq "hydra" && ($user->password eq "!" || $password ne "")) {
        error($c, "You must specify a password of at least 6 characters.")
            unless isValidPassword($password);

        error($c, "The passwords you specified did not match.")
            if $password ne trim $c->stash->{params}->{password2};

        $user->setPassword($password);
    }

    my $emailAddress = trim($c->stash->{params}->{emailaddress} // "");
    # FIXME: validate email address?

    $user->update(
        { fullname => $fullName
        , emailonerror => $c->stash->{params}->{"emailonerror"} ? 1 : 0
        , publicdashboard => $c->stash->{params}->{"publicdashboard"} ? 1 : 0
        });

    if (isAdmin($c)) {
        $user->update({ emailaddress => $emailAddress })
            if $user->type eq "hydra";

        # This is disabled in the UI, so ignoring this silently.
        if ($user->type ne "oidc") {
            $user->userroles->delete;
            $user->userroles->create({ role => $_ })
                foreach paramToList($c, "roles");
        }
    }
}


sub currentUser :Path('/current-user') :ActionClass('REST') { }

sub currentUser_GET {
    my ($self, $c) = @_;

    requireUser($c);

    $self->status_ok($c,
        entity => $c->model("DB::Users")->find($c->user->username)
    );
}


sub user :Chained('/') PathPart('user') CaptureArgs(1) {
    my ($self, $c, $userName) = @_;

    requireUser($c);

    accessDenied($c, "You do not have permission to edit other users.")
        if $userName ne $c->user->username && !isAdmin($c);

    $c->stash->{user} = $c->model('DB::Users')->find($userName)
        or notFound($c, "User $userName doesn't exist.");
}


sub edit :Chained('user') :PathPart('') :Args(0) :ActionClass('REST::ForBrowsers') { }

sub edit_GET {
    my ($self, $c) = @_;
    $c->stash->{template} = 'user.tt';
}

sub edit_PUT {
    my ($self, $c) = @_;
    my $user = $c->stash->{user};

    if (($c->stash->{params}->{submit} // "") eq "reset-password") {
        return;
    }

    $c->model('Db')->schema->txn_do(sub {
        updatePreferences($c, $user);
    });

    $c->flash->{successMsg} = "Your preferences have been updated.";
    $self->status_no_content($c);
}

sub edit_DELETE {
    my ($self, $c) = @_;
    my $user = $c->stash->{user};

    my ($project) = $c->model('DB::Projects')->search({ owner => $user->username });
    error($c, "User " . $user->username . " is still owner of project " . $project->name . ".")
        if defined $project;

    $c->logout() if $user->username eq $c->user->username;

    $user->delete;

    $c->flash->{successMsg} = "The user has been deleted.";
    $self->status_no_content($c);
}


sub reset_password :Chained('user') :PathPart('reset-password') :Args(0) {
    my ($self, $c) = @_;
    my $user = $c->stash->{user};

    requirePost($c);

    error($c, "This user's password cannot be reset.") if $user->type ne "hydra";
    error($c, "No email address is set for this user.")
        unless $user->emailaddress;

    my $password = Crypt::RandPasswd->word(8,10);
    $user->setPassword($password);
    sendEmail(
        $c->config,
        $user->emailaddress,
        "Hydra password reset",
        "Hi,\n\n".
        "Your password has been reset. Your new password is '$password'.\n\n".
        "You can change your password at " . $c->uri_for($self->action_for('edit'), [$user->username]) . ".\n\n".
        "With regards,\n\nHydra.\n",
        []
    );

    $c->flash->{successMsg} = "A new password has been sent to ${\$user->emailaddress}.";
    $self->status_no_content($c);
}


sub dashboard_old :Chained('user') :PathPart('dashboard') :Args(0) {
    my ($self, $c) = @_;
    $c->res->redirect($c->uri_for($self->action_for("dashboard"), $c->req->captures));
}


sub dashboard_base :Chained('/') PathPart('dashboard') CaptureArgs(1) {
    my ($self, $c, $userName) = @_;

    $c->stash->{user} = $c->model('DB::Users')->find($userName)
        or notFound($c, "User $userName doesn't exist.");

    accessDenied($c, "You do not have permission to view this dashboard.")
        unless $c->stash->{user}->publicdashboard ||
          (defined $c->user && ($userName eq $c->user->username || !isAdmin($c)));
}


sub dashboard :Chained('dashboard_base') :PathPart('') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'dashboard.tt';

    # Get the N most recent builds for each starred job.
    $c->stash->{starredJobs} = [];
    foreach my $j ($c->stash->{user}->starredjobs->search({}, { order_by => ['project', 'jobset', 'job'] })) {
        my @builds = $j->jobset->builds->search(
            { job => $j->job },
            { rows => 20, order_by => "id desc" });
        push @{$c->stash->{starredJobs}}, { job => $j, builds => [@builds] };
    }
}


sub my_jobs_tab :Chained('dashboard_base') :PathPart('my-jobs-tab') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{lazy} = 1;
    $c->stash->{template} = 'dashboard-my-jobs-tab.tt';

    error($c, "No email address is set for this user.") unless $c->stash->{user}->emailaddress;

    # Get all current builds of which this user is a maintainer.
    $c->stash->{builds} = [$c->model('DB::Builds')->search(
        { iscurrent => 1
        , maintainers => { ilike => "%" . $c->stash->{user}->emailaddress . "%" }
        , "project.enabled" => 1
        , "jobset.enabled" => 1
        },
        { order_by => ["project", "jobset", "job"]
        , join => {"jobset" => "project"}
        })];
}


sub my_jobsets_tab :Chained('dashboard_base') :PathPart('my-jobsets-tab') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'dashboard-my-jobsets-tab.tt';

    my $jobsets = $c->model('DB::Jobsets')->search(
        { "project.enabled" => 1, "me.enabled" => 1,
        , owner => $c->stash->{user}->username
        },
        { order_by => ["project", "name"]
        , join => ["project"]
        });

    $c->stash->{jobsets} = [jobsetOverview_($c, $jobsets)];
}


1;
