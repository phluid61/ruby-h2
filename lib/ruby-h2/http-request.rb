# encoding: BINARY
# vim: ts=2 sts=2 sw=2 expandtab

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

end

