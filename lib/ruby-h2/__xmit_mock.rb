# vim: ts=2:sts=2:sw=2

def try
	yield
rescue Exception => x
	STDERR.puts "#{x.class.name}: #{x}", *x.backtrace.map{|bt|"\tfrom #{bt}"}
end

class String
	def dump_frame
		s = '['
		self[0..9].each_byte do |b|
			s << ('%02X ' % b)
		end
		s << self[9..-1].inspect
		s << ']'
		s
	end
end

require_relative 'frame'
require_relative 'frame-types'
require_relative 'frame-serialiser'
require_relative 'frame-deserialiser'
require_relative 'headers-hook'

require 'logger'

$logger = Logger.new STDERR
$logger.progname = 'Xmit'
$logger.datetime_format = '%Y-%m-%d %H:%M:%S'
$logger.sev_threshold = Logger::DEBUG

include FrameTypes

$sil = FrameSerialiser.new
desil = FrameDeserialiser.new
headers_hook = HeadersHook.new
desil.on_frame do |f|
	headers_hook << f
end
headers_hook.on_frame do |f|
	$logger.info "received frame #{f.inspect}"
end
#headers_hook.on_stream do |sid, block|
#	$logger.info "new stream #{sid}\n#{block.inspect}"
#end
$sil.on_frame do |b|
	$logger.info "sending bytes #{b.dump_frame}"
	desil << b
end
def send f
	$logger.info "sending frame #{f.inspect}"
	$sil << f
end

puts "One frame with no payload:"
try { desil << "\x00\x00\x00\x00\x00\x00\x00\x00\x00" }
puts "One frame with payload:"
try { desil << "\x00\x00\x0b\x00\x00\x00\x00\x00\x00Hello world" }
puts "One frame split in header:"
try { desil << "\x00\x00\x00\x00\x00" << "\x00\x00\x00\x00" }
puts "One frame split in payload:"
try { desil << "\x00\x00\x0b\x00\x00\x00\x00\x00\x00Hello " << "world" }
puts "Two whole frames:"
try { desil << "\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x02" }
puts "Three split frames:"
try { desil << "\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00" << "\x00\x00\x00\x00\x00\x00\x02\x00\x00\x02\x00\x00\x00\x00\x00\x03a" << 'a' }

puts "Testing round-trips:"
try { send Frame.new(DATA,0,0,'') }
try { send Frame.new(DATA,0,1,'Hello') }
#try { send Frame.new(DATA,0,-1) }
try { send Frame.new(HEADERS,4,3,'New Stream') }

try { send Frame.new(HEADERS,0,5,'New Stream...') }
try { send Frame.new(CONTINUATION,0,5,'continued...') }
try { send Frame.new(CONTINUATION,4,5,'and ended.') }

