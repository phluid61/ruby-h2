# encoding: BINARY
# vim: ts=2 sts=2 sw=2 expandtab

require_relative 'http-agent'

require_relative 'settings'
require_relative 'errors'

require_relative 'http-response'

module RUBYH2

  class HTTPClientAgent < HTTPAgent

    def initialize logger
      super logger
      @response_proc = nil
    end

    ##
    # Set the callback to be invoked when a HTTP response arrives.
    #
    def on_response &b
      @response_proc = b
      self
    end

    def request r
      s = create_request_stream
      open_stream s
      deliver s, r
      s
    end

  private

    def initial_settings
      settings = super
      settings[Settings::ENABLE_PUSH] = 0

      settings
    end

    def handle_prefaces s
      _write s, PREFACE
    end

    def mandatory_pseudoheaders
      %w(:status)
    end

    def allowed_pseudoheader? h
      h == ':status'
    end

    def ok_incoming_streamid? sid
      raise ConnectionError.new(PROTOCOL_ERROR, "streams initiated by server must be even, received #{sid}") if sid % 2 != 0
      true
    end

    def _do_emit sid, headers, body
      @response_proc.call sid, HTTPResponse.new( headers.delete(':status'), headers, body )
    end

    def handle_push_promise f
      # FIXME
      # RFC 7540, Section 6.6
      # "PUSH_PROMISE MUST NOT be sent if the SETTINGS_ENABLE_PUSH
      #  setting of the peer endpoint is set to 0. An endpoint that
      #  has set this setting and has received acknowledgement MUST
      #  treat the receipt of a PUSH_PROMISE frame as a connection
      #  error (Section 5.4.1) of type PROTOCOL_ERROR."
      raise ConnectionError.new(PROTOCOL_ERROR, "received PUSH_PROMISE frame when disabled")
    end

  end

end

