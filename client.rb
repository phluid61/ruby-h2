# encoding: BINARY
# vim: ts=2 sts=2 sw=2 expandtab

require 'optparse'
opts = {
  :host => 'google.com',
  :port => 443,
  :https => true,
}
OptionParser.new do |o|
  o.banner = "Usage: ruby #{$0} [options]"
  o.on('-h', '--host HOST', 'The server name to connect to') {|h| opts[:host] = h }
  o.on('-p', '--port PORT', OptionParser::DecimalInteger, 'The TCP port to connect to') {|p| opts[:port] = Integer(p) }
  o.on('-s', '--[no-]https', 'Whether or not to use HTTPS') {|s| opts[:https] = s }
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

  if s.respond_to? :alpn_protocol
    puts "connected: #{s.io.remote_address.inspect_sockaddr} [#{s.ssl_version}/#{s.alpn_protocol}]"
  else
    puts "connected: #{s.io.remote_address.inspect_sockaddr} [#{s.ssl_version}]"
  end
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
require 'zlib'
require 'stringio'

$got_response = false
$shutdown = false
agent = RUBYH2::HTTPAgent.new(false, logger)
agent.on_response do |r|
  #puts "RECEIVED RESPONSE: #{r.inspect}"
  puts '--'
  gzip = nil
  filename = 'output.dat'
  r.headers.each_pair do |k,v|
    puts "#{k}: [#{v}]"
    gzip = true if k.downcase == 'content-encoding' && v == 'gzip'
    if k.downcase == 'content-disposition' && v =~ /^attachment\s*;\s*filename=("?)([a-z0-9._+-]+)\1$/i
      filename = $2
    end
  end
  puts ''

  bytes = r.body
  if gzip
    begin
      print "> inflating #{bytes.bytesize} bytes... "
      bytes = Zlib::GzipReader.new(StringIO.new bytes).read
      puts "=> #{bytes.bytesize} bytes"
    rescue Zlib::Error => e
      puts "#{e.class.name}: #{e}"
      filename += '.gz'
    end
  end

  if bytes.bytesize > 1023
    File.open(filename, 'w') {|f| f.write bytes }
    puts "> #{bytes.bytesize} bytes written to #{filename.inspect}"
  else
    puts bytes
    puts '--'
  end
 $got_response = true
end
agent.on_cancel do |sid, err|
  name = RUBYH2::Error.constants.find {|e| err == RUBYH2::Error.const_get(e) }
  name ||= "\##{err}"
  puts "*** cancelled stream #{sid}: #{name}"
  agent.shut_down
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

headers = {
  ':scheme' => $scheme,
  ':authority' => $authority,
  'user-agent' => 'RubyH2-Client/1.0',
  'accept-encoding' => 'gzip',
}
agent.deliver RUBYH2::HTTPRequest.new(1, 'GET', '/', headers)

loop do
  sleep 0.5
  if $got_response
    $shutdown = true
    agent.shut_down
    break
  elsif agent.shutdown?
    $shutdown = true
    break
  end
end

s.close
wrapper.join

