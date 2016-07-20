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
require_relative 'http-response'
require_relative 'priority-tree'
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

    def initialize logger=nil
      if logger.nil?
        logger = Object.new
        def logger.debug(*args) end
        def logger.info(*args) end
        def logger.warn(*args) end
        def logger.error(*args) end
        def logger.fatal(*args) end
      end

      @socket = nil
      # machinery state
      @cancel_proc = nil
      @hook = HeadersHook.new
      @hook.on_frame {|f| recv_frame f }
      @hpack = HPack.new
      @logger = logger
      # H2 state
      @window_queue = {}      # outgoing message queue (buffered until WINDOW_UPDATE)
      @first_frame_in = true  # true until we receive the preamble SETTINGS from the peer
      @first_frame_out = true # true until we deliver the preamble SETTINGS
      @streams = {}
      @default_window_size = 65535 # incoming INITIAL_WINDOW_SIZE value
      @window_size = @default_window_size # how much space remains in the connection window
      @max_frame_size = 16384 # incoming MAX_FRAME_SIZE value
      @max_streams = nil      # incoming MAX_CONCURRENT_STREAMS value
      @push_to_peer = true    # incoming ENABLE_PUSH value
      @ext__send_gzip = true  # are we config'd to send gzip data?
      @ext__peer_gzip = false # is peer config'd to accept gzip data? (incoming ACCEPT_GZIP_DATA)
      @ext__recv_gzip = true  # are we config'd to accept gzip data?
      @ext__veto_gzip = false # set if peer doesn't gzip right
      @ext__sent_dropped_frame = {} # frame types we've told the peer we're ignoring
      @ext__peer_dropped_frame = {} # frame types the peer has said it's ignoring
      @priority_tree = PriorityTree.new
      # other settings
      @pings = []      # pings we've sent
      @goaway = false  # false until incoming GOAWAY, then Last-Stream-ID
      @last_stream = 0 # last incoming stream handed up to application; sent in GOAWAY
      @shutting_down = false # false until we call #shut_down and set a GOAWAY

      @send_lock = Mutex.new
      @shutdown_lock = Mutex.new
    end

    ##
    # True if we've sent or received a GOAWAY frame.
    #
    def shutdown?
      @shutdown_lock.synchronize {
        @shutting_down
      }
    end

    attr_reader :push_to_peer

    ##
    # Set the callback to be invoked when a stream is cancelled.
    #
    # @yield stream_id, error_code
    #
    def on_cancel &b
      @cancel_proc = b
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
      raise "already wrapped a socket!" if @socket
      @socket = s

      if defined? OpenSSL::SSL::SSLSocket and s.is_a? OpenSSL::SSL::SSLSocket
        @descr = s.io.remote_address.inspect_sockaddr
      else
        @descr = s.remote_address.inspect_sockaddr
      end

      @sil = FrameSerialiser.new {|b|
cyan "@sil: _write #{hex b}"
_write s, b rescue nil }
      @dsil = FrameDeserialiser.new do |f|
        begin
brown "dsil: received #{frm f}"
          @hook << f
        rescue ConnectionError => e
          @logger.info "connection error [#{e.code}:#{e}] in client #{@descr} {1}"
          die e.code
        end
      end

      handle_prefaces s
      send_frame Settings.frame_from(initial_settings), true

      loop do
        bytes = begin
          s.readpartial(4*1024*1024)
        rescue EOFError
          nil
        rescue IOError, Errno::ECONNRESET
          raise unless s.closed?
        end
        if bytes.nil? or bytes.empty?
          @logger.info "client disconnected from #{@descr}"
          break
        end
