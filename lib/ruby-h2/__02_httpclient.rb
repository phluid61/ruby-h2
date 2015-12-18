# vim: ts=2 sts=2 sw=2

require_relative 'frame-deserialiser'
require_relative 'frame-types'
require_relative 'headers-hook'
require_relative 'hpack'

class HTTPClient
	FLAG_END_STREAM = 0x1
	FLAG_ACK        = 0x1

	def initialize
		# machinery state
		@request_proc = nil
		@hook = HeadersHook.new
		@hook.on_frame {|f| _recv_frame f }
		@hpack = ::RUBYH2_HPack.new
		# H2 state
		@streams = {}
		@default_window_size = 65535
		@window_size = @default_window_size
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
		dsil = FrameDeserialiser.new
		dsil.on_frame {|f| @hook << f }
		loop do
			dsil << s.read
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
				body: String.new,
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
			# apply k, v
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

		if f.sid
			@streams[f.sid][:window_size] += increment
		else
			@window_size += increment
		end
	end

	# triggered when a completed HTTP request arrives
	# (farms it off to the registered callback)
	def _emit_request h
		# FIXME
		@request_proc.call HTTPRequest.new( h[:headers][':method'], h[:header][':path'], 'HTTP/2', h[:headers], h[:body] )
	end
end

class HTTPRequest
	def initialize method, path, version, headers, body
		@method  = method
		@path    = path
		@version = version
		@headers = headers
		@body    = body
	end
	attr_reader :method
	attr_reader :path
	attr_reader :version
	attr_reader :headers
	attr_reader :body
end

class HTTPResponse
	def initialize status=nil
		@status  = status
		@headers = {}
		@body    = String.new
	end

	attr_accessor :status

	attr_reader :headers
	def []= h, v
		@headers[h] = v
	end

	def [] h
		@headers[h]
	end

	attr_reader :body
	def << s
		@body << s
	end
end

