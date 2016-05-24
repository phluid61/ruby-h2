# encoding: BINARY
# vim: ts=2 sts=2 sw=2

module RUBYH2

	class HTTPRequest
		def initialize stream, method, path, version, headers, body
			@stream  = stream
			@method  = method
			@path    = path
			@version = version
			@headers = headers
			@body    = body
		end
		attr_reader :stream
		attr_reader :method
		attr_reader :path
		attr_reader :version
		attr_reader :headers
		attr_reader :body

		def inspect
			"\#<HTTPRequest @stream=#{@stream.inspect}, @method=#{@method.inspect}, @path=#{@path.inspect}, @version=#{@version.inspect}, @headers=#{@headers.inspect}, @body=#{@body.inspect}>"
		end
	end

	class HTTPResponse
		def initialize stream, status=nil
			@stream  = stream
			@status  = status
			@headers = {}
			@body    = String.new.b
		end

		attr_reader :stream

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
			@body << s if s
		end
	end

end

