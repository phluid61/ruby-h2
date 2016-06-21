# encoding: BINARY
# vim: ts=2 sts=2 sw=2 expandtab

$USE_HTTPS = true

### DEBUG FUNCTIONS
require 'thread'
$ESC = "\x1B".b
$say_mutex = Mutex.new
module Kernel
  def say *strs
    $say_mutex.synchronize {
      if Thread.current[:reader]
        strs.each{|s| puts "#{$ESC}[36m#{s}#{$ESC}[0m" }
      else
        strs.each{|s| puts "#{$ESC}[35m#{s}#{$ESC}[0m" }
      end
    }
  end
end

require 'socket'
s = TCPSocket.new 'localhost', 8888

if $USE_HTTPS
  $scheme = 'https'
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
    s.hostname = 'localhost'
  else
    STDERR.puts "OpenSSL version doesn't support SNI"
  end
  s.sync_close = true
  s.connect
else
  $scheme = 'http'
  s.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
  #s.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDTIMEO, [0,500].pack('l_2'))
end

require 'zlib'
require 'stringio'

HEADER_FORMAT = 'CnCCN'
HEADER_LENGTH = 9
$buffer = ''
def parse_frames bytes, &block
  until bytes.empty?
    if ($buffer+bytes).bytesize < HEADER_LENGTH
      say "PARTIAL FRAME HEADER: #{bytes.each_byte.map{|b|'%02X' % b}.join ' '}"
      $buffer << bytes
      return
    end

    len0,len1, type, flags, sid = ($buffer+bytes).unpack HEADER_FORMAT
    rest = bytes[HEADER_LENGTH..-1]
    len = (len0 << 16) | len1

    if rest.bytesize < len
      say "PARTIAL FRAME: #{bytes.each_byte.map{|b|'%02X' % b}.join ' '}"
      $buffer << bytes
      return
    else
      payload = rest[0...len]
      frame = {type:type, flags:flags, sid:sid, payload:payload}

      $buffer = ''
      bytes = rest[len..-1]

      yield frame
    end
  end
end

def s.xmit bytes
  bytes.force_encoding Encoding::BINARY
#  print bytes
  until bytes.empty?
    sent = write bytes
    #sent = send bytes, 0
    bytes = bytes[sent..-1]
  end
#  flush
end

PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
#preader = Thread.new do
#  Thread.current[:reader] = true
#  preface = ''
#  while preface.bytesize < 24
#    bytes = s.readpartial(24 - preface.bytesize)
#    preface << bytes
#    say "PARTIAL PREFACE: #{bytes.each_byte.map{|b|'%02X' % b}.join ' '}" if preface.bytesize < 24
#  end
#  if bytes == PREFACE
#    say "RECEIVED PREFACE"
#  else
#    raise
#  end
#end
s.xmit PREFACE
#preader.join

#---

require_relative 'lib/ruby-h2/frame-types'
require_relative 'lib/ruby-h2/hpack'
$frame_name = Hash[ RUBYH2::FrameTypes.constants.map{|c| [RUBYH2::FrameTypes.const_get(c), c]} ]

#---

$_open = {}
$_open_sem = Mutex.new
def open i
  $_open_sem.synchronize {
    $_open[i] = 2
  }
end
def half_close i
  ded = false
  $_open_sem.synchronize {
    $_open[i] -= 1
    ded = true if $_open[i] == 0
  }
  say "stream #{i} is closed" if ded
end
def close i
  $_open_sem.synchronize {
    $_open[i] = 0
  }
  say "stream #{i} is closed"
end

#---

$ignore_EOFError = false

def strip_padding bytes
  ints = bytes.bytes
  pad_length = ints.shift
  rst_length = ints.length
  raise "Pad Length #{pad_length} exceeds frame payload size #{rst_length+1}" if pad_length > rst_length
  ints[0...rst_length-pad_length].pack('C*')
end
def hexify f
  hex = []
  cursor = 0x1
  while f > 0
    if f & cursor == cursor
      f ^= cursor
      hex << ('0x%02X' % cursor)
    end
    cursor <<= 1
  end
  return hex.join '|'
end

reader = Thread.new do
  Thread.current[:reader] = true
  begin
    catch :EOF do
      hpack = RUBYH2::HPack.new
      loop do
say "reading..."
        bytes = s.readpartial(4*1024*1024)
