# Copyright (C) Extensible Service Proxy Authors
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.
#
################################################################################
#
use strict;
use warnings;

################################################################################

use src::nginx::t::ApiManager;   # Must be first (sets up import path to the Nginx test module)
use src::nginx::t::HttpServer;
use Test::Nginx;  # Imports Nginx's test module
use Test::More;   # And the test framework

################################################################################

# Port assignments
my $NginxPort = ApiManager::pick_port();
my $BackendPort = ApiManager::pick_port();

my $t = Test::Nginx->new()->has(qw/http proxy/)->plan(7);

$t->write_file_expand('nginx.conf', <<"EOF");
%%TEST_GLOBALS%%
daemon off;
events { worker_connections 32; }
http {
  %%TEST_GLOBALS_HTTP%%
  server_tokens off;
  endpoints { off; }
  server {
    listen 127.0.0.1:${NginxPort};
    server_name localhost;
    location / {
      endpoints { off; }
      proxy_pass http://127.0.0.1:${BackendPort};
    }
  }
}
EOF

$t->run_daemon(\&bookstore, $t, $BackendPort, 'requests.log');
is($t->waitforsocket("127.0.0.1:${BackendPort}"), 1, 'Bookstore socket ready.');
$t->run();

################################################################################

my $response = ApiManager::http_get($NginxPort,'/endpoints-off');
$t->stop_daemons();

like($response, qr/HTTP\/1\.1 200 OK/, 'Returned HTTP 200.');
like($response, qr/Endpoints disabled/, 'Returned expected body.');

my @requests = ApiManager::read_http_stream($t, 'requests.log');
is(scalar @requests, 1, 'only /endpoints-off was called.');
my $r = shift @requests;
is($r->{verb}, 'GET', 'verb is get');
is($r->{uri}, '/endpoints-off', 'uri is /endpoints-off');
is($r->{headers}->{host}, "127.0.0.1:${BackendPort}", 'Host header was set.');

################################################################################

sub bookstore {
  my ($t, $port, $file) = @_;
  my $server = HttpServer->new($port, $t->testdir() . '/' . $file)
    or die "Can't create test HTTP server: $!\n";
  local $SIG{PIPE} = 'IGNORE';
  $server->on('GET', '/endpoints-off', <<'EOF');
HTTP/1.1 200 OK
Connection: close

Endpoints disabled
EOF
  $server->run();
}

################################################################################
