package Isucon3::Web;

use strict;
use warnings;
use utf8;
use Kossy;
use DBIx::Sunny;
use JSON::XS qw/ decode_json /;
use Digest::SHA qw/ sha256_hex /;
use DBIx::Sunny;
use File::Temp qw/ tempfile /;
use IO::Handle;
use Encode;
use Time::Piece;

sub load_config {
    my $self = shift;
    $self->{_config} ||= do {
        my $env = $ENV{ISUCON_ENV} || 'local';
        open(my $fh, '<', $self->root_dir . "/../config/${env}.json") or die $!;
        my $json = do { local $/; <$fh> };
        close($fh);
        decode_json($json);
    };
}

sub markdown {
    my $content = shift;
    my ($fh, $filename) = tempfile();
    $fh->print(encode_utf8($content));
    $fh->close;
    my $html = qx{ ../bin/markdown $filename };
    unlink $filename;
    return $html;
}

sub dbh {
    my ($self) = @_;
    $self->{_dbh} ||= do {
        my $dbconf = $self->load_config->{database};
        DBIx::Sunny->connect(
            "dbi:mysql:database=${$dbconf}{dbname};host=${$dbconf}{host};port=${$dbconf}{port}", $dbconf->{username}, $dbconf->{password}, {
                RaiseError => 1,
                PrintError => 0,
                AutoInactiveDestroy => 1,
                mysql_enable_utf8   => 1,
                mysql_auto_reconnect => 1,
            },
        );
    };
}

filter 'session' => sub {
    my ($app) = @_;
    sub {
        my ($self, $c) = @_;
        my $sid = $c->req->env->{"psgix.session.options"}->{id};
        $c->stash->{session_id} = $sid;
        $c->stash->{session}    = $c->req->env->{"psgix.session"};
        $app->($self, $c);
    };
};

filter 'get_user' => sub {
    my ($app) = @_;
    sub {
        my ($self, $c) = @_;

        my $user_id = $c->req->env->{"psgix.session"}->{user_id};
        my $user = $self->dbh->select_row(
            'SELECT * FROM users WHERE id=?',
            $user_id,
        );
        $c->stash->{user} = $user;
        $c->res->header('Cache-Control', 'private') if $user;
        $app->($self, $c);
    }
};

filter 'require_user' => sub {
    my ($app) = @_;
    sub {
        my ($self, $c) = @_;
        unless ( $c->stash->{user} ) {
            return $c->redirect('/');
        }
        $app->($self, $c);
    };
};

filter 'anti_csrf' => sub {
    my ($app) = @_;
    sub {
        my ($self, $c) = @_;
        my $sid   = $c->req->param('sid');
        my $token = $c->req->env->{"psgix.session"}->{token};
        if ( $sid ne $token ) {
            return $c->halt(400);
        }
        $app->($self, $c);
    };
};

get '/' => [qw(session get_user)] => sub {
    my ($self, $c) = @_;

    my $total = $self->dbh->select_one(
        'SELECT count(*) FROM memos WHERE is_private=0'
    );
    my $memos = $self->dbh->select_all(q{
        SELECT m.id, m.content, m.is_private, m.created_at, u.username
        FROM memos m
        STRAIGHT_JOIN users u ON m.user = u.id
        WHERE m.is_private = 0
        ORDER BY m.id DESC
        LIMIT 100
    });
    $c->render('index.tx', {
        memos => $memos,
        page  => 0,
        total => $total,
    });
};

get '/recent/:page' => [qw(session get_user)] => sub {
    my ($self, $c) = @_;
    my $page  = int $c->args->{page};
    my $total = $self->dbh->select_one(
        'SELECT count(*) FROM memos WHERE is_private=0'
    );
    my $memos = $self->dbh->select_all(sprintf q{
        SELECT m.id, m.content, m.is_private, m.created_at, u.username
        FROM memos m
        STRAIGHT_JOIN users u ON m.user = u.id
        WHERE m.is_private = 0
        ORDER BY m.id DESC
        LIMIT 100 OFFSET %d
    }, $page * 100);
    if ( @$memos == 0 ) {
        return $c->halt(404);
    }

    $c->render('index.tx', {
        memos => $memos,
        page  => $page,
        total => $total,
    });
};

