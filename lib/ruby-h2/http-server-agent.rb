# encoding: BINARY
# vim: ts=2 sts=2 sw=2 expandtab

require_relative 'http-agent'

require_relative 'settings'
require_relative 'errors'

require_relative 'http-request'

module RUBYH2

  class HTTPServerAgent < HTTPAgent

    def initialize logger
      super logger
      @request_proc = nil
    end

    ##
    # Set the callback to be invoked when a HTTP request arrives.
    #
    def on_request &b
      @request_proc = b
      self
    end

    def respond s, q
      deliver s, q
      s
    end

    def push r, q
      # FIXME
      raise unless push_to_peer
      s = create_push_stream
      reserve_stream s
      deliver s, r
      deliver s, q
      s
    end

  private

    def handle_prefaces s
      preface = String.new.b
      while preface.length < 24
        preface << s.readpartial(24 - preface.length)
      end
      # RFC7540, Section 3.5
      # "Clients and servers MUST treat an invalid connection preface
      #  as a connection error (Section 5.4.1) of type
      #  PROTOCOL_ERROR."
      raise ConnectionError.new(PROTOCOL_ERROR, 'invalid preface') if preface != PREFACE
    end

    def mandatory_pseudoheaders
      %w(:method :scheme :path)
    end

    def allowed_pseudoheader? h
      h == ':method' || h == ':scheme' || h == ':path' || h == ':authority'
    end

    def ok_incoming_streamid? sid
      raise ConnectionError.new(PROTOCOL_ERROR, "streams initiated by client must be odd, received #{sid}") if sid % 2 != 1
      true
    end

    def _do_emit sid, headers, body
      @request_proc.call sid, HTTPRequest.new( headers.delete(':method'), headers.delete(':path'), headers, body )
    end

    def handle_push_promise f
      # RFC 7540, Section 8.2
      # "A client cannot push. Thus, servers MUST treat the receipt
      #  of a PUSH_PROMISE frame as a connection error (Section
      #  5.4.1) of type PROTOCOL_ERROR."
      raise ConnectionError.new(PROTOCOL_ERROR, "received forbidden PUSH_PROMISE frame from client")
    end

  end

end

