# encoding: BINARY
# vim: ts=2:sts=2:sw=2

module RUBYH2
	class Frame
		def initialize type, flags, sid, payload=''
			@type = type
			@flags = flags
			@sid = sid
			@payload = payload.b.freeze
		end
		attr_reader :type
		attr_reader :flags
		attr_reader :sid
		attr_reader :payload

		def inspect
			"\#<Frame:#{'%02X'%type}[#{'%02X'%flags}]:#{sid} #{payload.inspect}>"
		end

		def flag? bit
			@flags & bit == bit
		end

		# only used when concatenating HEADERS+CONTINUATION
		def << bytes
			@payload = (@payload + bytes.b).freeze
		end

		def payload_size
			@payload.bytesize
		end
	end
end