red "read #{hex bytes}"
        @dsil << bytes
        Thread.pass
      end
    rescue ConnectionError => e
      @logger.info "connection error [#{e.code}:#{e}] in client #{@descr} {2}"
      die e.code
    ensure
      _close_socket
    end

    ##
    # Shut down the connection.
    def shut_down
      @shutdown_lock.synchronize {
        return if @shutting_down
        @shutting_down = true
      }
      die NO_ERROR
    end

    ##
    # send a PING message
    def ping message=nil
      if message
        message = (message.to_s.b + (0.chr * 8)).slice(0, 8)
      else
        now = Time.now
        message = [now.to_i, now.usec].pack('NN')
      end
      @pings << message
      g = Frame.new FrameTypes::PING, 0, 0, message
      send_frame g
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

    def create_request_stream
      s = if @streams.empty?
        1
      else
        t = @streams.keys.last
        t + 1 + (t % 2)
      end

      @streams[s] = Stream.new(@default_window_size)
      s
    end

    def create_push_stream
      s = if @streams.empty?
        2
      else
        t = @streams.keys.last
        t + 2 - (t % 2)
      end

      @streams[s] = Stream.new(@default_window_size)
      s
    end

    def open_stream s
      stream = @streams[s]
      raise unless stream
      stream.open!
      s
    end

    def reserve_stream s
      stream = @streams[s]
      raise unless stream
      stream.reserve_local!
      s
    end

  private

    ##
    # deliver HTTPMessage object
    def deliver s, m
      @shutdown_lock.synchronize {
        raise "delivering message after GOAWAY" if @shutting_down # FIXME
      }
