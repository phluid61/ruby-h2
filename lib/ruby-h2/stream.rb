# encoding: BINARY
# vim: ts=2 sts=2 sw=2 expandtab

require_relative 'header'

module RUBYH2

  class Stream
    def initialize window_size
      @headers = Hash.new {|h,k| h[k] = Header.new(k) }
      @body = String.new.b
      @window_size = window_size
      @got_headers = false
      # stream state
      @local = :idle
      @remote = :idle
    end
    attr_reader :body, :local, :remote
    attr_accessor :window_size

    def got_headers!
      @got_headers = true
    end
    def got_headers?
      @got_headers
    end

    # append bytes to the body
    def << bytes
      @body << bytes
    end

    # get the Header named +k+
    def [] k
      @headers[k]
    end
    # completely overwrite the Header named +k+
    def []= k, v
      @headers[k].value = v
    end
    # Get the headers as a simple Hash.
    # Options for +flatten+:
    #  * +nil+ (default)  don't flatten the value
    #  * +true+           flatten the value using the default separator
    #  * other            flatten the value using this value as the separator
    def headers flatten=nil
      hsh = {}
      if !flatten
        @headers.each_pair do |k, v|
          hsh[k] = v.value
        end
      elsif flatten == true
        @headers.each_pair do |k, v|
          hsh[k] = v.flatten
        end
      else
        @headers.each_pair do |k, v|
          hsh[k] = v.flatten(flatten)
        end
      end
      hsh
    end

    def idle?
      @local == :idle && @remote == :idle
    end

    def closed?
      @local == :closed && @remote == :closed
    end

    def state
      case [@local, @remote]
      when [:idle, :idle]
        :idle
      when [:open, :idle]
        :reserved_local
      when [:idle, :open]
        :reserved_remote
      when [:open, :open]
        :open
      when [:open, :closed]
        :halfclosed_remote
      when [:closed, :open]
        :halfclosed_local
      when [:closed, :closed]
        :closed
      end
    end

    def open!
      # FIXME
      raise unless @local == :idle && @remote == :idle
      @local = @remote = :open
    end
    def reserve_local!
      # FIXME
      raise unless @local == :idle && @remote == :idle
      @local = :open
    end
    def reserve_remote!
      # FIXME
      raise unless @local == :idle && @remote == :idle
      @remote = :open
    end

    def close_local!
      # FIXME
      raise unless @remote == :open || @remote == :closed
      @local = :closed
    end
    def close_remote!
      # FIXME
      raise unless @local == :open || @local == :closed
      @remote = :closed
    end
    def close!
      @local = @remote = :closed
    end

  end

end

