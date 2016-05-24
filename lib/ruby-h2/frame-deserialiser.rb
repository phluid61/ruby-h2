# encoding: BINARY
# vim: ts=2:sts=2:sw=2

require_relative 'frame'

module RUBYH2
	class FrameDeserialiser
		HEADER_FORMAT = 'CnCCN'
		HEADER_LENGTH = 9
		R_MASK = 0x8000_0000

		def initialize &callback
			@max_frame_size = 16384
			@buffer = nil
			@callbacks = []
			@callbacks << callback if callback
		end
		attr_accessor :max_frame_size

		# block gets called whenever a frame arrives
		def on_frame &handler
			@callbacks << handler
		end

		# accepts bytes, triggers on_frame callbacks
		def << bytes
STDERR.puts "* received #{bytes.bytesize} bytes"
			bytes = @buffer + bytes if @buffer
			bytes.force_encoding Encoding::BINARY

			until bytes.empty?
STDERR.puts "* total size = #{bytes.bytesize}"
				if bytes.bytesize < HEADER_LENGTH
STDERR.puts "* not enough; waiting for more"
					@buffer = bytes
					return self
				end

				len0,len1, type, flags, sid = bytes.unpack HEADER_FORMAT
				rest = bytes[HEADER_LENGTH..-1]
				len = (len0 << 16) | len1
STDERR.puts "* [#{len}, 0x#{type.to_s 16}, 0x#{'%02X'%flags}, #{sid}]"

				raise "too long (#{len} > #{@max_frame_size})" if len > @max_frame_size
				raise "reserved bit set" if sid & R_MASK != 0

				if rest.bytesize < len
STDERR.puts "* waiting for payload..."
					@buffer = bytes
					return self
				end

				payload = rest[0...len]
				emit RUBYH2::Frame.new(type, flags, sid, payload)

				bytes = rest[len..-1]
			end

			@buffer = nil
			self
		end

		def emit f
			@callbacks.each do |h|
				begin
					h.call f
				rescue Exception => x
					# FIXME
					STDERR.puts x, *x.backtrace.map{|bt|"\t#{bt}"}
				end
			end
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
end

