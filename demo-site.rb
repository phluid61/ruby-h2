# encoding: BINARY
# vim: ts=2 sts=2 sw=2 expandtab

require 'optparse'
opts = {
  :port => 8888,
  :https => true,
}
OptionParser.new do |o|
  o.banner = "Usage: ruby #{$0} [options]"
  o.on('-p', '--port PORT', OptionParser::DecimalInteger, 'The TCP port to listen for new connections [default=8888]') {|p| opts[:port] = Integer(p) }
  o.on('-s', '--[no-]https', 'Whether or not to use HTTPS [default=true]') {|s| opts[:https] = s }
  o.on('-?', '--help', 'Show this help message, and quit') { puts o; exit }
end.parse!

require_relative 'lib/ruby-h2/application'

Application.port = opts[:port]
Application.https = opts[:https]

get '/' do
  <<HTML
<!DOCTYPE html>
<html lang="en"><head><title>Index</title></head><body><h1>Index</h1><p>This is the index.</p><ul><li><a href="/">simple test</a></li><li><a href="/padded">padding test</a></li></ul></body></html>
HTML
end

get '/padded' do |request, response|
  response.pad!
  <<HTML
<!DOCTYPE html>
<html lang="en"><head><title>Padded</title></head><body><h1>Padded</h1><p>This response should be padded.</p><ul><li><a href="/">simple test</a></li><li><a href="/padded">padding test</a></li></ul></body></html>
HTML
end

