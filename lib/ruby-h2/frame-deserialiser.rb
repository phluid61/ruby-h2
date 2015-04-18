#vim: ts=2:sts=2:sw=2

require_relative 'frame'

class FrameDeserialiser
	HEADER_FORMAT = 'CnCCNA*'
	HEADER_LENGTH = 9
	R_MASK = 0x8000_0000

	def initialize &callback
		@max_frame_size = 16384
		@buffer = nil
		@callback = callback
	end
	attr_accessor :max_frame_size

	def << bytes
		bytes = @buffer + bytes if @buffer

		until bytes.empty?
			len0,len1, type, flags, sid, rest = bytes.unpack HEADER_FORMAT
			len = (len0 << 16) | len1

			raise "too long (#{len} > #{@max_frame_size}" if len > @max_frame_size
			raise "reserved bit set" if sid & R_MASK

			if rest.bytesize < len
				@buffer = bytes
				return
			end

			payload = rest[0...len]
			emit Frame.new(type, flags, sid, payload)

			bytes = rest[len..-1]
		end

		@buffer = nil
	end

	def emit f
		@callback.call f if @callback
	end
	private :emit

	# for tooling
	def empty?
		@buffer.nil? || @buffer.empty?
	end
	# for tooling
	def length
		@buffer.nil? ? 0 : @buffer.bytesize
	end

	# for debugging purposes
	def peek
		@buffer.nil? ? @buffer : @buffer.dup
	end
end