say "read #{bytes.bytesize} bytes" rescue nil
        throw :EOF if bytes.nil? or bytes.empty?
        parse_frames(bytes) do |frame|
          say "RECEIVED FRAME:"
          say "   type:   #{frame[:type].to_s 16} #{$frame_name[frame[:type]]}"
          say "   flags:  #{frame[:flags].to_s 16} #{hexify frame[:flags]}"
          say "   stream: #{frame[:sid]}"
          say "   payload: [#{frame[:payload].bytesize}]"
          if frame[:payload].bytesize > 0
            say *frame[:payload].each_byte.map{|b|'%02X' % b}.each_slice(8).each_slice(4).map{|q|q.map{|h|h.join ' '}.join '   '}
            case frame[:type]
            when 0
              frame[:payload] = strip_padding frame[:payload] if (frame[:flags] & 0x8) == 0x8
              say '---8<---', frame[:payload], '--->8---'
              half_close frame[:sid] if (frame[:flags] & 0x1) == 0x1
            when 1
              # parse headers
              frame[:payload] = strip_padding frame[:payload] if (frame[:flags] & 0x8) == 0x8
              say '---'
              hpack.parse_block(frame[:payload]) do |k, v|
                say " #{k}: #{v}"
              end
              say '---'
              half_close frame[:sid] if (frame[:flags] & 0x1) == 0x1
            when 3
              close frame[:sid]
            when 4
              bytes = frame[:payload].dup.b
              say '---'
              until bytes.nil? or bytes.empty?
                k, v, bytes = bytes.unpack 'nNa*'
                say " #{'%02X' % k} = #{v}"
              end
              say '---'
            when 7
              stream, error, message = frame[:payload].unpack('NNa*')
              say '---'
              say " last stream id: #{stream}"
              say " error code:     #{error}"
              say " debug data:     [#{message.bytesize}]"
              say *message.each_byte.map{|b|'%02X' % b}.each_slice(8).each_slice(4).map{|q|q.map{|h|h.join ' '}.join '   '}
              say '---'
            when 0xf0 # GZIPPED_DATA
              frame[:payload] = strip_padding frame[:payload] if (frame[:flags] & 0x8) == 0x8
              gunzip = Zlib::GzipReader.new(StringIO.new frame[:payload])
              say '---8<---', gunzip.read, '--->8---'
              half_close frame[:sid] if (frame[:flags] & 0x1) == 0x1
            end
          end
          say ''
        end
        Thread.pass
      end#loop
    end#catch
  rescue IOError, Errno::EBADF => x
    STDERR.say "#{x.class.name}: #{x}", *x.backtrace.map{|bt|"\t#{bt}"} unless $ignore_EOFError
  rescue Exception => x
    STDERR.say "#{x.class.name}: #{x}", *x.backtrace.map{|bt|"\t#{bt}"}
  end
end
Thread.pass

#---

# HTTP/2 SETTINGS
s.xmit [0,0, 0x4, 0x00, 0].pack(HEADER_FORMAT)
say "WROTE SETTINGS"

# test ping1
s.xmit( [0,8, 0x6, 0x00, 0].pack(HEADER_FORMAT)+'UUUUUUUU' )
say "SENT PING: UUUUUUUU"

hpack = RUBYH2::HPack.new

open 1
# HEADERS (GET /)
bytes = hpack.create_block({
  ':method' => 'GET',
  ':scheme' => $scheme,
  ':authority' => 'localhost:8888',
  ':path' => '/',
  'host' => 'localhost',
  'date' => Time.now.utc.strftime('%a, %e %b %Y %H:%M:%S %Z'),
  'user-agent' => 'TestClient/1.0',
})
len = bytes.bytesize
len0 = len >> 16
len1 = len & 0xFFFF
s.xmit( [len0,len1, 0x1, 0x01|0x04, 1].pack(HEADER_FORMAT)+bytes )
say "WROTE HEADERS: GET /"
half_close 1

# test ping2
s.xmit( [0,8, 0x6, 0x00, 0].pack(HEADER_FORMAT)+'33333333' )
say "SENT PING: 33333333"

sleep 1

