# encoding: BINARY
# vim: ts=2 sts=2 sw=2 expandtab

module RUBYH2

  class HTTPMessage
    def initialize pseudoheaders, headers=nil, body=nil
      @body   = body ? body.b : String.new.b
      @pad = false

      # Note: ensure virtual headers are first in @headers
      headers = headers ? headers.dup : {}
      @headers = {}
      pseudoheaders.each do |h|
        m = h.sub(/^:/, '').downcase
        h = ":#{m}"
        singleton_class.send(:define_method, :"#{m}") { @headers[h] }
        singleton_class.send(:define_method, :"#{m}=") {|v| @headers[h] = v.to_s }
        @headers[h] = headers.delete(h) if headers && headers[h]
      end
      @headers.merge! headers
    end

    attr_reader :headers
    def []= h, v
      @headers[h.downcase] = v.to_s
    end

    def [] h
      @headers[h.downcase]
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

