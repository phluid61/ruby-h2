# encoding: BINARY
# vim: ts=2 sts=2 sw=2 expandtab

module RUBYH2

  class HTTPMessage
    def initialize stream, virtual_headers, headers=nil, body=nil
      @stream = stream
      @body   = body ? body.b : String.new.b
      @pad = false

      # Note: ensure virtual headers are first in @headers
      headers = headers ? headers.dup : {}
      @headers = {}
      virtual_headers.each do |h|
        m = h.sub /^:/, ''
        h = ":#{m}"
        define_method(:"#{m}") { @headers[h] }
        @headers[h] = headers.delete(h) if headers
      end
      @headers.merge! headers
    end

    attr_reader :stream

    attr_reader :headers
    def []= h, v
      @headers[h] = v.to_s
    end

    def [] h
      @headers[h]
    end

    attr_reader :body
    def << s
      @body << s if s
    end

    def pad?
      @pad
    end
    def pad!
      @pad = true
    end
    def no_pad!
      @pad = false
    end
  end

end

