# encoding: BINARY
# vim: ts=2 sts=2 sw=2

require_relative '__02_httpclient'

$port = 8000

$_get = {}
def get path, &b
	$_get[path] = b
end

def request_handler r, c
STDERR.puts "in request_hander #{r.inspect}, #{c.inspect}"
	q = RUBYH2::HTTPResponse.new r.stream+1
	begin
		case r.method.upcase
		when 'GET', 'HEAD'
			callback = $_get[r.path]
			if callback
				q.status = 200
				q['content-type'] = 'text/html'
				q << callback.call(r, q)
			else
				q = RUBYH2::HTTPResponse.new r.stream+1 # wipe any changes from the handler
				q.status = 404
				q['content-type'] = 'text/html'
				q << <<HTML
<!DOCTYPE html>
<html lang="en"><head><title>Not Found</title></head><body><h1>Not Found</h1><p>Resource <tt>#{r.path}</tt> not found.</p></body></html>
HTML
			end
		else
				q = RUBYH2::HTTPResponse.new r.stream+1 #...
				q.status = 405
				q['content-type'] = 'text/html'
				q << <<HTML
<!DOCTYPE html>
<html lang="en"><head><title>Not Allowed</title></head><body><h1>Not Allowed</h1><p>Method <tt>#{r.method}</tt> not allowed.</p></body></html>
HTML
		end
	rescue Exception => x
		STDERR.puts "#{x.class.name}: #{x}", *x.backtrace.map{|bt|"\t#{bt}"}
		q = RUBYH2::HTTPResponse.new r.stream+1 #...
		q.status = 500
		q['content-type'] = 'text/html'
				q << <<HTML
<!DOCTYPE html>
<html lang="en"><head><title>Internal Server Error</title></head><body><h1>Internal Server Error</h1><p>An error occurred while attempting to handle your request.</p></body></html>
HTML
	end
	c.deliver q
end

at_exit do
	require 'threadpuddle'
	require 'socket'
	threads = ThreadPuddle.new 100
	server = TCPServer.new $port
Thread.new{loop{p threads; sleep 10}}
	Thread.abort_on_exception = true
	loop do
		hclient = RUBYH2::HTTPClient.new
		hclient.on_request {|r| request_handler r, hclient }
		socket = server.accept
STDERR.puts "received socket"
		socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
		socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDTIMEO, [0,500].pack('l_2'))
		socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, [10, 0].pack('l_2'))
		threads.spawn do
STDERR.puts "wrapping socket with hclient"
			hclient.wrap socket
		end
	end
end

