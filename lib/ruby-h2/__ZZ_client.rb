# encoding: BINARY
# vim: ts=2:sts=2:sw=2

require 'socket'
s = TCPSocket.new 'localhost', 8888
s.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
#s.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDTIMEO, [0,500].pack('l_2'))

HEADER_FORMAT = 'CnCCN'
HEADER_LENGTH = 9
$buffer = ''
def parse_frames bytes, &block
	until bytes.empty?
		if ($buffer+bytes).bytesize < HEADER_LENGTH
			puts "PARTIAL FRAME HEADER: #{bytes.each_byte.map{|b|'%02X' % b}.join ' '}"
			$buffer << bytes
			return
		end

		len0,len1, type, flags, sid = ($buffer+bytes).unpack HEADER_FORMAT
		rest = bytes[HEADER_LENGTH..-1]
		len = (len0 << 16) | len1

		if rest.bytesize < len
			puts "PARTIAL FRAME: #{bytes.each_byte.map{|b|'%02X' % b}.join ' '}"
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
#	print bytes
	until bytes.empty?
		sent = write bytes
		#sent = send bytes, 0
		bytes = bytes[sent..-1]
	end
#	flush
end

PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
preader = Thread.new do
	preface = ''
	while preface.bytesize < 24
		bytes = s.readpartial(24 - preface.bytesize)
		preface << bytes
		puts "PARTIAL PREFACE: #{bytes.each_byte.map{|b|'%02X' % b}.join ' '}" if preface.bytesize < 24
	end
	if bytes == PREFACE
		puts "RECEIVED PREFACE"
	else
		raise
	end
end
Thread.pass
s.xmit PREFACE
preader.join

require_relative 'frame-types'
require_relative 'hpack'
$frame_name = Hash[ RUBYH2::FrameTypes.constants.map{|c| [RUBYH2::FrameTypes.const_get(c), c]} ]

reader = Thread.new do
	begin
		catch :EOF do
			hpack = RUBYH2::HPack.new
			loop do
puts "reading..."
				bytes = s.readpartial(4*1024*1024)
puts "read #{bytes.bytesize} bytes" rescue nil
				throw :EOF if bytes.nil? or bytes.empty?
				parse_frames(bytes) do |frame|
					puts "RECEIVED FRAME:"
					puts "   type:   #{frame[:type].to_s 16} #{$frame_name[frame[:type]]}"
					puts "   flags:  #{frame[:flags].to_s 16}"
					puts "   stream: #{frame[:sid]}"
					puts "   payload: [#{frame[:payload].bytesize}]"
					puts *frame[:payload].each_byte.map{|b|'%02X' % b}.each_slice(8).each_slice(4).map{|q|q.map{|h|h.join ' '}.join '   '}
					puts ''
					case frame[:type]
					when 0
						puts '---8<---', frame[:payload], '--->8---', ''
					when 1
						# parse headers
						puts '---'
						hpack.parse_block(frame[:payload]) do |k, v|
							puts " #{k}: #{v}"
						end
						puts '---', ''
					when 4
						bytes = frame[:payload].dup.b
						puts '---'
						until bytes.nil? or bytes.empty?
							k, v, bytes = bytes.unpack 'nNC*'
							puts " #{'%02X' % k} = #{v}"
						end
						puts '---', ''
					end
				end
				Thread.pass
			end#loop
		end#catch
	rescue Exception => x
		STDERR.puts "#{x.class.name}: #{x}", *x.backtrace.map{|bt|"\t#{bt}"}
	end
end
Thread.pass

# HTTP/2 SETTINGS
s.xmit [0,0, 0x4, 0x00, 0].pack(HEADER_FORMAT)
puts "WROTE SETTINGS"

hpack = RUBYH2::HPack.new
# HEADERS (GET /)
bytes = hpack.create_block({
	':method' => 'GET',
	':scheme' => 'http',
	':path' => '/',
	'host' => 'localhost',
	'date' => Time.now.utc.strftime('%a, %e %b %Y %H:%M:%S %Z'),
	'user-agent' => 'TestClient/1.0',
})
#p bytes
len = bytes.bytesize
len0 = len >> 16
len1 = len & 0xFFFF
s.xmit( [len0,len1, 0x1, 0x01|0x04, 1].pack(HEADER_FORMAT)+bytes )
s.flush
puts "WROTE HEADERS"

sleep 5
s.close

reader.join

