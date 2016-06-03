# encoding: BINARY
# vim: ts=2 sts=2 sw=2

module RUBYH2

	class HTTPRequest
		def initialize stream, method, path, version, headers, body
			@stream  = stream
			@method  = method
			@path    = path
			@version = version
			@headers = headers
			@body    = body
		end
		attr_reader :stream
		attr_reader :method
		attr_reader :path
		attr_reader :version
		attr_reader :headers
		attr_reader :body

		def inspect
			"\#<HTTPRequest @stream=#{@stream.inspect}, @method=#{@method.inspect}, @path=#{@path.inspect}, @version=#{@version.inspect}, @headers=#{@headers.inspect}, @body=#{@body.inspect}>"
		end
	end

	class HTTPResponse
		def initialize stream, status=nil
			@stream  = stream
			@status  = status
			@headers = {}
			@body    = String.new.b
			@pad = false
		end

		attr_reader :stream

		attr_accessor :status

		attr_reader :headers
		def []= h, v
			@headers[h] = v
		end

		def [] h
			@headers[h]
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
			@headers[k.downcase]
		end
		# completely overwrite the Header named +k+
		def []= k, v
			@headers[k.downcase].value = v
		end
		# Get the headers as a simple Hash.
		# Options for +flatten+:
		#  * +nil+ (default)  don't flatten the value
		#  * +true+           flatten the value using the default separator
		#  * other            flatten the value using this value as the separator
		def headers flatten=true
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

