# vim: ts=2 sts=2 sw=2

require_relative 'frame-deserialiser'
require_relative 'frame-types'
require_relative 'headers-hook'
require_relative 'hpack'

class HTTPClient
	FLAG_END_STREAM = 0x1

	def initialize
		@request_proc = nil
		@streams = {}
		@hook = HeadersHook.new
		@hook.on_frame {|f| _recv_frame f }
		@hook.on_stream {|sid, flags, hblock| _recv_stream sid, flags, hblock }
		@hpack = ::RUBYH2_HPack.new
	end
	def on_request &b
		@request_proc = b
		self
	end
	def wrap s
		dsil = FrameDeserialiser.new
		dsil.on_frame {|f| @hook << f }
		loop do
			dsil << s.read
		end
	end
	def _recv_stream sid, flags, hblock
		if @streams[sid]
			raise "no END_STREAM on trailing headers" if flags & FLAG_END_STREAM != FLAG_END_STREAM
		else
			@streams[sid] = {
				headers: Hash.new{|h,k| h[k] = [] },
				body: String.new,
			}
		end
		# read the header block
		@hpack.parse_block(hblock) do |k, v|
			@streams[sid][:headers][k] << v
		end
		# if end-of-stream, emit the request
		if flags & FLAG_END_STREAM == FLAG_END_STREAM
			_emit_request @streams[sid]
		end
	end
	def _recv_frame f
		# TODO: f.type, f.flags, f.sid, f.payload
		# note: f.type != HEADERS
		# FIXME: need better HTTP semantics
		case f.type
		when FrameTypes::DATA
			@streams[f.sid][:body] << f.payload
			_emit_request @streams[f.sid] if f.flags & FLAG_END_STREAM == FLAG_END_STREAM
		#when FrameTypes::HEADERS
		when FrameTypes::PRIORITY
			# TODO
		when FrameTypes::RST_STREAM
			# TODO
		when FrameTypes::SETTINGS
			# TODO
		when FrameTypes::PUSH_PROMISE
			# TODO
		when FrameTypes::PING
			# TODO
		when FrameTypes::GOAWAY
			# TODO
		when FrameTypes::WINDOW_UPDATE
			# TODO
		#when FrameTypes::CONTINUATION
		#else: ignore extension frames
		end
	end
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

