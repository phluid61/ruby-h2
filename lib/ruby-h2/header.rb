# encoding: BINARY
# vim: ts=2 sts=2 sw=2 expandtab

module RUBYH2

  class Header
    def initialize name, value=nil
      @name = name.downcase
      @value = value
    end
    attr_reader :name
    attr_accessor :value
    def << v
      case @value
      when nil
        @value = v
      when Array
        @value << v
      else
        @value = [@value, v]
      end
      v
    end
    def inspect
      "\#<Header #{@name.inspect}:#{@value.inspect}>"
    end
    def flatten glue=', ', force_string:false
      case @value
      when nil
        force_string ? '' : nil
      when Array
        @value.join(glue)
      else
        @value.to_s
      end
    end
  end

end