open 3
# HEADERS (GET /nonesuch)
bytes = hpack.create_block({
  ':method' => 'GET',
  ':scheme' => $scheme,
  ':authority' => 'localhost:8888',
  ':path' => '/nonesuch',
  'host' => 'localhost',
  'date' => Time.now.utc.strftime('%a, %e %b %Y %H:%M:%S %Z'),
  'user-agent' => 'TestClient/1.0',
})
len = bytes.bytesize
len0 = len >> 16
len1 = len & 0xFFFF
s.xmit( [len0,len1, 0x1, 0x01|0x04, 3].pack(HEADER_FORMAT)+bytes )
say "WROTE HEADERS: GET /nonesuch"
half_close 3

sleep 0.5

open 5
# HEADERS (POST /)
payload = 'foobar'
bytes = hpack.create_block({
  ':method' => 'POST',
  ':scheme' => $scheme,
  ':authority' => 'localhost:8888',
  ':path' => '/',
  'host' => 'localhost',
  'date' => Time.now.utc.strftime('%a, %e %b %Y %H:%M:%S %Z'),
  'user-agent' => 'TestClient/1.0',
  'content-type' => 'text/plain',
  'content-length' => payload.bytesize.to_s,
})
len = bytes.bytesize
len0 = len >> 16
len1 = len & 0xFFFF
s.xmit( [len0,len1, 0x1, 0x04, 5].pack(HEADER_FORMAT)+bytes )
say "WROTE HEADERS:  POST /"
# BODY (POST /)
len = payload.bytesize
len0 = len >> 16
len1 = len & 0xFFFF
s.xmit( [len0,len1, 0x0, 0x01, 5].pack(HEADER_FORMAT)+payload )
say "WROTE DATA: foobar"
half_close 5

sleep 0.5

open 7
# HEADERS (GET /padded)
bytes = hpack.create_block({
  ':method' => 'GET',
  ':scheme' => $scheme,
  ':authority' => 'localhost:8888',
  ':path' => '/padded',
  'host' => 'localhost',
  'date' => Time.now.utc.strftime('%a, %e %b %Y %H:%M:%S %Z'),
  'user-agent' => 'TestClient/1.0',
})
len = bytes.bytesize
len0 = len >> 16
len1 = len & 0xFFFF
s.xmit( [len0,len1, 0x1, 0x01|0x04, 7].pack(HEADER_FORMAT)+bytes )
say "WROTE HEADERS: GET /padded"
half_close 7

sleep 1

# HTTP/2 SETTINGS
bytes = [0xf000,1].pack('nN')
len = bytes.bytesize
len0 = len >> 16
len1 = len & 0xFFFF
s.xmit( [len0,len1, 0x4, 0x00, 0].pack(HEADER_FORMAT)+bytes )
say "WROTE SETTINGS: ACCEPT_GZIP_DATA"

sleep 1

open 9
# HEADERS (GET /padded)
bytes = hpack.create_block({
  ':method' => 'GET',
  ':scheme' => $scheme,
  ':authority' => 'localhost:8888',
  ':path' => '/',
  'host' => 'localhost',
  'date' => Time.now.utc.strftime('%a, %e %b %Y %H:%M:%S %Z'),
  'user-agent' => 'TestClient/1.0',
})
len = bytes.bytesize
len0 = len >> 16
len1 = len & 0xFFFF
s.xmit( [len0,len1, 0x1, 0x01|0x04, 9].pack(HEADER_FORMAT)+bytes )
say "WROTE HEADERS: GET /"
half_close 9

sleep 0.5

open 11
# HEADERS (GET /padded)
bytes = hpack.create_block({
  ':method' => 'GET',
  ':scheme' => $scheme,
  ':authority' => 'localhost:8888',
  ':path' => '/padded',
  'host' => 'localhost',
  'date' => Time.now.utc.strftime('%a, %e %b %Y %H:%M:%S %Z'),
  'user-agent' => 'TestClient/1.0',
})
len = bytes.bytesize
len0 = len >> 16
len1 = len & 0xFFFF
s.xmit( [len0,len1, 0x1, 0x01|0x04, 11].pack(HEADER_FORMAT)+bytes )
say "WROTE HEADERS: GET /padded"
half_close 11

sleep 5

bytes = [0,0x0].pack('NN') + 'Cya'
len = bytes.bytesize
len0 = len >> 16
len1 = len & 0xFFFF
s.xmit( [len0,len1, 0x7, 0x00, 0].pack(HEADER_FORMAT)+bytes )
say "WROTE GOAWAY: Cya"

sleep 5
$ignore_EOFError = true
s.close

reader.join

