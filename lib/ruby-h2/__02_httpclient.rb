# encoding: BINARY
# vim: ts=2 sts=2 sw=2

require_relative 'frame-deserialiser'
require_relative 'frame-types'
require_relative 'headers-hook'
require_relative 'hpack'

require_relative '__03_objects'

module RUBYH2

	class HTTPClient
		FLAG_END_STREAM  = 0x1
		FLAG_ACK         = 0x1
		FLAG_END_HEADERS = 0x4

		def initialize
			# machinery state
			@request_proc = nil
			@hook = RUBYH2::HeadersHook.new
			@hook.on_frame {|f| _recv_frame f }
			@hpack = RUBYH2::HPack.new
			@window_queue = {}
			# H2 state
			@streams = {}
			@default_window_size = 65535
			@window_size = @default_window_size
			@max_frame_size = 16384
		end

		##
		# Set the callback to be invoked when a HTTP request arrives.
		#
		def on_request &b
			@request_proc = b
			self
		end

		##
		# wrap a TCPSocket
		# e.g.:
		#
		#   require 'socket'
		#   server = TCPServer.new 4567
		#   http_client.wrap server.accept
		#
		def wrap s
			@sil = RUBYH2::FrameSerialiser.new {|b| s.write b } # FIXME: partial write?
			dsil = RUBYH2::FrameDeserialiser.new
			dsil.on_frame {|f| @hook << f }
			loop do
				dsil << s.read
			end
		end

		##
		# deliver HTTPResponse
		def deliver r

			# create headers
			hblock = @hpack.create_block headers
			# split header block into chunks and deliver
			chunks = hblock.scan(/.{1,#{@max_frame_size}}/).map{|c| {type: FrameTypes::CONTINUATION, flags: 0, bytes: c} }
			if chunks.empty?
				# I cast no judgement here, but shouldn't there be some headers..?
				chunks << {type: FrameTypes::HEADERS, flags: FLAG_END_HEADERS, bytes: String.new.b}
			else
				chunks.first[:type] = FrameTypes::HEADERS
				chunks.last[:flags] |= FLAG_END_HEADERS
			end
			# without data, the HEADERS ends the stream
			if r.body.empty?
				chunks.last[:flags] |= FLAG_END_STREAM
			end
			# send the headers frame(s)
			chunks.each do |chunk|
				f = RUBYH2::Frame.new chunk[:type], chunk[:flags], r.stream, chunk[:bytes]
				_send_frame f
			end

			# create data
			if !r.body.empty?
				chunks = r.body.b.scan(/.{1,#{@max_frame_size}}/).map{|c| {flags: 0, bytes: c} }
				chunks.last[:flags] |= FLAG_END_STREAM
				chunks.each do |chunk|
					f = RUBYH2::Frame.new FrameTypes::DATA, chunk[:flags], r.stream, chunk[:bytes]
					_send_frame f
				end
			end
		end

		# returns truthy if the given frame carries HTTP semantics
		# (so has to be sent in order)
		def _semantic_frame? f
			f.type == FrameTypes::DATA || f.type == FrameTypes::HEADERS || f.type == FrameTypes::CONTINUATION
		end

		def _send_frame f
			if !_semantic_frame? f
				@sil << f
			elsif f.sid == 0
				# FIXME: assumes .type != DATA, etc.
				@sil << f
			else
				s = @streams[f.sid]
				raise unless s #???
				q = @window_queue[f.sid]
				if q && !q.empty?
					q << f
				elsif f.type == FrameTypes::DATA
					b = f.payload_size
					if @window_size >= b && s[:window_size] >= b
						@window_size -= b
						s[:window_size] -= b
						@sil << f
					else
						@window_queue[f.sid] ||= []
						@window_queue[f.sid] << f
					end
				else
					@sil << f
				end
			end
		end

		# triggered when a new H2 frame arrives
		def _recv_frame f
			case f.type
			when FrameTypes::DATA
				handle_data f
			when FrameTypes::HEADERS
				handle_headers f
			when FrameTypes::PRIORITY
				# TODO
			when FrameTypes::RST_STREAM
				# TODO
			when FrameTypes::SETTINGS
				handle_settings f
			when FrameTypes::PUSH_PROMISE
				# TODO
			when FrameTypes::PING
				handle_ping f
			when FrameTypes::GOAWAY
				# TODO
			when FrameTypes::WINDOW_UPDATE
				handle_window_update f
			when FrameTypes::CONTINUATION
				# never emitted by the Hook
				raise 'unexpected CONTINUATION frame'
			else
				# ignore extension frames
			end
		end

		def handle_data f
			@streams[f.sid][:body] << f.payload
			_emit_request @streams[f.sid] if f.flag? FLAG_END_STREAM
		end

		def handle_headers f
			if @streams[f.sid]
				raise "no END_STREAM on trailing headers" unless f.flag? FLAG_END_STREAM
			else
				@streams[sid] = {
					headers: Hash.new{|h,k| h[k] = [] },
					body: String.new.b,
					window_size: @default_window_size,
				}
				# read the header block
				@hpack.parse_block(hblock) do |k, v|
					@streams[sid][:headers][k] << v
				end
			end
			# if end-of-stream, emit the request
			_emit_request @streams[sid] if f.flag? FLAG_END_STREAM
		end

		def handle_settings f
			if f.flag? FLAG_ACK
				# TODO
			else
				# TODO:
				#parse settings
				#foreach k=>v
				#	apply k, v
				#end
				#send ACK
			end
		end

		def handle_ping f
			raise 'connection.PROTOCOL_ERROR' unless f.sid == 0
			raise 'connection.FRAME_SIZE_ERROR' unless f.payload.bytesize == 8
			# TODO:
			if f.flag? FLAG_ACK
				#verify_pong f.payload
			else
				#send_pong f.payload
			end
		end

		def handle_window_update f
			raise 'connection:FRAME_SIZE_ERROR' unless f.payload.bytesize == 4
			increment = f.payload.unpack('N').first

			#raise 'PROTOCOL_ERROR' if increment & 0x80000000 == 0x80000000
			increment &= 0x7fffffff

			raise 'stream:PROTOCOL_ERROR' if increment == 0

			if f.sid != 0
				@streams[f.sid][:window_size] += increment
			else
				@window_size += increment
			end

			catch :CONNECTION_EXHAUSTED do
				@window_queue.each_pair do |sid, queue|
					s = @streams[sid]
					# note: sid can never be zero, since frames only
					#       enter the queue because of a blocked DATA
					#       (which isn't allowed on stream 0)
					raise unless s # FIXME
					catch :STREAM_EXHAUSED do
						until queue.empty?
							f = queue.first
							b = (f.type == FrameTypes::DATA ? f.payload_size : 0)
							throw :CONNECTION_EXHAUSED if @window_size < b
							throw :STREAM_EXHAUSTED if s[:window_size] < b
							#TODO: LOCK {
								queue.shift
								@window_size -= b
								s[:window_size] -= b
							#}
							@sil << f
						end
					end
				end
			end
		end

		# triggered when a completed HTTP request arrives
		# (farms it off to the registered callback)
		def _emit_request h
			# FIXME
			@request_proc.call RUBYH2::HTTPRequest.new( h[:headers].delete(':method'), h[:headers].delete(':path'), 'HTTP/2', h[:headers], h[:body] )
		end
	end

end

