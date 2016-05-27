# encoding: BINARY
# vim: ts=2 sts=2 sw=2

require_relative 'frame-deserialiser'
require_relative 'frame-serialiser'
require_relative 'frame-types'
require_relative 'headers-hook'
require_relative 'settings'
require_relative 'errors'
require_relative 'hpack'

require_relative '__03_objects'

module RUBYH2

	PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

	class HTTPClient
		FLAG_END_STREAM  = 0x1
		FLAG_ACK         = 0x1
		FLAG_END_HEADERS = 0x4

		include RUBYH2::Error

		def initialize logger
			# machinery state
			@request_proc = nil
			@hook = RUBYH2::HeadersHook.new
			@hook.on_frame {|f| recv_frame f }
			@hpack = RUBYH2::HPack.new
			@logger = logger
			# H2 state
			@window_queue = {}
			@first_frame = true
			@streams = {}
			@default_window_size = 65535
			@window_size = @default_window_size
			@max_frame_size = 16384
			@max_streams = nil
			# other settings
			@can_push = true
		end

		def inspect
			"\#<HTTPClient @window_queue=#{@window_queue.inspect}, @streams=#{@streams.inspect}, @default_window_size=#{@default_window_size.inspect}, @window_size=#{@window_size.inspect}, @max_frame_size=#{@max_frame_size.inspect}, @max_streams=#{@max_streams.inspect}, @can_push=#{@can_push.inspect}>"
		end

		attr_reader :can_push

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
			@sil = RUBYH2::FrameSerialiser.new {|b| _write s, b }
			dsil = RUBYH2::FrameDeserialiser.new
			dsil.on_frame {|f| @hook << f }
			handle_prefaces s
			send_frame RUBYH2::Settings.frame_from({0x4 => 2_147_483_647})
			loop do
				bytes = begin
					s.readpartial(4*1024*1024)
				rescue EOFError
					nil
				end
				break if bytes.nil? or bytes.empty?
				dsil << bytes
				Thread.pass
			end
		ensure
			s.close rescue nil
		end

		##
		# deliver HTTPResponse
		def deliver r
			# create headers
			all_headers = r.headers.dup
			all_headers[':status'] = r.status.to_s
			hblock = @hpack.create_block all_headers
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
				send_frame f
			end

			# create data
			if !r.body.empty?
				chunks = r.body.b.scan(/.{1,#{@max_frame_size}}/).map{|c| {flags: 0, bytes: c} }
				chunks.last[:flags] |= FLAG_END_STREAM
				chunks.each do |chunk|
					f = RUBYH2::Frame.new FrameTypes::DATA, chunk[:flags], r.stream, chunk[:bytes]
					send_frame f
				end
			end

			# half-close
			@streams[r.stream].close_local! # TODO: maybe close/destroy
		end

		# returns truthy if the given frame carries HTTP semantics
		# (so has to be sent in order)
		def semantic_frame? f
			f.type == FrameTypes::DATA || f.type == FrameTypes::HEADERS || f.type == FrameTypes::CONTINUATION
		end

	private

		def _write sock, bytes
			bytes.force_encoding Encoding::BINARY
			#sock.print bytes
			until bytes.empty?
				sent = sock.write bytes
				#sent = sock.send bytes, 0
				bytes = bytes[sent..-1]
			end
			#sock.flush
		end


		def handle_prefaces s
			preface = nil
			t0 = Thread.new do
				preface = String.new.b
				while preface.length < 24
					preface << s.readpartial(24 - preface.length)
				end
			end
			t1 = Thread.new do
				_write s, PREFACE
			end
			t0.join
			raise ConnectionError.new(PROTOCOL_ERROR, 'invalid preface') if preface != PREFACE
			t1.join
		end

		def send_frame f
			if !semantic_frame? f
				@sil << f
			elsif f.sid == 0
				# FIXME: assumes .type != DATA, etc.
				@sil << f
			else
				s = @streams[f.sid]
				s = @streams[f.sid] = RUBYH2::Stream.new(@default_window_size) if !s
				q = @window_queue[f.sid]
				if q && !q.empty?
					q << f
				elsif f.type == FrameTypes::DATA
					b = f.payload_size
					if @window_size >= b && s.window_size >= b
						@window_size -= b
						s.window_size -= b
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
		def recv_frame f
			if @first_frame
				# first frame has to be settings
				# FIXME: make sure this is the actual settings, not the ACK to ours
				raise ConnectionError.new(PROTOCOL_ERROR, 'invalid preface - no SETTINGS') if f.type != FrameTypes::SETTINGS
				@first_frame = false
			end

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

		# triggered when a completed HTTP request arrives
		# (farms it off to the registered callback)
		def emit_request sid, h
			# NB: this is only invoked once we get an END_STREAM flag
			@streams[sid].close_remote! # TODO: maybe close/destroy
			# FIXME
			headers = h.headers
			@request_proc.call RUBYH2::HTTPRequest.new( sid, headers.delete(':method'), headers.delete(':path'), 'HTTP/2', headers, h[:body] )
		end

		def handle_data f
			# FIXME: if @streams[f.sid] is closed ...
			@streams[f.sid] << f.payload
			emit_request f.sid, @streams[f.sid] if f.flag? FLAG_END_STREAM
		end

		def handle_headers f
			# FIXME: if @streams[f.sid] is closed ...
			if @streams[f.sid]
				raise "no END_STREAM on trailing headers" unless f.flag? FLAG_END_STREAM
			else
				# FIXME: is this the right stream-id?
				@streams[f.sid] = RUBYH2::Stream.new(@default_window_size)
				# read the header block
				@hpack.parse_block(f.payload) do |k, v|
					@streams[f.sid][k] << v
				end
			end
			# if end-of-stream, emit the request
			emit_request f.sid, @streams[f.sid] if f.flag? FLAG_END_STREAM
		end

		def handle_settings f
			# FIXME: if f.sid > 0 ...
			if f.flag? FLAG_ACK
				# TODO
			else
				hash = RUBYH2::Settings.pairs_from(f)
				hash.each_pair do |k, v|
					case k
					when RUBYH2::Settings::HEADER_TABLE_SIZE
						@hpack.max_size_out = v
					when RUBYH2::Settings::ENABLE_PUSH
						raise 'connect:PROTOCOL_ERROR' unless v == 0 or v == 1 # FIXME
						@can_push = (v == 1)
					when RUBYH2::Settings::MAX_CONCURRENT_STREAMS
						@max_streams = v
					when RUBYH2::Settings::INITIAL_WINDOW_SIZE
						raise 'connection:FLOW_CONTROL_ERROR' if v > 0x7fffffff # FIXME
						@default_window_size = v
					when RUBYH2::Settings::MAX_FRAME_SIZE
						raise 'connection:PROTOCOL_ERROR' if v < 0x4000 or v > 0xffffff # FIXME
						@max_frame_size = v
					when RUBYH2::Settings::MAX_HEADER_LIST_SIZE
						# FIXME ???
					end
				end
				#send ACK
				# FIXME: ensure we only send this after the initial settings
				g = RUBYH2::Frame.new FrameTypes::SETTINGS, FLAG_ACK, 0, ''
				send_frame g
			end
		end

		def handle_ping f
			# FIXME: if f.sid > 0 ...
			raise 'connection:PROTOCOL_ERROR' unless f.sid == 0
			raise 'connection:FRAME_SIZE_ERROR' unless f.payload.bytesize == 8
			if f.flag? FLAG_ACK
				#TODO: verify_pong f.payload
			else
				# send pong
				g = RUBYH2::Frame.new FrameTypes::PING, FLAG_ACK, 0, f.payload
				send_frame g
			end
		end

		def handle_window_update f
			# FIXME: stream states?

			raise 'connection:FRAME_SIZE_ERROR' unless f.payload.bytesize == 4
			increment = f.payload.unpack('N').first

			#raise 'PROTOCOL_ERROR' if increment & 0x80000000 == 0x80000000
			increment &= 0x7fffffff

			raise 'stream:PROTOCOL_ERROR' if increment == 0

			if f.sid != 0
				@streams[f.sid].window_size += increment
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
							throw :STREAM_EXHAUSTED if s.window_size < b
							queue.shift
							@window_size -= b
							s.window_size -= b
							@sil << f
						end
					end# :STREAM_EXHAUSTED
				end
			end# :CONNECTION_EXHAUSTED
		end


	end

end

