# encoding: BINARY
# vim: ts=2 sts=2 sw=2 expandtab

require 'optparse'
opts = {
  :host => 'localhost',
  :port => 8888,
  :https => true,
}
OptionParser.new do |o|
  o.banner = "Usage: ruby #{$0} [options]"
  o.on('-h', '--host HOST', 'The server name to connect to [default=localhost]') {|h| opts[:host] = h }
  o.on('-p', '--port PORT', OptionParser::DecimalInteger, 'The TCP port to connect to [default=8888]') {|p| opts[:port] = Integer(p) }
  o.on('-s', '--[no-]https', 'Whether or not to use HTTPS [default=true]') {|s| opts[:https] = s }
  o.on('-?', '--help', 'Show this help message, and quit') { puts o; exit }
end.parse!


require 'socket'
s = TCPSocket.new opts[:host], opts[:port]
s.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)

$authority = opts[:host]
if opts[:https]
  $scheme = 'https'
  $authority += ":#{opts[:port]}" if opts[:port] != 443
  require 'openssl'
  ctx = OpenSSL::SSL::SSLContext.new :TLSv1_2_client
  ctx.verify_callback = lambda {|pverify_ok, store_context| true } # security!
  if ctx.respond_to? :alpn_protocols=
    ctx.alpn_protocols = %w[h2]
  else
    STDERR.puts "OpenSSL version doesn't support ALPN"
  end
  s = OpenSSL::SSL::SSLSocket.new s, ctx
  if s.respond_to? :hostname=
    s.hostname = opts[:host]
  else
    STDERR.puts "OpenSSL version doesn't support SNI"
  end
  s.sync_close = true
  s.connect
else
  $scheme = 'http'
  $authority += ":#{opts[:port]}" if opts[:port] != 80
end

require 'logger'
logger = Logger.new STDERR
logger.progname = 'demo-client'
logger.datetime_format = '%Y-%m-%d %H:%M:%S'
logger.sev_threshold = Logger::DEBUG

require_relative 'lib/ruby-h2/http-agent'
require_relative 'lib/ruby-h2/http-request'

$shutdown = false
agent = RUBYH2::HTTPAgent.new(false, logger)
agent.on_response do |r|
  #puts "RECEIVED RESPONSE: #{r.inspect}"
  puts '--'
  r.headers.each_pair do |k,v|
    puts "#{k}: [#{v}]"
  end
  puts ''
  puts r.body
  puts '--'
end
wrapper = Thread.new do
  begin
    agent.wrap s
  rescue Exception => e
    if !$shutdown
      logger.error "#{e.class.name}: #{e}"
      STDERR.puts "#{e.class.name}: #{e}", *e.backtrace.map{|bt|"\t#{bt}"}
    end
  end
end

agent.ping 'UUUUUUUU'

headers = {
  ':scheme' => $scheme,
  ':authority' => $authority,
  'host' => opts[:host],
  'user-agent' => 'TestClient/1.0',
}
agent.deliver RUBYH2::HTTPRequest.new(1, 'GET', '/', headers)

agent.ping '33333333'

sleep 1

headers = {
  ':scheme' => $scheme,
  ':authority' => $authority,
  'host' => opts[:host],
  'user-agent' => 'TestClient/1.0',
}
agent.deliver RUBYH2::HTTPRequest.new(3, 'GET', '/nonesuch', headers)

sleep 0.5

payload = 'foobar'
headers = {
  ':scheme' => $scheme,
  ':authority' => $authority,
  'host' => opts[:host],
  'user-agent' => 'TestClient/1.0',
  'content-type' => 'text/plain',
  'content-length' => payload.bytesize.to_s,
}
agent.deliver RUBYH2::HTTPRequest.new(5, 'POST', '/', headers, payload)

sleep 0.5

headers = {
  ':scheme' => $scheme,
  ':authority' => $authority,
  'host' => opts[:host],
  'user-agent' => 'TestClient/1.0',
}
agent.deliver RUBYH2::HTTPRequest.new(7, 'GET', '/padded', headers)

sleep 1

agent.accept_gzip!

sleep 0.25

headers = {
  ':scheme' => $scheme,
  ':authority' => $authority,
  'host' => opts[:host],
  'user-agent' => 'TestClient/1.0',
}
agent.deliver RUBYH2::HTTPRequest.new(9, 'GET', '/', headers)

sleep 0.5

headers = {
  ':scheme' => $scheme,
  ':authority' => $authority,
  'host' => opts[:host],
  'user-agent' => 'TestClient/1.0',
}
agent.deliver RUBYH2::HTTPRequest.new(11, 'GET', '/padded', headers)

sleep 5

$shutdown = true
agent.shut_down

sleep 2
s.close

wrapper.join

