# encoding: BINARY
# vim: ts=2 sts=2 sw=2 expandtab

module RUBYH2

  class HTTPResponse
    def initialize stream, status=nil
      @stream  = stream
      @status  = status
      @headers = {}
      @body    = String.new.b
      @pad = false
    end

    attr_reader :stream

    attr_accessor :status

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

