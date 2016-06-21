# encoding: BINARY
# vim: ts=2 sts=2 sw=2 expandtab

module RUBYH2

  module Error
    NO_ERROR            = 0x0
    PROTOCOL_ERROR      = 0x1
    INTERNAL_ERROR      = 0x2
    FLOW_CONTROL_ERROR  = 0x3
    SETTINGS_TIMEOUT    = 0x4
    STREAM_CLOSED       = 0x5
    FRAME_SIZE_ERROR    = 0x6
    REFUSED_STREAM      = 0x7
    CANCEL              = 0x8
    COMPRESSION_ERROR   = 0x9
    CONNECT_ERROR       = 0xa
    ENHANCE_YOUR_CALM   = 0xb
    INADEQUATE_SECURITY = 0xc
    HTTP_1_1_REQUIRED   = 0xd

    DATA_ENCODING_ERROR = 0xf000_0000 # Non-standard
  end

  class GenericError < StandardError
    def initialize code, msg=nil
      super msg
      @code = code
    end
    attr_reader :code
  end

  class ConnectionError < GenericError
  end

  class StreamError < GenericError
  end

  class SemanticError < StandardError
  end

end

