# encoding: BINARY
# vim: ts=2 sts=2 sw=2 expandtab

require_relative 'header'

module RUBYH2

  class Stream
    def initialize window_size
      @headers = Hash.new {|h,k| h[k] = Header.new(k) }
      @body = String.new.b
      @window_size = window_size
      # FIXME: this only allows: open, half-closed(local), half-closed(remote), and closed
      @open_local = true
      @open_remote = true
    end
    attr_reader :body
    attr_accessor :window_size

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

    def open_local?
      @open_local
    end

    def open_remote?
      @open_remote
    end

    def state
      # TODO: idle/reserved(*)/..?
      if @open_local
        if @open_remote
          :open
        else
          :halfclosedremote
        end
      else
        if @open_remote
          :halfclosedlocal
        else
          :closed
        end
      end
    end

    def close_local!
      @open_local = false
    end

    def close_remote!
      @open_remote = false
    end

  end

end

