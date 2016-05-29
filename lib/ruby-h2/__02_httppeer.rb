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

	class HTTPPeer
		FLAG_END_STREAM  = 0x1
		FLAG_ACK         = 0x1
		FLAG_END_HEADERS = 0x4

		include Error

		def initialize logger
			# machinery state
			@request_proc = nil
			@hook = HeadersHook.new
			@hook.on_frame {|f| recv_frame f }
			@hpack = HPack.new
			@logger = logger
			# H2 state
			@window_queue = {}
			@first_frame = true
			@streams = {}
			@default_window_size = 65535
			@window_size = @default_window_size
			@max_frame_size = 16384
			@max_streams = nil
			@push_to_client = true
			# other settings
			@pings = []
			@goaway = false
			@last_stream = 0 # last incoming stream handed up to application
			@shutting_down = false
		end

		def inspect
			"\#<HTTPPeer @window_queue=#{@window_queue.inspect}, @streams=#{@streams.inspect}, @default_window_size=#{@default_window_size.inspect}, @window_size=#{@window_size.inspect}, @max_frame_size=#{@max_frame_size.inspect}, @max_streams=#{@max_streams.inspect}, @push_to_client=#{@push_to_client.inspect}>"
		end

		attr_reader :push_to_client

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
			@sil = FrameSerialiser.new {|b| _write s, b }
			dsil = FrameDeserialiser.new
			dsil.on_frame {|f| @hook << f }
			handle_prefaces s
			send_frame Settings.frame_from({Settings::INITIAL_WINDOW_SIZE => 0x7fffffff})
			loop do
				bytes = begin
					s.readpartial(4*1024*1024)
				rescue EOFError
					nil
				end
				if bytes.nil? or bytes.empty?
					@logger.info "client disconnected from #{s.remote_address.inspect_sockaddr}"
					break
				end
				dsil << bytes
				Thread.pass
			end
		ensure
			s.close rescue nil
		end

		##
		# Shut down the connection.
		def shut_down
			return if @shutting_down
			@shutting_down = true
			g = Frame.new FrameTypes::GOAWAY, 0x00, 0, [@last_stream,NO_ERROR].pack('NN')
			send_frame g
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
				f = Frame.new chunk[:type], chunk[:flags], r.stream, chunk[:bytes]
				send_frame f
			end

			# create data
			if !r.body.empty?
				chunks = r.body.b.scan(/.{1,#{@max_frame_size}}/).map{|c| {flags: 0, bytes: c} }
				chunks.last[:flags] |= FLAG_END_STREAM
				chunks.each do |chunk|
					f = Frame.new FrameTypes::DATA, chunk[:flags], r.stream, chunk[:bytes]
					send_frame f
				end
			end

			# half-close
			@streams[r.stream].close_local!
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
				s = @streams[f.sid] = Stream.new(@default_window_size) if !s
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

			if @goaway
				case f.type
				when FrameTypes::DATA
				when FrameTypes::HEADERS
				when FrameTypes::PUSH_PROMISE
				when FrameTypes::CONTINUATION
				else
					# FIXME
					@logger.info "Ignoring frame 0x#{f.type.to_s 16} after GOAWAY"
					return
				end
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
				handle_goaway f
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
			# NB: this function only invoked once we get an END_STREAM flag
			@streams[sid].close_remote!
			@last_stream = sid
			# FIXME
			headers = h.headers
			@request_proc.call HTTPRequest.new( sid, headers.delete(':method'), headers.delete(':path'), 'HTTP/2', headers, h[:body] )
		end

		def handle_data f
			# FIXME: if @streams[f.sid] is closed ...
			return if @goaway

			bytes = f.payload

			# never run out of window space
			g = Frame.new FrameTypes::WINDOW_UPDATE, 0x00, 0,     [bytes.bytesize].pack('N')
			h = Frame.new FrameTypes::WINDOW_UPDATE, 0x00, f.sid, [bytes.bytesize].pack('N')
			send_frame g
			send_frame h

			@streams[f.sid] << bytes
			emit_request f.sid, @streams[f.sid] if f.flag? FLAG_END_STREAM
		end

		def handle_headers f
			# FIXME: if @streams[f.sid] is closed ...
			if @streams[f.sid]
				raise "no END_STREAM on trailing headers" unless f.flag? FLAG_END_STREAM
			else
				# FIXME: is this the right stream-id?
				@streams[f.sid] = Stream.new(@default_window_size)
				# read the header block
				@hpack.parse_block(f.payload) do |k, v|
					@streams[f.sid][k] << v
				end
			end

			if !@goaway
				# if end-of-stream, emit the request
				emit_request f.sid, @streams[f.sid] if f.flag? FLAG_END_STREAM
			end
		end

		def handle_settings f
			# FIXME: if f.sid > 0 ...
			if f.flag? FLAG_ACK
				# TODO
			else
				hash = Settings.pairs_from(f)
				hash.each_pair do |k, v|
					case k
					when Settings::HEADER_TABLE_SIZE
						@hpack.max_size_out = v
					when Settings::ENABLE_PUSH
						raise ConnectionError.new(PROTOCOL_ERROR, "ENABLE_PUSH must be 0 or 1, received #{v}") unless v == 0 or v == 1 # FIXME
						@push_to_client = (v == 1)
					when Settings::MAX_CONCURRENT_STREAMS
						@max_streams = v
					when Settings::INITIAL_WINDOW_SIZE
						raise ConnectionError.new(FLOW_CONTROL_ERROR, "INITIAL_WINDOW_SIZE too large #{v}") if v > 0x7fffffff # FIXME
						@default_window_size = v
					when Settings::MAX_FRAME_SIZE
						raise ConnectionError.new(PROTOCOL_ERROR, "MAX_FRIM_SIZE out of bounds #{v}") if v < 0x4000 or v > 0xffffff # FIXME
						@max_frame_size = v
					when Settings::MAX_HEADER_LIST_SIZE
						# FIXME ???
					end
				end
				#send ACK
				# FIXME: ensure we only send this after the initial settings
				g = Frame.new FrameTypes::SETTINGS, FLAG_ACK, 0, ''
				send_frame g
			end
		end

		def handle_ping f
			# FIXME: if f.sid > 0 ...
			raise ConnectionError.new(PROTOCOL_ERROR, "received PING on stream id #{f.sid}") unless f.sid == 0
			raise ConnectionError.new(FRAME_SIZE_ERROR, "PING payload must be 8 bytes, received #{f.payload.bytesize}") unless f.payload.bytesize == 8
			if f.flag? FLAG_ACK
				idx = @pings.find_index f.payload
				if idx
					@logger.info "ping pong #{f.payload.inspect}"
					@pings.delete_at idx
				else
					# FIXME
					raise ConnectionError.new(PROTOCOL_ERROR, "unexpected PONG or incorrect payload #{f.payload.inspect}")
				end
			else
				# send pong
				g = Frame.new FrameTypes::PING, FLAG_ACK, 0, f.payload
				send_frame g
			end
		end

		def handle_goaway f
			raise ConnectionError.new(PROTOCOL_ERROR, "received GOAWAY on stream id #{f.sid}") unless f.sid == 0
			# TODO
			@goaway, error_code, debug_data = f.payload.unpack('NNa*')
			@logger.info "received GOAWAY (last stream ID=#{@goaway}, error_code=0x#{error_code.to_s 16}"
			@logger.info debug_data.inspect if debug_data && debug_data.bytesize > 0

			shut_down unless @shutting_down
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
