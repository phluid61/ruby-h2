# encoding: BINARY
# vim: ts=2 sts=2 sw=2

require_relative '__02_httpclient'

$port = 8000

_get = {}
def get path, &b
	_get[path] = b
end

def request_handler r, c
	q = RUBYH2::HTTPResponse.new r.stream
	case r.method.upcase
	when 'GET', 'HEAD'
		callback = _get[r.path]
		if callback
			q.status = 200
			q['content-type'] = 'text/html'
			q << callback.call(r, q)
		else
			q.status = 404
			q['content-type'] = 'text/html'
			q << <<HTML
<!DOCTYPE html>
<html lang="en"><head><title>Not Found</title></head><body><h1>Not Found</h1><p>Resource <tt>#{r.path}</tt> not found.</p></body></html>
HTML
		end
	else
			q.status = 405
			q['content-type'] = 'text/html'
			q << <<HTML
<!DOCTYPE html>
<html lang="en"><head><title>Not Allowed</title></head><body><h1>Not Allowed</h1><p>Method <tt>#{r.method}</tt> not allowed.</p></body></html>
HTML
	end
	c.deliver r
end

at_exit do
	require 'socket'
	server = TCPServer.new $port
	loop do
		# FIXME: GC?
		hclient = RUBYH2::HTTPClient.new
		hclient.on_request {|r| request_handler r, hclient }
		hclient.wrap server.accept
	end
end

