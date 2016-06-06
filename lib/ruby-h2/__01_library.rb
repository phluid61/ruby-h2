# encoding: BINARY
# vim: ts=2 sts=2 sw=2

require_relative '__02_httppeer'

require 'logger'

class ApplicationClass
	def initialize port
		@port = port
		@https = true

		@gzip = false

		@logger = Logger.new STDERR
		@logger.progname = 'ruby-h2'
		@logger.datetime_format = '%Y-%m-%d %H:%M:%S'
		@logger.sev_threshold = Logger::DEBUG

		@_get = {}
	end
	attr_accessor :port
	attr_accessor :logger

	def https?
		@https
	end
	def https= h
		@https = !!h
	end

	def gzip?
		@gzip
	end
	def gzip= gz
		@gzip = !!gz
	end

	def get path, &proc
		@_get[path] = proc
	end

	def handle_request r, c
		@logger.info "in request_hander #{r.inspect}"
		q = RUBYH2::HTTPResponse.new r.stream
		begin
			case r.method.upcase
			when 'GET', 'HEAD'
				callback = @_get[r.path]
				if callback
					q.status = 200
					q['content-type'] = 'text/html'
					q << callback.call(r, q)
				else
					q = RUBYH2::HTTPResponse.new r.stream # wipe any changes from the handler
					q.status = 404
					q['content-type'] = 'text/html'
					q << <<HTML
<!DOCTYPE html>
<html lang="en"><head><title>Not Found</title></head><body><h1>Not Found</h1><p>Resource <tt>#{r.path}</tt> not found.</p></body></html>
HTML
				end
			else
					q = RUBYH2::HTTPResponse.new r.stream #...
					q.status = 405
					q['content-type'] = 'text/html'
					q << <<HTML
<!DOCTYPE html>
<html lang="en"><head><title>Not Allowed</title></head><body><h1>Not Allowed</h1><p>Method <tt>#{r.method}</tt> not allowed.</p></body></html>
HTML
			end
		rescue Exception => x
			STDERR.puts "#{x.class.name}: #{x}", *x.backtrace.map{|bt|"\t#{bt}"}
			q = RUBYH2::HTTPResponse.new r.stream #...
			q.status = 500
			q['content-type'] = 'text/html'
					q << <<HTML
<!DOCTYPE html>
<html lang="en"><head><title>Internal Server Error</title></head><body><h1>Internal Server Error</h1><p>An error occurred while attempting to handle your request.</p></body></html>
HTML
		end
		c.deliver q
	end
end

Application = ApplicationClass.new(8000)

def get path, &proc
	Application.get path, &proc
end

at_exit do
	require 'threadpuddle'
	require 'socket'
	require 'openssl'
	threads = ThreadPuddle.new 100
	server = TCPServer.new Application.port
	if Application.https?
		begin
			ctx = OpenSSL::SSL::SSLContext.new :TLSv1_2_server
			if ctx.respond_to? :alpn_protocols=
				ctx.alpn_protocols = %w[h2]
				ctx.alpn_select_cb = lambda {|p| p.delete('h2') or raise "can only speak h2" }
			else
				Application.logger.warn "OpenSSL version doesn't support ALPN"
			end
			# openssl req -x509 -newkey rsa:2048 -keyout private.key -out certificate.crt -days 3650 -nodes
			ctx.key = OpenSSL::PKey::RSA.new(File.read 'private.key')
			ctx.cert = OpenSSL::X509::Certificate.new(File.read 'certificate.crt')
			server = OpenSSL::SSL::SSLServer.new server, ctx
			server.start_immediately = true
		rescue Exception => e
			Application.logger.error "unable to start OpenSSL: #{e}"
			exit
		end
	end
	Application.logger.info "listening on port #{Application.port}"
	Thread.abort_on_exception = true
	loop do
		hclient = RUBYH2::HTTPPeer.new(Application.logger)
		hclient.send_gzip! if Application.gzip?
		hclient.accept_gzip! if Application.gzip?
		hclient.on_request {|r| Application.handle_request r, hclient }
		socket = server.accept
		if Application.https?
			Application.logger.info "client connected from #{socket.io.remote_address.inspect_sockaddr}[#{socket.ssl_version}]"
		else
			socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
			#socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDTIMEO, [0,500].pack('l_2'))
			#socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, [10, 0].pack('l_2'))
			Application.logger.info "client connected from #{socket.remote_address.inspect_sockaddr}"
		end
		threads.spawn do
			hclient.wrap socket
		end
	end
end