blue "deliver #{m.inspect}"

      # FIXME
      stream = @streams[s]
      raise unless stream
      raise unless stream.local == :open

      max_send_size = [@max_frame_size, @window_size, stream.window_size].min

      # create headers
      hblock = @hpack.create_block m.headers
      # split header block into chunks and deliver
      chunks = hblock.scan(/.{1,#{max_send_size}}/m).map{|c| {type: FrameTypes::CONTINUATION, flags: 0, bytes: c} }
      if chunks.empty?
        # I cast no judgement here, but shouldn't there be some headers..?
        chunks << {type: FrameTypes::HEADERS, flags: FLAG_END_HEADERS, bytes: String.new.b}
      else
        chunks.first[:type] = FrameTypes::HEADERS
        chunks.last[:flags] |= FLAG_END_HEADERS
      end
      # without data, the HEADERS ends the stream
      if m.body.empty?
        chunks.last[:flags] |= FLAG_END_STREAM
      end
      # pad out to %256 bytes if required
      _pad chunks.last if m.pad?
      # send the headers frame(s)
      chunks.each do |chunk|
        g = Frame.new chunk[:type], chunk[:flags], s, chunk[:bytes]
        send_frame g
      end

      # create data
      if !m.body.empty?
        chunks = []
        if send_gzip?
          type = FrameTypes::GZIPPED_DATA
          bytes = m.body.b

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

              if gzipped.bytesize > max_send_size
                # try a smaller sample
                maxright = right
                right = maxright - (maxright - left) / 2
                # is this a good as we'll get?
                break if right == left
              elsif gzipped.bytesize == max_send_size
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
            _pad chunk if m.pad?
            # add to list
            chunks << chunk
          end
        else
          type = FrameTypes::DATA
          chunks = m.body.b.scan(/.{1,#{max_send_size}}/m).map{|c| {flags: 0, bytes: c} }
          # pad out to %256 bytes if required
          _pad chunks.last if m.pad?
        end
        chunks.last[:flags] |= FLAG_END_STREAM
        chunks.each do |chunk|
          g = Frame.new type, chunk[:flags], s, chunk[:bytes]
          send_frame g
        end
      end

      # half-close
      stream.close_local!
    end

    def handle_prefaces s
      raise NoMethodError, "handle_prefaces should be implemented in subclass"
    end

    ##
    # Initial settings sent during preface
    def initial_settings
      #{Settings::INITIAL_WINDOW_SIZE => 0x7fffffff, Settings::ACCEPT_GZIPPED_DATA => 1}
      #{Settings::INITIAL_WINDOW_SIZE => 0x7fffffff}
      {Settings::INITIAL_WINDOW_SIZE => 0x20000, Settings::MAX_FRAME_SIZE => @dsil.max_frame_size, Settings::ACCEPT_GZIPPED_DATA => 1}
    end

    ##
    # Shut down the connection.
    def die code
      if !@send_lock.synchronize{@first_frame_out}
        g = Frame.new FrameTypes::GOAWAY, 0x00, 0, [@last_stream,code].pack('NN')
        send_frame g
      end
      _close_socket
    end

    # close the socket we've wrapped
    def _close_socket
      raise "no wrapped socket" unless @socket
      return if @socket.closed?
      @socket.shutdown rescue nil
      @socket.read_nonblock(4*1024*1024) rescue nil # flush any in-flight crud
      @socket.close rescue nil
    end

    ##
    # Shut down a stream.
    def cancel stream_id, code
      # TODO: @streams[stream_id].close_local!
      g = Frame.new FrameTypes::RST_STREAM, 0x00, stream_id, [code].pack('N')
      send_frame g
    end

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
        raise unless s # FIXME
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

        # RFC 7540, Section 3.5
        # "Clients and servers MUST treat an invalid connection preface
        #  as a connection error (Section 5.4.1) of type
        #  PROTOCOL_ERROR."
        raise ConnectionError.new(PROTOCOL_ERROR, 'invalid preface - no SETTINGS') if f.type != FrameTypes::SETTINGS
        @first_frame_in = false
      end

      if @goaway
        case f.type
        when FrameTypes::DATA
        when FrameTypes::HEADERS
        when FrameTypes::PUSH_PROMISE
        when FrameTypes::CONTINUATION
        when FrameTypes::GZIPPED_DATA
        when FrameTypes::DROPPED_FRAME
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
        handle_priority f
      when FrameTypes::RST_STREAM
        handle_rst_stream f
      when FrameTypes::SETTINGS
        handle_settings f
      when FrameTypes::PUSH_PROMISE
        handle_push_promise f
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
    rescue ConnectionError => e
      @logger.info "connection error [#{e.code}:#{e}] in client #{@descr} {3}"
      die e.code
    rescue StreamError => e
      @logger.info "stream error [#{e.code}:#{e.stream}:#{e}] in client #{@descr}"
      cancel e.stream, e.code
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

    # triggered when a completed HTTP message arrives
    # (farms it off to the registered callback)
    def emit_message sid, stream
      # NB: this function only invoked once we get an END_STREAM flag
      stream.close_remote!
      @last_stream = sid

      headers = stream.headers

      mandatory_headers = mandatory_pseudoheaders
      nonpseudo_headers = false
      malformed_headers = catch(:MALFORMED) do
        headers.each_pair do |k, v|
          throw :MALFORMED, "uppercase header #{k.inspect}" unless k.downcase == k
          if k.start_with? ':'
            throw :MALFORMED, "invalid pseudo-header #{k.inspect}" unless allowed_pseudoheader? k
            throw :MALFORMED, "pseudo-header after regular header" if nonpseudo_headers
            throw :MALFORMED, "repeated pseudo-header" if v.is_a?(Array) && v.length > 1
            mandatory_headers.delete k
          else
            nonpseudo_headers = true
            case k
            when 'connection'
              throw :MALFORMED, "\"connection\" header"
            when 'te'
              throw :MALFORMED, "invalid \"te\" header" unless v == '' || v.downcase == 'trailers'
            end
          end
        end
        nil
      end
      # missing mandatory pseudo-headers
      malformed_headers ||= "missing mandatory pseudo-headers #{mandatory_headers.inspect}" unless mandatory_headers.empty?

      # RFC 7540, Section 8.1.2
      # "A request or response containing uppercase header field
      #  names MUST be treated as malformed ..."
      # > S8.1.2.6 "Malformed requests ... MUST be treated as a
      #    stream error ..."
      raise StreamError.new(PROTOCOL_ERROR, sid, "malformed message: #{malformed_headers}") if malformed_headers

      # RFC 7540, Section 8.1.2.6
      # "A request or response is also malformed if the value of a
      #  content-length header field does not equal the sum of the DATA
      #  frame payload lengths that form the body."
      cl = headers['content-length']
      raise StreamError.new(PROTOCOL_ERROR, sid, "malformed message: content-length #{cl.inspect}, expected #{stream.body.bytesize}") if cl and (Integer(cl) rescue -1) != stream.body.bytesize

      _do_emit sid, headers, stream.body
    end

    # triggered when a stream is cancelled (RST_STREAM)
    def emit_cancel sid, error
      @cancel_proc.call sid, error if @cancel_proc
    end

    def strip_padding bytes
      ints = bytes.bytes
      pad_length = ints.shift
      rst_length = ints.length
      # e.g. RFC 7540, Section 6.1
      # "If the length of the padding is the length of the frame
      #  payload or greater, the recipient MUST treat this as a
      #  connection error (Section 5.4.1) of type PROTOCOL_ERROR."
      raise ConnectionError.new(PROTOCOL_ERROR, "Pad Length #{pad_length} exceeds frame payload size #{rst_length+1}") if pad_length > rst_length
      ints[0...rst_length-pad_length].pack('C*')
    end

    def extract_priority bytes
      sid, weight, bytes = bytes.unpack('NCa*')
      exclusive = (sid & 0x80000000) == 0x80000000
      sid &= 0x7fffffff
      [{exclusive:exclusive, sid:sid, weight:weight}, bytes]
    end

    def handle_data f
      # RFC 7540, Section 6.1
      # "If a DATA frame is received whose stream identifier field is
      #  0x0, the recipient MUST respond with a connection error
      #  (Section 5.4.1) of type PROTOCOL_ERROR."
      raise ConnectionError.new(PROTOCOL_ERROR, "DATA must be sent on stream >0") if f.sid == 0

      stream = @streams[f.sid]
      raise ConnectionError.new(PROTOCOL_ERROR, "DATA frame received on idle stream #{f.sid}") unless stream
      case stream.state
      when :open, :halfclosed_local
      when :idle, :reserved_local, :reserved_remote
        raise ConnectionError.new(PROTOCOL_ERROR, "DATA frame received on #{stream.state} stream #{f.sid}")
      when :closed, :halfclosed_remote
        raise StreamError.new(STREAM_CLOSED, f.sid, "DATA frame received on #{stream.state} stream #{f.sid}")
      else
        raise "BUG: invalid stream #{f.sid} state #{stream.state.inspect}" # FIXME
      end

      return if @goaway

      bytes = f.payload

      # never run out of window space
      size = bytes.bytesize
      if size > 0
        g = Frame.new FrameTypes::WINDOW_UPDATE, 0x00, 0,     [size].pack('N')
        h = Frame.new FrameTypes::WINDOW_UPDATE, 0x00, f.sid, [size].pack('N')
        send_frame g
        send_frame h
      end

      bytes = strip_padding(bytes) if f.flag? FLAG_PADDED

      stream << bytes
      emit_message f.sid, stream if f.flag? FLAG_END_STREAM
    end

    def handle_gzipped_data f
      #raise ConnectionError.new(PROTOCOL_ERROR, "GZIPPED_DATA cannot be sent without SETTINGS_ACCEPT_GZIP_DATA") unless accept_gzip
      if !accept_gzip?
        drop_frame f
        return
      end

      raise ConnectionError.new(PROTOCOL_ERROR, "GZIPPED_DATA must be sent on stream >0") if f.sid == 0

      stream = @streams[f.sid]
      raise ConnectionError.new(PROTOCOL_ERROR, "GZIPPED_DATA frame received on idle stream #{f.sid}") unless stream
      case stream.state
      when :open, :halfclosed_local
      when :idle, :reserved_local, :reserved_remote
        raise ConnectionError.new(PROTOCOL_ERROR, "GZIPPED_DATA frame received on #{stream.state} stream #{f.sid}")
      when :closed, :halfclosed_remote
        raise StreamError.new(STREAM_CLOSED, f.sid, "GZIPPED_DATA frame received on #{stream.state} stream #{f.sid}")
      else
        raise "BUG: invalid stream #{f.sid} state #{stream.state.inspect}" # FIXME
      end

      return if @goaway

      bytes = f.payload
      bytes = strip_padding(bytes) if f.flag? FLAG_PADDED

      # never run out of window space
      size = bytes.bytesize
      if size > 0
        g = Frame.new FrameTypes::WINDOW_UPDATE, 0x00, 0, [size].pack('N')
        send_frame g
      end

      inflated_bytes = nil
      gunzip = Zlib::GzipReader.new(StringIO.new bytes)
      begin
        inflated_bytes = gunzip.read
      rescue Zlib::Error => e
        # bad gzip!
        raise StreamError.new(DATA_ENCODING_ERROR, f.sid, e.to_s)
      ensure
        veto_gzip! if inflated_bytes.nil?
      end

      # note: only update the frame window if gunzip succeeddededd
      if size > 0
        h = Frame.new FrameTypes::WINDOW_UPDATE, 0x00, f.sid, [size].pack('N')
        send_frame h
      end

      stream << inflated_bytes
      emit_message f.sid, stream if f.flag? FLAG_END_STREAM
    end

    def handle_headers f
      raise ConnectionError.new(PROTOCOL_ERROR, "HEADERS must be sent on stream >0") if f.sid == 0
      stream = @streams[f.sid]
      if !stream
        raise ConnectionError.new(PROTOCOL_ERROR, "new stream id #{f.sid} not greater than previous stream id #{@last_stream}") if f.sid <= @last_stream
        ok_incoming_streamid? f.sid
        stream = @streams[f.sid] = Stream.new(@default_window_size)
      end

      stream_error = catch :STREAM_ERROR do
        case stream.state
        when :idle
          stream.open!
        when :reserved_remote
          stream.close_local!
        when :open, :halfclosed_local
        when :halfclosed_remote
          # Can't emit STREAM_ERROR here; we must parse the header block first
          throw :STREAM_ERROR, StreamError.new(STREAM_CLOSED, f.sid, "HEADERS frame received on half-closed stream #{f.sid}")
        when :closed
          raise ConnectionError.new(STREAM_CLOSED, "HEADERS frame received on closed stream #{f.sid}")
        when :reserved_local
          raise ConnectionError.new(PROTOCOL_ERROR, "HEADERS frame received on reserved stream #{f.sid}")
        else
          raise "BUG: invalid stream #{f.sid} state #{stream.state.inspect}" # FIXME
        end

        if stream.got_headers?
          # Can't emit STREAM_ERROR here; we must parse the header block first
          throw :STREAM_ERROR, StreamError.new(PROTOCOL_ERROR, f.sid, "no END_STREAM on trailing headers") unless f.flag? FLAG_END_STREAM
        else
          stream.got_headers!
        end

        nil
      end

      # read the header block
      bytes = f.payload
      bytes = strip_padding(bytes) if f.flag? FLAG_PADDED
      priority, bytes = extract_priority(bytes) if f.flag? FLAG_PRIORITY
yellow "priority: #{priority.inspect}"
      begin
        @hpack.parse_block(bytes) do |k, v|
yellow "  [#{k}]: [#{v}]"
          stream[k] << v
        end
yellow "--"
      rescue => e
        raise ConnectionError.new(COMPRESSION_ERROR, e.to_s)
      end

      # If a STREAM_ERROR was detected before parsing the header block,
      # emit it now.
      raise stream_error if stream_error

      # handle the priority -- after HPACK, in case of errors
      @priority_tree.add f.sid, priority[:sid], priority[:weight], priority[:exclusive] if priority

      # if end-of-stream, emit the message
      emit_message f.sid, stream if !@goaway and f.flag? FLAG_END_STREAM
    end

    def handle_priority f
      # RFC 7540, Section 6.3
      # "If a PRIORITY frame is received with a stream identifier of
      #  0x0, the recipient MUST respond with a connection error
      #  (Section 5.4.1) of type PROTOCOL_ERROR."
      raise ConnectionError.new(PROTOCOL_ERROR, "PRIORITY must be sent on stream >0") if f.sid == 0

      # RFC 7540, Section 6.3
      # "A PRIORITY frame with a length other than 5 octets MUST be
      #  treated as a stream error (Section 5.4.2) of type
      #  FRAME_SIZE_ERROR."
      raise StreamError.new(FRAME_SIZE_ERROR, f.sid, "PRIORITY payload must be 5 bytes, received #{f.payload.bytesize}") unless f.payload.bytesize == 5

      priority, bytes = extract_priority(f.payload)
      @priority_tree.add f.sid, priority[:sid], priority[:weight], priority[:exclusive]
    end

    def handle_settings f
      raise ConnectionError.new(PROTOCOL_ERROR, "SETTINGS must be sent on stream 0, received #{f.sid}") if f.sid != 0

      if f.flag? FLAG_ACK
        # RFC 7540, Section 6.5
        # "Receipt of a SETTINGS frame with the ACK flag set and a
        #  length field value other than 0 MUST be treated as a
        #  connection error (Section 5.4.1) of type FRAME_SIZE_ERROR."
        raise ConnectionError.new(FRAME_SIZE_ERROR, "SETTINGS ACK must have no payload, got #{f.payload.bytesize} bytes") unless f.payload.bytesize == 0

        # TODO: the rest of this
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

    def handle_push_promise f
      raise NoMethodError, "handle_push_promise should be implemented in subclass"
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

    def handle_rst_stream f
      # RFC 7540, Section 6.4
      # "If a RST_STREAM frame is received with a stream identifier of
      #  0x0, the recipient MUST treat this as a connection error
      #  (Section 5.4.1) of type PROTOCOL_ERROR."
      raise ConnectionError.new(PROTOCOL_ERROR, "received RST_STREAM on stream id #{f.sid}") if f.sid == 0
      # RFC 7540, Section 5.1
      # "Receiving any frame other than HEADERS or PRIORITY on a
      #  stream in this state MUST be treated as a connection error
      #  (Section 5.4.1) of type PROTOCOL_ERROR."
      # Section 6.4
      # "If a RST_STREAM frame identifying an idle stream is received,
      #  the recipient MUST treat this as a connection error (Section
      #  5.4.1) of type PROTOCOL_ERROR."
      raise ConnectionError.new(PROTOCOL_ERROR, "received RST_STREAM frame on idle stream #{f.sid}") unless @streams[f.sid]
      # RFC 7540, Section 6.4
      # "A RST_STREAM frame with a length other than 4 octets MUST be
      #  treated as a connection error (Section 5.4.1) of type
      #  FRAME_SIZE_ERROR."
      raise ConnectionError.new(FRAME_SIZE_ERROR, "RST_STREAM payload must be 4 bytes, received #{f.payload.bytesize}") unless f.payload.bytesize == 4
      # TODO
      error_code = f.payload.unpack('N').first
      @logger.info "received RST_STREAM (stream ID=#{f.sid}, error_code=0x#{error_code.to_s 16})"

      emit_cancel f.sid, error_code if !@goaway
    end

    def handle_window_update f
      # FIXME: stream states?

      # RFC 7540, Section 5.1
      # "Receiving any frame other than HEADERS or PRIORITY on a
      #  stream in this state MUST be treated as a connection error
      #  (Section 5.4.1) of type PROTOCOL_ERROR."
      raise ConnectionError.new(PROTOCOL_ERROR, "received WINDOW_UPDATE frame on idle stream #{f.sid}") unless f.sid == 0 || @streams[f.sid]

      # RFC 7540, Section 6.9
      # "A WINDOW_UPDATE frame with a length other than 4 octets MUST
      #  be treated as a connection error (Section 5.4.1) of type
      #  FRAME_SIZE_ERROR."
      raise ConnectionError.new(FRAME_SIZE_ERROR, "WINDOW_UPDATE payload must be 4 bytes, received #{f.payload.bytesize}") unless f.payload.bytesize == 4
      increment = f.payload.unpack('N').first

      #raise 'PROTOCOL_ERROR' if increment & 0x80000000 == 0x80000000
      increment &= 0x7fffffff

      # RFC 7540, Section 6.9
      # "A receiver MUST treat the receipt of a WINDOW_UPDATE frame
      #  with an flow-control window increment of 0 as a stream error
      #  (Section 5.4.2) of type PROTOCOL_ERROR"
      #
      # RFC 7540, Section 6.9.1
      # "A sender MUST NOT allow a flow-control window to exceed 2^31-1
      #  octets. [etc.]"
      if f.sid != 0
        raise StreamError.new(PROTOCOL_ERROR, f.sid, "WINDOW_UPDATE increment should be > 0") if increment == 0
        @streams[f.sid].window_size += increment
        raise StreamError.new(FLOW_CONTROL_ERROR, f.sid, "WINDOW_UPDATE overflow on stream #{f.sid}") if @streams[f.sid].window_size > 0x7fffffff
      else
        raise ConnectionError.new(PROTOCOL_ERROR, "WINDOW_UPDATE increment should be > 0") if increment == 0
        @window_size += increment
        raise ConnectionError.new(FLOW_CONTROL_ERROR, "WINDOW_UPDATE overflow on connection") if @window_size > 0x7fffffff
      end

      catch :CONNECTION_EXHAUSTED do
        @window_queue.each_pair do |sid, queue|
          s = @streams[sid]
          # note: sid can never be zero, since frames only
          #       enter the queue because of a blocked DATA
          #       (which isn't allowed on stream 0)
          raise unless s # FIXME
          catch :STREAM_EXHAUSTED do
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

