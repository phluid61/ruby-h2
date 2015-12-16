
class HTTPClient
	def initialize
		@request_block = nil
	end
	def on_request &b
		@request_block = b
		self
	end
	def wrap s
		#s.read
		#if (is_request)
		#  @request_block[ HTTPRequest.new(method, path, version, headers, body) ]
		#end
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

