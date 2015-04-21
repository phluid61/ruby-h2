# vim: ts=2:sts=2:sw=2

def try
	yield
rescue Exception => x
	STDERR.puts "#{x.class.name}: #{x}", *x.backtrace.map{|bt|"\tfrom #{bt}"}
end

require_relative 'receiver'

r = Receiver.new

# len0,len1, type, flags, sid, payload
try { r << [0,0, 0, 0, 0].pack('CnCCN') }
try { r << [0,5, 0, 1, 1].pack('CnCCN')+'Hello' }
try { r << [0,0, 0, 0, -1].pack('CnCCN') }
try {
	r << [0,11, 0, 1, 1].pack('CnCCN')
	r << 'Hello'
	r << ' World'
}

