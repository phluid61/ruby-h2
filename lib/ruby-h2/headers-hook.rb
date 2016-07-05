# encoding: BINARY
# vim: ts=2 sts=2 sw=2 expandtab

require_relative 'frame-types'
require_relative 'errors'

module RUBYH2
  class HeadersHook
    include FrameTypes

    FLAG_END_HEADERS = 0x4

    def initialize
      @frame_handlers = []
      @headers = nil
    end

    # block gets called whenever a frame arrives
    def on_frame &handler
      @frame_handlers << handler
    end

    # call this with every arriving frame
    def << frame
      if @headers
        intercept_continuation frame
      else
        intercept_header frame
      end
    end

    # :nodoc:
    def intercept_continuation frame
      if frame.type == CONTINUATION
        @headers << frame.payload
        maybe_continue frame
      else
        # RFC 7540, Section 6.2 (and others)
        # "A receiver MUST treat the receipt of any other type of frame
        #  or a frame on a different stream as a connection error
        #  (Section 5.4.1) of type PROTOCOL_ERROR."
        raise ConnectionError.new(Error::PROTOCOL_ERROR, "expected CONTINUATION frame, got 0x#{'%X' % frame.type}")
      end
    end

    # :nodoc:
    def intercept_header frame
        case frame.type
        when HEADERS
          @headers = frame
          # TODO: extract padding,priority,...
          maybe_continue frame
        when CONTINUATION
          # RFC 7540, 6.10
          # "A CONTINUATION frame MUST be preceded by a HEADERS,
          #  PUSH_PROMISE or CONTINUATION frame without the END_HEADERS
          #  flag set. A recipient that observes a violation of this
          #  rule MUST respond with a connection error (Section 5.4.1)
          #  of type PROTOCOL_ERROR."
          raise ConnectionError.new(Error::PROTOCOL_ERROR, 'unexpected CONTINUATION frame')
        else
          emit_frame frame
        end
    end

    # :nodoc:
    def maybe_continue frame
      if frame.flag? FLAG_END_HEADERS
        emit_frame @headers
        @headers = nil
      end
    end

    # :nodoc:
    def emit_frame frame
      @frame_handlers.each do |h|
        begin
          h.call frame
        rescue Exception => x
          # FIXME
          STDERR.puts x, *x.backtrace.map{|bt|"\t#{bt}"}
        end
      end
    end
  end
end

