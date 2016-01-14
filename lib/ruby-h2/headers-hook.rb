# encoding: BINARY
# vim: ts=2:sts=2:sw=2

require_relative 'frame-types'

module RUBYH2
	class HeadersHook
		include FrameTypes

		FLAG_END_HEADERS = 0x4

		def initialize
			@frame_handlers = []
			@headers = nil
		end

		# block gets called whenever a frame arrives
		def on_frame &handler
			@frame_handlers << handler
		end

		# call this with every arriving frame
		def << frame
			if @headers
				intercept_continuation frame
			else
				intercept_header frame
			end
		end

		# :nodoc:
		def intercept_continuation frame
			if frame.type == CONTINUATION
				@headers << frame.payload
				maybe_continue frame
			else
				raise 'not CONTINUATION frame'
			end
		end

		# :nodoc:
		def intercept_header frame
				case frame.type
				when HEADERS
					@headers = frame
					# TODO: extract padding,priority,...
					maybe_continue frame
				when CONTINUATION
					raise 'unexpected CONTINUATION frame' # FIXME
				else
					emit_frame frame
				end
		end

		# :nodoc:
		def maybe_continue frame
			if frame.flag? FLAG_END_HEADERS
				emit_frame @headers
				@headers = nil
			end
		end

		# :nodoc:
		def emit_frame frame
			@frame_handlers.each do |h|
				begin
					h.call frame
				rescue Exception => x
					# FIXME
					STDERR.puts x, *x.backtrace.map{|bt|"\t#{bt}"}
				end
			end
		end
	end
end

