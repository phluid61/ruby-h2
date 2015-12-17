# vim: ts=2:sts=2:sw=2

require_relative 'frame-types'

class HeadersHook
	include FrameTypes

	FLAG_END_HEADERS = 0x4

	def initialize
		@frame_handlers = []
		@stream_handlers = []

		@headers_sid = nil
		@headers_flags = nil
		@headers_block = nil
	end

	# block gets called whenever a frame arrives
	def on_frame &handler
		@frame_handlers << handler
	end

	# block gets called whenever a new stream is opened
	def on_stream &handler
		@stream_handlers << handler
	end

	# call this with every arriving frame
	def << frame
		if @headers_sid
			intercept_continuation frame
		else
			intercept_header frame
		end
	end

	# :nodoc:
	def intercept_continuation frame
		if frame.type == CONTINUATION
			@headers_block << frame.payload
			maybe_continue frame
		else
			raise 'not CONTINUATION frame'
		end
	end

	# :nodoc:
	def intercept_header frame
			case frame.type
			when HEADERS
				@headers_sid = frame.sid
				@headers_flags = frame.flags
				# TODO: extract padding,priority,...
				@headers_block = frame.payload.dup
				maybe_continue frame
			when CONTINUATION
				raise 'unexpected CONTINUATION frame' # FIXME
			else
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

	# :nodoc:
	def maybe_continue frame
		if frame.flags & FLAG_END_HEADERS == FLAG_END_HEADERS
			@stream_handlers.each do |h|
				begin
					h.call @headers_sid, @headers_flags, @headers_block.dup
				rescue Exception => x
					# FIXME
					STDERR.puts x, *x.backtrace.map{|bt|"\t#{bt}"}
				end
			end
			@headers_sid = nil
		end
	end
end

