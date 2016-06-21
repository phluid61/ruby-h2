# encoding: BINARY
# vim: ts=2 sts=2 sw=2 expandtab

require_relative 'httppeer'

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
    @logger.debug "in request_hander #{r.inspect}"
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
        # force certain behaviours
        q['content-length'] = q.body.bytesize
        if r.method.upcase == 'HEAD'
          q.instance_variable_set :@body, ''
        end
      else
          q = RUBYH2::HTTPResponse.new r.stream #...
          q.status = 405
          q['content-type'] = 'text/html'
          q << <<HTML
<!DOCTYPE html>
<html lang="en"><head><title>Not Allowed</title></head><body><h1>Not Allowed</h1><p>Method <tt>#{r.method}</tt> not allowed.</p></body></html>
HTML
        q['content-length'] = q.body.bytesize
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
      q['content-length'] = q.body.bytesize
    end
    q['date'] = Time.now.utc.strftime('%a, %e %b %Y %H:%M:%S %Z')
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
      #ctx.ciphers = 'TLSv1.2:!aNULL:!eNULL'
      #ctx.ciphers = '+ECDHE-RSA-AES128-GCM-SHA256:HIGH:!ADH:!SSLv2:!RC4:!aNULL:+3DES';
      #ctx.ciphers = 'ECDHE-RSA-AES128-GCM-SHA256';
      ctx.ciphers = 'EECDH+AESGCM:EDH+AESGCM:AES256+EECDH:AES256+EDH';
#p *ctx.ciphers
      if ctx.respond_to? :alpn_select_cb=
        ctx.alpn_select_cb = lambda {|p| p.delete('h2') or raise "can only speak h2" }
      else
        Application.logger.warn "OpenSSL version doesn't support ALPN"
      end
      if ctx.respond_to? :servername_cb=
        ctx.servername_cb = lambda {|ary| s,h = ary; s.context }
      else
        Application.logger.warn "OpenSSL version doesn't support SNI"
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
  Application.logger.info "#{server.class.name} listening on port #{Application.port}"
  loop do
    hclient = RUBYH2::HTTPPeer.new(Application.logger)
    hclient.send_gzip! if Application.gzip?
    hclient.accept_gzip! if Application.gzip?
    hclient.on_request {|r| Application.handle_request r, hclient }
    begin
      socket = server.accept
      sock_desc = nil
      if socket.is_a? OpenSSL::SSL::SSLSocket
        #socket.io.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
        if socket.respond_to? :alpn_protocol
          sock_desc = "#{socket.io.remote_address.inspect_sockaddr} [#{socket.ssl_version}/#{socket.alpn_protocol}]"
        else
          sock_desc = "#{socket.io.remote_address.inspect_sockaddr} [#{socket.ssl_version}]"
        end
        p socket.cipher
      else
        socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
        sock_desc = "#{socket.remote_address.inspect_sockaddr}"
      end
      Application.logger.info "client connected from #{sock_desc}"
      threads.spawn(sock_desc) do |sock_desc|
        begin
          hclient.wrap socket
        rescue Exception => e
          Application.logger.error "error in client #{sock_desc}: #{e.class.name}: #{e}"
          STDERR.puts "#{e.class.name}: #{e}", *e.backtrace.map{|bt|"\t#{bt}"}
        end
      end
    rescue => e
      Application.logger.error "error in server: #{e.class.name}: #{e}"
      STDERR.puts "#{e.class.name}: #{e}", *e.backtrace.map{|bt|"\t#{bt}"}
    end
  end
end

