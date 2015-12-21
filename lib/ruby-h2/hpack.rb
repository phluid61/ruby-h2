# encoding: BINARY
# vim: ts=2:sts=2:sw=2

require_relative 'hpack/encoding'

class ::RUBYH2_TableEntry
	def initialize name, value
		@name = name
		@value = value
	end
	attr_accessor :name
	attr_accessor :value
	def to_a
		[@name, @value]
	end
	def size
		@name.bytesize + @value.bytesize + 32
	end
end

class ::RUBYH2_Table
	def initialize
		@max_size = 4096
		@dtable = []
	end
	attr_reader :max_size
	def max_size= s
		raise if s < 0 # FIXME
		_evict_until s
		@max_size = s
	end
	def [] i
		raise if i < 1 # FIXME
		if i <= 61
			::RUBYH2_Table.static_table[i-1]
		else
			@dtable[i-62]
		end
	end
	def add name, value
		e = ::RUBYH2_TableEntry.new(name, value)
		_evict_until(@max_size - e.size)
		@dtable = [e] + @dtable if e.size <= @max_size
		self
	end
	def size
		@dtable.inject(0){|s,e| s + e.size }
	end

	def find n, v
		@names.each_with_index do |e,i|
			return i if e.name == n && e.value == v
		end
		nil
	end
	def find_name n
		@names.each_with_index do |e,i|
			return i if e.name == n
		end
		nil
	end

	def _evict_until s
		if s < 1
			@dtable = []
		else
			@dtable.pop while size > s
		end
	end

	def self.static_table
		@@stable ||= [
			::RUBYH2_TableEntry.new(':authority', ''),
			::RUBYH2_TableEntry.new(':method', 'GET'),
			::RUBYH2_TableEntry.new(':method', 'POST'),
			::RUBYH2_TableEntry.new(':path', '/'),
			::RUBYH2_TableEntry.new(':path', '/index.html'),
			::RUBYH2_TableEntry.new(':scheme', 'http'),
			::RUBYH2_TableEntry.new(':scheme', 'https'),
			::RUBYH2_TableEntry.new(':status', '200'),
			::RUBYH2_TableEntry.new(':status', '204'),
			::RUBYH2_TableEntry.new(':status', '206'),
			::RUBYH2_TableEntry.new(':status', '304'),
			::RUBYH2_TableEntry.new(':status', '400'),
			::RUBYH2_TableEntry.new(':status', '404'),
			::RUBYH2_TableEntry.new(':status', '500'),
			::RUBYH2_TableEntry.new('accept-charset', ''),
			::RUBYH2_TableEntry.new('accept-encoding', ''),
			::RUBYH2_TableEntry.new('accept-languages', ''),
			::RUBYH2_TableEntry.new('accept-ranges', ''),
			::RUBYH2_TableEntry.new('accept', ''),
			::RUBYH2_TableEntry.new('access-control-allow-origin', ''),
			::RUBYH2_TableEntry.new('age', ''),
			::RUBYH2_TableEntry.new('allow', ''),
			::RUBYH2_TableEntry.new('authorization', ''),
			::RUBYH2_TableEntry.new('cache-control', ''),
			::RUBYH2_TableEntry.new('content-disposition', ''),
			::RUBYH2_TableEntry.new('content-encoding', ''),
			::RUBYH2_TableEntry.new('content-language', ''),
			::RUBYH2_TableEntry.new('content-length', ''),
			::RUBYH2_TableEntry.new('content-location', ''),
			::RUBYH2_TableEntry.new('content-range', ''),
			::RUBYH2_TableEntry.new('content-type', ''),
			::RUBYH2_TableEntry.new('cookie', ''),
			::RUBYH2_TableEntry.new('date', ''),
			::RUBYH2_TableEntry.new('etag', ''),
			::RUBYH2_TableEntry.new('expect', ''),
			::RUBYH2_TableEntry.new('expires', ''),
			::RUBYH2_TableEntry.new('from', ''),
			::RUBYH2_TableEntry.new('host', ''),
			::RUBYH2_TableEntry.new('if-match', ''),
			::RUBYH2_TableEntry.new('if-modified-since', ''),
			::RUBYH2_TableEntry.new('if-none-match', ''),
			::RUBYH2_TableEntry.new('if-range', ''),
			::RUBYH2_TableEntry.new('if-unmodified-since', ''),
			::RUBYH2_TableEntry.new('last-modified', ''),
			::RUBYH2_TableEntry.new('link', ''),
			::RUBYH2_TableEntry.new('location', ''),
			::RUBYH2_TableEntry.new('max-forwards', ''),
			::RUBYH2_TableEntry.new('proxy-authenticate', ''),
			::RUBYH2_TableEntry.new('proxy-authorization', ''),
			::RUBYH2_TableEntry.new('range', ''),
			::RUBYH2_TableEntry.new('referer', ''),
			::RUBYH2_TableEntry.new('refresh', ''),
			::RUBYH2_TableEntry.new('retry-after', ''),
			::RUBYH2_TableEntry.new('server', ''),
			::RUBYH2_TableEntry.new('set-cookie', ''),
			::RUBYH2_TableEntry.new('strict-transport-security', ''),
			::RUBYH2_TableEntry.new('transfer-encoding', ''),
			::RUBYH2_TableEntry.new('user-agent', ''),
			::RUBYH2_TableEntry.new('var', ''),
			::RUBYH2_TableEntry.new('via', ''),
			::RUBYH2_TableEntry.new('www-authenticate', ''),
		]
	end
