# encoding: BINARY
# vim: ts=2 sts=2 sw=2 expandtab

def hex(s) s.nil? ? 'nil' : "[#{s.bytesize}]:#{s.bytes.map{|b|'%02X' % b}.join '.'}" end
def ansi(n, *args) args.each {|arg| puts "\x1B[#{n}m#{arg}\x1B[0m" }; end
def black(*args)   ansi 30, *args; end
def red(*args)     ansi 31, *args; end
def green(*args)   ansi 32, *args; end
def brown(*args)   ansi 33, *args; end
def yellow(*args)  ansi 93, *args; end
def blue(*args)    ansi 94, *args; end
def magenta(*args) ansi 35, *args; end
def cyan(*args)    ansi 36, *args; end
def silver(*args)  ansi 37, *args; end
def white(*args)   ansi 97, *args; end
def flg(f)
  s = "#{f.to_s 16}"
  a = []
  n = 1
  while n <= f
    if (f & n) == n
      a << ('%02X' % n)
    end
    n <<= 1
  end
  "#{f.to_s 16}[#{a.join '|'}]"
end
def frm(f)
  t = RUBYH2::FrameTypes.constants.find {|t| f.type == RUBYH2::FrameTypes.const_get(t) }
  t ||= f.type
  "<#{t}: flags=#{flg f.flags} stream=#{f.sid} payload=#{hex f.payload}>"
end

require 'thread'
require 'zlib'
require 'stringio'

require_relative 'frame-deserialiser'
require_relative 'frame-serialiser'
require_relative 'frame-types'
require_relative 'headers-hook'
require_relative 'settings'
require_relative 'errors'
require_relative 'hpack'

require_relative 'http-request'
require_relative 'stream'

module RUBYH2

  PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

  class HTTPAgent
    FLAG_END_STREAM  = 0x1
    FLAG_ACK         = 0x1
    FLAG_END_HEADERS = 0x4
    FLAG_PADDED      = 0x8
    FLAG_PRIORITY    = 0x20

    include Error

    def initialize is_server, logger
      # machinery state
      @is_server = is_server
      @request_proc = nil
      @hook = HeadersHook.new
      @hook.on_frame {|f| recv_frame f }
      @hpack = HPack.new
      @logger = logger
      # H2 state
      @window_queue = {}
      @first_frame_in = true
      @first_frame_out = true
      @streams = {}
      @default_window_size = 65535
      @window_size = @default_window_size
      @max_frame_size = 16384
      @max_streams = nil
      @push_to_peer = true
      @ext__send_gzip = true  # are we config'd to send gzip data?
      @ext__peer_gzip = false # is peer config'd to accept gzip data?
      @ext__recv_gzip = true  # are we config'd to accept gzip data?
      @ext__veto_gzip = false # set if peer doesn't gzip right
      @ext__sent_dropped_frame = {}
      @ext__peer_dropped_frame = {}
      # other settings
      @pings = []
      @goaway = false
      @last_stream = 0 # last incoming stream handed up to application
      @shutting_down = false

      @send_lock = Mutex.new
      @shutdown_lock = Mutex.new
    end

    def inspect
      "\#<HTTPAgent @window_queue=#{@window_queue.inspect}, @streams=#{@streams.inspect}, @default_window_size=#{@default_window_size.inspect}, @window_size=#{@window_size.inspect}, @max_frame_size=#{@max_frame_size.inspect}, @max_streams=#{@max_streams.inspect}, @push_to_peer=#{@push_to_peer.inspect}>"
    end

    attr_reader :push_to_peer

    ##
    # Set the callback to be invoked when a HTTP request arrives.
    #
    def on_request &b
      @request_proc = b
      self
    end

    ##
    # wrap a TCPSocket
    # e.g.:
    #
    #   require 'socket'
    #   server = TCPServer.new 4567
    #   http_client.wrap server.accept
    #
    def wrap s
      @sil = FrameSerialiser.new {|b|
cyan "@sil: _write #{hex b}"
_write s, b rescue nil }
      dsil = FrameDeserialiser.new
      dsil.on_frame {|f|
brown "dsil: received #{frm f}"
@hook << f }
      handle_prefaces s
      #send_frame Settings.frame_from({Settings::INITIAL_WINDOW_SIZE => 0x7fffffff, Settings::ACCEPT_GZIPPED_DATA => 1}), true
      #send_frame Settings.frame_from({Settings::INITIAL_WINDOW_SIZE => 0x7fffffff}), true
      send_frame Settings.frame_from({Settings::INITIAL_WINDOW_SIZE => 0x20000, Settings::MAX_FRAME_SIZE => 0x4000}), true
      loop do
        bytes = begin
          s.readpartial(4*1024*1024)
        rescue EOFError
          nil
        end
        if bytes.nil? or bytes.empty?
          if s.is_a? OpenSSL::SSL::SSLSocket
            @logger.info "client disconnected from #{s.io.remote_address.inspect_sockaddr}"
          else
            @logger.info "client disconnected from #{s.remote_address.inspect_sockaddr}"
          end
          break
        end