get '/signin' => [qw(session get_user)] => sub {
    my ($self, $c) = @_;
    $c->render('signin.tx', {});
};

post '/signout' => [qw(session get_user require_user anti_csrf)] => sub {
    my ($self, $c) = @_;
    $c->req->env->{"psgix.session.options"}->{change_id} = 1;
    delete $c->req->env->{"psgix.session"}->{user_id};
    $c->redirect('/');
};

post '/signup' => [qw(session anti_csrf)] => sub {
    my ($self, $c) = @_;

    my $username = $c->req->param("username");
    my $password = $c->req->param("password");
    my $user = $self->dbh->select_row(
        'SELECT id, username, password, salt FROM users WHERE username=?',
        $username,
    );
    if ($user) {
        $c->halt(400);
    }
    else {
        my $salt = substr( sha256_hex( time() . $username ), 0, 8 );
        my $password_hash = sha256_hex( $salt, $password );
        $self->dbh->query(
            'INSERT INTO users (username, password, salt) VALUES (?, ?, ?)',
            $username, $password_hash, $salt,
        );
        my $user_id = $self->dbh->last_insert_id;
        $c->req->env->{"psgix.session"}->{user_id} = $user_id;
        $c->redirect('/mypage');
    }
};

post '/signin' => [qw(session)] => sub {
    my ($self, $c) = @_;

    my $username = $c->req->param("username");
    my $password = $c->req->param("password");
    my $user = $self->dbh->select_row(
        'SELECT id, username, password, salt FROM users WHERE username=?',
        $username,
    );
    if ( $user && $user->{password} eq sha256_hex($user->{salt} . $password) ) {
        $c->req->env->{"psgix.session.options"}->{change_id} = 1;
        my $session = $c->req->env->{"psgix.session"};
        $session->{user_id} = $user->{id};
        $session->{token}   = sha256_hex(rand());
        $self->dbh->query(
            'UPDATE users SET last_access=now() WHERE id=?',
            $user->{id},
        );
        return $c->redirect('/mypage');
    }
    else {
        $c->render('signin.tx', {});
    }
};

get '/mypage' => [qw(session get_user require_user)] => sub {
    my ($self, $c) = @_;

    my $memos = $self->dbh->select_all(
        'SELECT id, content, is_private, created_at, updated_at FROM memos WHERE user=? ORDER BY id DESC',
        $c->stash->{user}->{id},
    );
    $c->render('mypage.tx', { memos => $memos });
};

post '/memo' => [qw(session get_user require_user anti_csrf)] => sub {
    my ($self, $c) = @_;

    $self->dbh->query(
        'INSERT INTO memos (user, content, is_private, created_at) VALUES (?, ?, ?, now())',
        $c->stash->{user}->{id},
        scalar $c->req->param('content'),
        scalar($c->req->param('is_private')) ? 1 : 0,
    );
    my $memo_id = $self->dbh->last_insert_id;
    $c->redirect('/memo/' . $memo_id);
};

get '/memo/:id' => [qw(session get_user)] => sub {
    my ($self, $c) = @_;

    my $user = $c->stash->{user};
    my $memo = $self->dbh->select_row(q{
        SELECT m.id, m.content, m.is_private, m.created_at, m.updated_at, u.id AS user_id, u.username
        FROM memos m
        STRAIGHT_JOIN users u ON m.user = u.id
        WHERE m.id = ?
    }, $c->args->{id});
    $c->halt(404) unless $memo;

    if ($memo->{is_private}) {
        if (!$user || $user->{id} != $memo->{user_id}) {
            $c->halt(404);
        }
    }

    $memo->{content_html} = markdown($memo->{content});

    my $cond = ($user and $user->{id} == $memo->{user_id}) ? "" : "AND is_private = 0";

    my $older = $self->dbh->select_row(qq{
        SELECT id FROM memos WHERE id < ? AND user = ? $cond ORDER BY id DESC LIMIT 1
    }, $memo->{id}, $memo->{user_id});

    my $newer = $self->dbh->select_row(qq{
        SELECT id FROM memos WHERE id > ? AND user = ? $cond ORDER BY id ASC LIMIT 1
    }, $memo->{id}, $memo->{user_id});

    $c->render('memo.tx', {
        memo  => $memo,
        older => $older,
        newer => $newer,
    });
};

1;