end

class ::RUBYH2_HPack

	def initialize
		@table_in = ::RUBYH2_Table.new
		@table_out = ::RUBYH2_Table.new
	end

	def parse_block bytes, &b
		bytes = bytes.to_s unless bytes.is_a? String
		#raise ArgumentError if bytes.empty?
		while !bytes.empty?
			first_byte = bytes.unpack('C')
			if first_byte & 0x80 == 0x80
				# indexed header field representation
				pfx, index, bytes = ::RUBYH2_HPackEncoding.decode_int bytes, prefix_bits: 7
				raise if index == 0 # FIXME
				name, value = @table_in[index].to_a
				yield name, value
			elsif first_byte & 0xc0 == 0x40
				# literal header field with incremental indexing
				pfx, index, bytes = ::RUBYH2_HPackEncoding.decode_int bytes, prefix_bits: 6
				if index == 0
					name, bytes = ::RUBYH2_HPackEncoding.decode_string bytes
				else
					name = @table_in[index].name
				end
				value, bytes = ::RUBYH2_HPackEncoding.decode_string bytes
				@table_in.add name, value
				yield name, value
			elsif first_byte & 0xe0 == 0x20
				# dynamic table size update
				pfx, max_size, bytes = ::RUBYH2_HPackEncoding.decode_int bytes, prefix_bits: 5
				@table_in.max_size = max_size
			else
				#if first_byte & 0xf0 == 0x10
				# literal header field never indexed
				#else# first_byte & 0xf0 == 0x00
				# literal header field without indexing
				#end
				pfx, index, bytes = ::RUBYH2_HPackEncoding.decode_int bytes, prefix_bits: 4
				if index == 0
					name, bytes = ::RUBYH2_HPackEncoding.decode_string bytes
				else
					name = @table_in[index].name
				end
				value, bytes = ::RUBYH2_HPackEncoding.decode_string bytes
				yield name, value
			end
		end
	end

	def create_block headers
		bytes = String.new
		headers.each do |k,v|
			i = @table_out.find k, v
			if i
				# generate indexed thing
				chunk = ::RUBYH2_HPackEncoding.encode_int i, prefix_bits: 7, prefix: 0x80
				# TODO: @table_out.add name, value ???
			else
				i = @table_out.find_name k
				if i
					# generate a half-indexed thing
					chunk = ::RUBYH2_HPackEncoding.encode_int i, prefix_bits: 6, prefix: 0x40
					chunk = ::RUBYH2_HPackEncoding.encode_string value
					# TODO: @table_out.add name, value ???
				else
					# generate a literal thing
					chunk = ::RUBYH2_HPackEncoding.encode_int 0, prefix_bits: 6, prefix: 0x40
					chunk = ::RUBYH2_HPackEncoding.encode_string name
					chunk = ::RUBYH2_HPackEncoding.encode_string value
					# TODO: @table_out.add name, value ???
				end
			end
		end
		bytes
	end

end