red "read #{hex bytes}"
        dsil << bytes
        Thread.pass
      end
    ensure
      s.close rescue nil
    end

    ##
    # Shut down the connection.
    def shut_down
      @shutdown_lock.synchronize {
        return if @shutting_down
        @shutting_down = true
      }
      g = Frame.new FrameTypes::GOAWAY, 0x00, 0, [@last_stream,NO_ERROR].pack('NN')
      send_frame g
    end

    ##
    # deliver HTTPResponse
    def deliver r
      @shutdown_lock.synchronize {
        raise "delivering response after GOAWAY" if @shutting_down # FIXME
      }
blue "deliver #{r.inspect}"

      # create headers
      all_headers = {':status' => r.status.to_s}
      r_headers = r.headers.dup
      r_headers.delete ':status'
      all_headers.merge! r_headers
      hblock = @hpack.create_block all_headers
      # split header block into chunks and deliver
      chunks = hblock.scan(/.{1,#{@max_frame_size}}/m).map{|c| {type: FrameTypes::CONTINUATION, flags: 0, bytes: c} }
      if chunks.empty?
        # I cast no judgement here, but shouldn't there be some headers..?
        chunks << {type: FrameTypes::HEADERS, flags: FLAG_END_HEADERS, bytes: String.new.b}
      else
        chunks.first[:type] = FrameTypes::HEADERS
        chunks.last[:flags] |= FLAG_END_HEADERS
      end
      # without data, the HEADERS ends the stream
      if r.body.empty?
        chunks.last[:flags] |= FLAG_END_STREAM
      end
      # pad out to %256 bytes if required
      _pad chunks.last if r.pad?
      # send the headers frame(s)
      chunks.each do |chunk|
        g = Frame.new chunk[:type], chunk[:flags], r.stream, chunk[:bytes]
        send_frame g
      end

      # create data
      if !r.body.empty?
        chunks = []
        if send_gzip?
          type = FrameTypes::GZIPPED_DATA
          bytes = r.body.b

          until bytes.empty?
            # binary search for biggest data chunk that fits when gzipped
            left = 0
            right = bytes.bytesize
            maxright = right
            best = nil
            rest = bytes

            loop do
              gzipped = ''.b
              gzip = Zlib::GzipWriter.new(StringIO.new gzipped)
              gzip.write bytes[0...right]
              gzip.close

              rest = bytes[right..-1]

              if gzipped.bytesize > @max_frame_size
                # try a smaller sample
                maxright = right
                right = maxright - (maxright - left) / 2
                # is this a good as we'll get?
                break if right == left
              elsif gzipped.bytesize == @max_frame_size
                # perfect!
                best = gzipped
                break
              else
                # try a bigger sample
                best = gzipped

                left = right
                right = maxright - (maxright - left) / 2
                # is this a good as we'll get?
                break if right == left
              end
            end
            bytes = rest

            # create chunk
            chunk = {flags: 0, bytes: best}
            # pad out to %256 bytes if required
            _pad chunk if r.pad?
            # add to list
            chunks << chunk
          end
        else
          type = FrameTypes::DATA
          chunks = r.body.b.scan(/.{1,#{@max_frame_size}}/m).map{|c| {flags: 0, bytes: c} }
          # pad out to %256 bytes if required
          _pad chunks.last if r.pad?
        end
        chunks.last[:flags] |= FLAG_END_STREAM
        chunks.each do |chunk|
          g = Frame.new type, chunk[:flags], r.stream, chunk[:bytes]
          send_frame g
        end
      end

      # half-close
      @streams[r.stream].close_local!
    end

    # returns truthy if the given frame carries HTTP semantics
    # (so has to be sent in order)
    def semantic_frame? f
      f.type == FrameTypes::DATA || f.type == FrameTypes::HEADERS || f.type == FrameTypes::CONTINUATION || f.type == FrameTypes::GZIPPED_DATA
    end

    # Are we configured to accept GZIPPED_DATA frames from this peer?
    # Takes into account peer's apparent ability to correctly send gzip.
    def accept_gzip?
      return if @ext__veto_gzip
      @ext__recv_gzip
    end
    # tell the peer we'll accept GZIPPED_DATA frames
    def accept_gzip!
      return if @ext__veto_gzip
      if !@ext__recv_gzip
        send_frame Settings.frame_from({Settings::ACCEPT_GZIPPED_DATA => 1})
        @ext__recv_gzip = true
      end
    end
    # tell the peer we don't accept GZIPPED_DATA frames
    def no_accept_gzip!
      return if @ext__veto_gzip
      if @ext__recv_gzip
        send_frame Settings.frame_from({Settings::ACCEPT_GZIPPED_DATA => 0})
        @ext__recv_gzip = false
      end
    end

    # Are we configured to send GZIPPED_DATA frames to this peer?
    # Takes into account peer's settings for receiving them.
    def send_gzip?
      return if !@ext__peer_gzip
      @ext__send_gzip
    end
    # application lets us send GZIPPED_DATA frames to this peer
    def send_gzip!
      if !@ext__send_gzip
        @ext__send_gzip = true
      end
    end
    # application won't let us send GZIPPED_DATA frames to this peer
    def no_send_gzip!
      if @ext__send_gzip
        @ext__send_gzip = false
      end
    end

  private

    def veto_gzip!
      return if @ext__veto_gzip
      if @ext__recv_gzip
        send_frame Settings.frame_from({Settings::ACCEPT_GZIPPED_DATA => 0})
        @ext__veto_gzip = true
      end
    end

    def _pad hash, modulus=256
      len = hash[:bytes].bytesize
      rem = (modulus - (len % modulus)) - 1
      # don't overflow the frame!
      if len + rem > @max_frame_size
        rem = @max_frame_size - len - 1
      end
      if rem >= 0
        padlen = [rem].pack('C')
        padding = ''
        padding = [0].pack('C') * rem if rem > 0
        hash[:flags] |= FLAG_PADDED
        hash[:bytes] = padlen + hash[:bytes] + padding
      end
      hash
    end

    def _write sock, bytes
      bytes.force_encoding Encoding::BINARY
      #sock.print bytes
      until bytes.empty?
        sent = sock.write bytes
        #sent = sock.send bytes, 0
        bytes = bytes[sent..-1]
      end
      #sock.flush
    end


    def handle_prefaces s
      preface = nil
      t0 = Thread.new do
        preface = String.new.b
        while preface.length < 24
          preface << s.readpartial(24 - preface.length)
        end
      end
      if !@is_server
        t1 = Thread.new do
          _write s, PREFACE
        end
      end
      t0.join
      raise ConnectionError.new(PROTOCOL_ERROR, 'invalid preface') if preface != PREFACE
      if !@is_server
        t1.join
      end
    end

    def send_frame g, is_first_settings=false
      if is_first_settings
        # Unset @first_frame_out and transmit said first frame, atomically
        @send_lock.synchronize do
          @first_frame_out = false
          _do_send_frame g
        end
      else
        # FIXME: this is horrible
        # Spin-lock on @first_frame_out being unset.
        # Note that writes to @first_frame_out are sync'd by @send_lock
        wait = false
        @send_lock.synchronize { wait = @first_frame_out }
        while wait
          sleep 0.1
          @send_lock.synchronize { wait = @first_frame_out }
        end
        # Actually transmit the frame, atomically.
        @send_lock.synchronize do
          _do_send_frame g
        end
      end
    end

    def _do_send_frame g
      if !semantic_frame? g
        @sil << g
      elsif g.sid == 0
        # FIXME: assumes .type != DATA, etc.
        @sil << g
      else
        s = @streams[g.sid]
        s = @streams[g.sid] = Stream.new(@default_window_size) if !s
        q = @window_queue[g.sid]
        if q && !q.empty?
          # there's a queue; wait for a WINDOW_UPDATE
          q << g
        elsif g.type == FrameTypes::DATA
          b = g.payload_size
          if @window_size >= b && s.window_size >= b
            @window_size -= b
            s.window_size -= b
            @sil << g
          else
            @window_queue[g.sid] ||= []
            @window_queue[g.sid] << g
          end
        else
          @sil << g
        end
      end
    end

    # triggered when a new H2 frame arrives
    def recv_frame f
      if @first_frame_in
        # first frame has to be settings
        # FIXME: make sure this is the actual settings, not the ACK to ours
        raise ConnectionError.new(PROTOCOL_ERROR, 'invalid preface - no SETTINGS') if f.type != FrameTypes::SETTINGS
        @first_frame_in = false
      end

      if @goaway
        case f.type
        when FrameTypes::DATA
        when FrameTypes::HEADERS
        when FrameTypes::PUSH_PROMISE
        when FrameTypes::CONTINUATION
        else
          # FIXME
          @logger.warn "Ignoring frame 0x#{f.type.to_s 16} after GOAWAY"
          return
        end
      end

      case f.type
      when FrameTypes::DATA
        handle_data f
      when FrameTypes::HEADERS
        handle_headers f
      when FrameTypes::PRIORITY
        # TODO
      when FrameTypes::RST_STREAM
        # TODO
      when FrameTypes::SETTINGS
        handle_settings f
      when FrameTypes::PUSH_PROMISE
        # TODO
      when FrameTypes::PING
        handle_ping f
      when FrameTypes::GOAWAY
        handle_goaway f
      when FrameTypes::WINDOW_UPDATE
        handle_window_update f
      when FrameTypes::CONTINUATION
        # never emitted by the Hook
        raise 'unexpected CONTINUATION frame'

      # EXTENSION FRAME HANDLING
      when FrameTypes::GZIPPED_DATA
        handle_gzipped_data f
      when FrameTypes::DROPPED_FRAME
        handle_dropped_frame f
      else
        # ignore unrecognised/extension frames
        drop_frame f
      end
    end

    # tell the peer we ignored it
    def drop_frame f
      if !@ext__sent_dropped_frame[f.type]
        @ext__sent_dropped_frame[f.type] = true
        g = Frame.new FrameTypes::DROPPED_FRAME, 0x00, 0, [f.type].pack('C')
        send_frame g
      end
    end

    def handle_dropped_frame f
      raise ConnectionError.new(PROTOCOL_ERROR, "DROPPED_FRAME must be sent on stream 0, received #{f.sid}") if f.sid != 0
      raise ConnectionError.new(PROTOCOL_ERROR, "DROPPED_FRAME payload must be exactly 1 byte, received #{f.payload.bytesize}") if f.payload.bytesize != 1
      type = f.payload.bytes.first
      @logger.info "peer dropped extension frame type 0x#{type.to_s 16}"
      @ext__peer_dropped_frame[type] = true
    end

    # triggered when a completed HTTP request arrives
    # (farms it off to the registered callback)
    def emit_request sid, stream
      # NB: this function only invoked once we get an END_STREAM flag
      stream.close_remote!
      @last_stream = sid
      # FIXME
      headers = stream.headers
      @request_proc.call HTTPRequest.new( sid, headers.delete(':method'), headers.delete(':path'), 'HTTP/2', headers, stream.body )
    end

    def strip_padding bytes
      ints = bytes.bytes
      pad_length = ints.shift
      rst_length = ints.length
      raise ConnectionError.new(PROTOCOL_ERROR, "Pad Length #{pad_length} exceeds frame payload size #{rst_length+1}") if pad_length > rst_length
      ints[0...rst_length-pad_length].pack('C*')
    end

    def extract_priority bytes
      stream, weight, bytes = bytes.unpack('NCa*')
      exclusive = (stream & 0x80000000) == 0x80000000
      stream &= 0x7fffffff
      [{exclusive:exclusive, stream:stream, weight:weight}, bytes]
    end

    def handle_data f
      raise ConnectionError.new(PROTOCOL_ERROR, "DATA must be sent on stream >0") if f.sid == 0

      stream = @streams[f.sid]
      raise SemanticError.new("DATA frame with invalid stream id #{f.sid}") unless stream
      raise StreamError.new(STREAM_CLOSED, "DATA frame received on (half-)closed stream #{f.sid}") unless stream.open_remote?

      return if @goaway

      bytes = f.payload
      bytes = strip_padding(bytes) if f.flag? FLAG_PADDED

      # never run out of window space
      g = Frame.new FrameTypes::WINDOW_UPDATE, 0x00, 0,     [bytes.bytesize].pack('N')
      h = Frame.new FrameTypes::WINDOW_UPDATE, 0x00, f.sid, [bytes.bytesize].pack('N')
      send_frame g
      send_frame h

      stream << bytes
      emit_request f.sid, stream if f.flag? FLAG_END_STREAM
    end

    def handle_gzipped_data f
      #raise ConnectionError.new(PROTOCOL_ERROR, "GZIPPED_DATA cannot be sent without SETTINGS_ACCEPT_GZIP_DATA") unless accept_gzip
      if !accept_gzip?
        drop_frame f
        return
      end

      raise ConnectionError.new(PROTOCOL_ERROR, "GZIPPED_DATA must be sent on stream >0") if f.sid == 0

      stream = @streams[f.sid]
      raise SemanticError.new("GZIPPED_DATA frame with invalid stream id #{f.sid}") unless stream
      raise StreamError.new(STREAM_CLOSED, "GZIPPED_DATA frame received on (half-)closed stream #{f.sid}") unless stream.open_remote?

      return if @goaway

      bytes = f.payload
      bytes = strip_padding(bytes) if f.flag? FLAG_PADDED

      # never run out of window space
      g = Frame.new FrameTypes::WINDOW_UPDATE, 0x00, 0,     [bytes.bytesize].pack('N')
      send_frame g

      inflated_bytes = nil
      gunzip = Zlib::GzipReader.new(StringIO.new bytes)
      begin
        inflated_bytes = gunzip.read
      rescue Zlib::Error => e
        # bad gzip!
        raise StreamError.new(DATA_ENCODING_ERROR, e.to_s)
      ensure
        veto_gzip! if inflated_bytes.nil?
      end

      # note: only update the frame window if gunzip succeeddededd
      h = Frame.new FrameTypes::WINDOW_UPDATE, 0x00, f.sid, [bytes.bytesize].pack('N')
      send_frame h

      stream << inflated_bytes
      emit_request f.sid, stream if f.flag? FLAG_END_STREAM
    end

    def handle_headers f
      stream = @streams[f.sid]
      if stream
        raise SemanticError.new("no END_STREAM on trailing headers") unless f.flag? FLAG_END_STREAM #FIXME: malformed => StreamError:PROTOCOL_ERROR ?
        raise StreamError.new(STREAM_CLOSED, "HEADER frame received on (half-)closed stream #{f.sid}") unless stream.open_remote? # FIXME
      else
        raise ConnectionError.new(PROTOCOL_ERROR, "HEADERS must be sent on stream >0") if f.sid == 0
        raise ConnectionError.new(PROTOCOL_ERROR, "new stream id #{f.sid} not greater than previous stream id #{@last_stream}") if f.sid <= @last_stream
        raise ConnectionError.new(PROTOCOL_ERROR, "streams initiated by client must be odd, received #{f.sid}") if f.sid % 2 != 1
        @streams[f.sid] = Stream.new(@default_window_size)
        # read the header block
        bytes = f.payload
        bytes = strip_padding(bytes) if f.flag? FLAG_PADDED
        priority, bytes = extract_priority(bytes) if f.flag? FLAG_PRIORITY
yellow "priority: #{priority.inspect}"
        # TODO: handle priority?
        @hpack.parse_block(bytes) do |k, v|
yellow "  [#{k}]: [#{v}]"
          @streams[f.sid][k] << v
        end
yellow "--"
      end

      # if end-of-stream, emit the request
      emit_request f.sid, @streams[f.sid] if !@goaway and f.flag? FLAG_END_STREAM
    end

    def handle_settings f
      raise ConnectionError.new(PROTOCOL_ERROR, "SETTINGS must be sent on stream 0, received #{f.sid}") if f.sid != 0

      if f.flag? FLAG_ACK
        # TODO
      else
        hash = Settings.pairs_from(f)
        hash.each_pair do |k, v|
          case k
          when Settings::HEADER_TABLE_SIZE
            @hpack.max_size_out = v
          when Settings::ENABLE_PUSH
            raise ConnectionError.new(PROTOCOL_ERROR, "ENABLE_PUSH must be 0 or 1, received #{v}") unless v == 0 or v == 1 # FIXME
            @push_to_peer = (v == 1)
          when Settings::MAX_CONCURRENT_STREAMS
            @max_streams = v
          when Settings::INITIAL_WINDOW_SIZE
            raise ConnectionError.new(FLOW_CONTROL_ERROR, "INITIAL_WINDOW_SIZE too large #{v}") if v > 0x7fffffff # FIXME
            @default_window_size = v
          when Settings::MAX_FRAME_SIZE
            raise ConnectionError.new(PROTOCOL_ERROR, "MAX_FRAME_SIZE out of bounds #{v}") if v < 0x4000 or v > 0xffffff # FIXME
            @max_frame_size = v
          when Settings::MAX_HEADER_LIST_SIZE
            # FIXME ???

          when Settings::ACCEPT_GZIPPED_DATA
            raise ConnectionError.new(PROTOCOL_ERROR, "ACCEPT_GZIPPED_DATA must be 0 or 1, received #{v}") unless v == 0 or v == 1 # FIXME
            @ext__peer_gzip = (v == 1)
          end
        end
        #send ACK
        # FIXME: ensure we only send this after the initial settings
        g = Frame.new FrameTypes::SETTINGS, FLAG_ACK, 0, ''
        send_frame g
      end
    end

    def handle_ping f
      # FIXME: if f.sid > 0 ...
      raise ConnectionError.new(PROTOCOL_ERROR, "received PING on stream id #{f.sid}") unless f.sid == 0
      raise ConnectionError.new(FRAME_SIZE_ERROR, "PING payload must be 8 bytes, received #{f.payload.bytesize}") unless f.payload.bytesize == 8
      if f.flag? FLAG_ACK
        idx = @pings.find_index f.payload
        if idx
          @logger.info "ping pong #{f.payload.inspect}"
          @pings.delete_at idx
        else
          # FIXME
          raise ConnectionError.new(PROTOCOL_ERROR, "unexpected PONG or incorrect payload #{f.payload.inspect}")
        end
      else
        # send pong
        g = Frame.new FrameTypes::PING, FLAG_ACK, 0, f.payload
        send_frame g
      end
    end

    def handle_goaway f
      raise ConnectionError.new(PROTOCOL_ERROR, "received GOAWAY on stream id #{f.sid}") unless f.sid == 0
      # TODO
      @goaway, error_code, debug_data = f.payload.unpack('NNa*')
      @logger.info "received GOAWAY (last stream ID=#{@goaway}, error_code=0x#{error_code.to_s 16})"
      @logger.info debug_data.inspect if debug_data && debug_data.bytesize > 0

      shut_down
    end

    def handle_window_update f
      # FIXME: stream states?

      raise 'connection:FRAME_SIZE_ERROR' unless f.payload.bytesize == 4
      increment = f.payload.unpack('N').first

      #raise 'PROTOCOL_ERROR' if increment & 0x80000000 == 0x80000000
      increment &= 0x7fffffff

      raise 'stream:PROTOCOL_ERROR' if increment == 0

      if f.sid != 0
        @streams[f.sid].window_size += increment
      else
        @window_size += increment
      end

      catch :CONNECTION_EXHAUSTED do
        @window_queue.each_pair do |sid, queue|
          s = @streams[sid]
          # note: sid can never be zero, since frames only
          #       enter the queue because of a blocked DATA
          #       (which isn't allowed on stream 0)
          raise unless s # FIXME
          catch :STREAM_EXHAUSED do
            until queue.empty?
              f = queue.first
              b = (f.type == FrameTypes::DATA ? f.payload_size : 0)
              throw :CONNECTION_EXHAUSED if @window_size < b
              throw :STREAM_EXHAUSTED if s.window_size < b
              queue.shift
              @window_size -= b
              s.window_size -= b
              @sil << f
            end
          end# :STREAM_EXHAUSTED
        end
      end# :CONNECTION_EXHAUSTED
    end

  end

end

