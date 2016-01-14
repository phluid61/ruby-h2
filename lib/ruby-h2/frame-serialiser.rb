# encoding: BINARY
# vim: ts=2:sts=2:sw=2

require_relative 'frame'

module RUBYH2
	class FrameSerialiser
		HEADER_FORMAT = 'CnCCNA*'
		R_MASK = 0x8000_0000

		def initialize &callback
			@max_frame_size = 16384
			@callbacks = []
			@callbacks << callback if callback
		end
		attr_accessor :max_frame_size

		# block gets called whenever a frame is sent
		def on_frame &handler
			@callbacks << handler
		end

		# accepts frames, triggers on_frame callbacks
		def << frame
			len = frame.payload.bytesize
			len0 = (len >> 16) & 0xFF
			len1 = (len & 0xFFFF)

			raise "too long (#{len} > #{@max_frame_size}" if len > @max_frame_size
			raise "reserved bit set" if frame.sid & R_MASK != 0

			bytes = [len0,len1, frame.type, frame.flags, frame.sid, frame.payload].pack HEADER_FORMAT
			emit bytes
			self
		end

		def emit b
			@callbacks.each do |h|
				begin
					h.call b
				rescue Exception => x
					# FIXME
					STDERR.puts x, *x.backtrace.map{|bt|"\t#{bt}"}
				end
			end
		end
		private :emit

	end
end

