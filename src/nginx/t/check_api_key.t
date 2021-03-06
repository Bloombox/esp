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
use src::nginx::t::ServiceControl;
use Test::Nginx;  # Imports Nginx's test module
use Test::More;   # And the test framework
use JSON::PP;

################################################################################

# Port assignments
my $NginxPort = ApiManager::pick_port();
my $BackendPort = ApiManager::pick_port();
my $ServiceControlPort = ApiManager::pick_port();

my $t = Test::Nginx->new()->has(qw/http proxy/)->plan(28);

# Save service name in the service configuration protocol buffer file.
my $config = ApiManager::get_bookstore_service_config .
             ApiManager::read_test_file('testdata/logs_metrics.pb.txt') . <<"EOF";
control {
  environment: "http://127.0.0.1:${ServiceControlPort}"
}
EOF
$t->write_file('service.pb.txt', $config);

$t->write_file('server_config.pb.txt', ApiManager::disable_service_control_cache);

$t->write_file_expand('nginx.conf', <<"EOF");
%%TEST_GLOBALS%%
daemon off;
events {
  worker_connections 32;
}
http {
  %%TEST_GLOBALS_HTTP%%
  server_tokens off;
  server {
    listen 127.0.0.1:${NginxPort};
    server_name localhost;
    location / {
      endpoints {
        api service.pb.txt;
        server_config server_config.pb.txt;
        on;
      }
      proxy_pass http://127.0.0.1:${BackendPort};
    }
  }
}
EOF

my $report_done = $t->{_testdir} . '/report_done.log';

$t->run_daemon(\&bookstore, $t, $BackendPort, 'bookstore.log');
$t->run_daemon(\&servicecontrol, $t, $ServiceControlPort, $report_done,
               'servicecontrol.log');

is($t->waitforsocket("127.0.0.1:${BackendPort}"), 1, 'Bookstore socket ready.');
is($t->waitforsocket("127.0.0.1:${ServiceControlPort}"), 1, 'Service control socket ready.');

$t->run();

################################################################################

my $response1 = ApiManager::http_get($NginxPort,'/shelves?key=key-1');
my $response2 = ApiManager::http_get($NginxPort,'/shelves?api_key=api-key-1');
my $response3 = ApiManager::http_get($NginxPort,'/shelves?api_key=api-key-2&key=key-2');
my $response4 = ApiManager::http($NginxPort,<<'EOF');
GET /shelves HTTP/1.0
X-API-KEY: key-4
Host: localhost

EOF

is($t->waitforfile($report_done), 1, 'Report body file ready.');
$t->stop_daemons();

sub check_response {
    my ($response, $msg) = @_;
    like($response, qr/HTTP\/1\.1 200 OK/, "${msg}: 200 OK");
    like($response, qr/List of shelves\.$/, "${msg}: body OK");
}
check_response($response1, 'Response1 for key-1');
check_response($response2, 'Response2 for api-key-1');
check_response($response3, 'Response3 for api-key-2&key-2');
check_response($response4, 'Response4 for x-api-key:key-4');

sub check_service_control {
    my ($check, $report, $msg, $expected_key) = @_;
    like($check->{uri}, qr/:check$/, "check uri ${msg}");
    like($report->{uri}, qr/:report$/, "report uri ${msg}");

    my $check_body = decode_json(ServiceControl::convert_proto($check->{body}, 'check_request', 'json'));
    my $report_body = decode_json(ServiceControl::convert_proto($report->{body}, 'report_request', 'json'));

    is($check_body->{operation}->{consumerId}, $expected_key,
       "check body has correct consumer id for ${msg}");
    is($report_body->{operations}->[0]->{consumerId}, $expected_key,
       "report_body has correct consumerId for ${msg}");
}

my @sc_requests = ApiManager::read_http_stream($t, 'servicecontrol.log');
is(scalar @sc_requests, 8, 'Service control was called 8 times.');

check_service_control(@sc_requests[0], @sc_requests[1], '1', 'api_key:key-1');
check_service_control(@sc_requests[2], @sc_requests[3], '2', 'api_key:api-key-1');
check_service_control(@sc_requests[4], @sc_requests[5], '3', 'api_key:key-2');
check_service_control(@sc_requests[6], @sc_requests[7], '4', 'api_key:key-4');

################################################################################

sub servicecontrol {
  my ($t, $port, $done, $file) = @_;
  my $server = HttpServer->new($port, $t->testdir() . '/' . $file)
    or die "Can't create test server socket: $!\n";
  local $SIG{PIPE} = 'IGNORE';
  my $request_count = 0;

  $server->on_sub('POST', '/v1/services/endpoints-test.cloudendpointsapis.com:check', sub {
    my ($headers, $body, $client) = @_;
    print $client <<'EOF';
HTTP/1.1 200 OK
Connection: close

EOF
  });

  $server->on_sub('POST', '/v1/services/endpoints-test.cloudendpointsapis.com:report', sub {
    my ($headers, $body, $client) = @_;
    print $client <<'EOF';
HTTP/1.1 200 OK
Connection: close

EOF
    $request_count++;
    if ($request_count == 4) {
      ApiManager::write_binary_file($done, ':report done');
    }
  });

  $server->run();
}

################################################################################

sub bookstore {
  my ($t, $port, $file) = @_;
  my $server = HttpServer->new($port, $t->testdir() . '/' . $file)
    or die "Can't create test server socket: $!\n";
  local $SIG{PIPE} = 'IGNORE';

  $server->on_sub('GET', '/shelves', sub {
    my ($headers, $body, $client) = @_;
    print $client <<'EOF';
HTTP/1.1 200 OK
Connection: close

List of shelves.
EOF
  });

  $server->run();
}

################################################################################
