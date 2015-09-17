use FindBin;
use lib "$FindBin::Bin/extlib/lib/perl5";
use lib "$FindBin::Bin/lib";
use Cache::Redis;
use File::Basename;
use Plack::Builder;
use Isucon3::Web;

my $root_dir = File::Basename::dirname(__FILE__);

my $app = Isucon3::Web->psgi($root_dir);
builder {
    enable 'ReverseProxy';
    enable 'Session::Simple',
        store => Cache::Redis->new(
            server      => 'localhost:6379',
            redis_class => 'Redis::Fast',
        ),
        cookie_name => 'isucon_session',
        httponly    => 1;
    $app;
};
