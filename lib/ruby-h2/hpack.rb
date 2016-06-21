# encoding: BINARY
# vim: ts=2:sts=2:sw=2

require_relative 'hpack/encoding'

module RUBYH2

	class TableEntry
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

	class Table
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
				RUBYH2::Table.static_table[i-1]
			else
				@dtable[i-62]
			end
		end
		def add name, value
			e = RUBYH2::TableEntry.new(name, value)
			_evict_until(@max_size - e.size)
			@dtable = [e] + @dtable if e.size <= @max_size
			self
		end
		def size
			@dtable.inject(0){|s,e| s + e.size }
		end

		def find n, v
			self.class.static_table.each_with_index do |e,i|
				return i+1 if e.name == n && e.value == v
			end
			@dtable.each_with_index do |e,i|
				return i+62 if e.name == n && e.value == v
			end
			nil
		end
		def find_name n
			self.class.static_table.each_with_index do |e,i|
				return i+1 if e.name == n
			end
			@dtable.each_with_index do |e,i|
				return i+62 if e.name == n
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
				RUBYH2::TableEntry.new(':authority', ''),
				RUBYH2::TableEntry.new(':method', 'GET'),
				RUBYH2::TableEntry.new(':method', 'POST'),
				RUBYH2::TableEntry.new(':path', '/'),
				RUBYH2::TableEntry.new(':path', '/index.html'),
				RUBYH2::TableEntry.new(':scheme', 'http'),
				RUBYH2::TableEntry.new(':scheme', 'https'),
				RUBYH2::TableEntry.new(':status', '200'),
				RUBYH2::TableEntry.new(':status', '204'),
				RUBYH2::TableEntry.new(':status', '206'),
				RUBYH2::TableEntry.new(':status', '304'),
				RUBYH2::TableEntry.new(':status', '400'),
				RUBYH2::TableEntry.new(':status', '404'),
				RUBYH2::TableEntry.new(':status', '500'),
				RUBYH2::TableEntry.new('accept-charset', ''),
				RUBYH2::TableEntry.new('accept-encoding', ''),
				RUBYH2::TableEntry.new('accept-languages', ''),
				RUBYH2::TableEntry.new('accept-ranges', ''),
				RUBYH2::TableEntry.new('accept', ''),
				RUBYH2::TableEntry.new('access-control-allow-origin', ''),
				RUBYH2::TableEntry.new('age', ''),
				RUBYH2::TableEntry.new('allow', ''),
				RUBYH2::TableEntry.new('authorization', ''),
				RUBYH2::TableEntry.new('cache-control', ''),
				RUBYH2::TableEntry.new('content-disposition', ''),
				RUBYH2::TableEntry.new('content-encoding', ''),
				RUBYH2::TableEntry.new('content-language', ''),
				RUBYH2::TableEntry.new('content-length', ''),
				RUBYH2::TableEntry.new('content-location', ''),
				RUBYH2::TableEntry.new('content-range', ''),
				RUBYH2::TableEntry.new('content-type', ''),
				RUBYH2::TableEntry.new('cookie', ''),
				RUBYH2::TableEntry.new('date', ''),
				RUBYH2::TableEntry.new('etag', ''),
				RUBYH2::TableEntry.new('expect', ''),
				RUBYH2::TableEntry.new('expires', ''),
				RUBYH2::TableEntry.new('from', ''),
				RUBYH2::TableEntry.new('host', ''),
				RUBYH2::TableEntry.new('if-match', ''),
				RUBYH2::TableEntry.new('if-modified-since', ''),
				RUBYH2::TableEntry.new('if-none-match', ''),
				RUBYH2::TableEntry.new('if-range', ''),
				RUBYH2::TableEntry.new('if-unmodified-since', ''),
				RUBYH2::TableEntry.new('last-modified', ''),
				RUBYH2::TableEntry.new('link', ''),
				RUBYH2::TableEntry.new('location', ''),
				RUBYH2::TableEntry.new('max-forwards', ''),
				RUBYH2::TableEntry.new('proxy-authenticate', ''),
				RUBYH2::TableEntry.new('proxy-authorization', ''),
				RUBYH2::TableEntry.new('range', ''),
				RUBYH2::TableEntry.new('referer', ''),
				RUBYH2::TableEntry.new('refresh', ''),
				RUBYH2::TableEntry.new('retry-after', ''),
				RUBYH2::TableEntry.new('server', ''),
				RUBYH2::TableEntry.new('set-cookie', ''),
				RUBYH2::TableEntry.new('strict-transport-security', ''),
				RUBYH2::TableEntry.new('transfer-encoding', ''),
				RUBYH2::TableEntry.new('user-agent', ''),
				RUBYH2::TableEntry.new('var', ''),
				RUBYH2::TableEntry.new('via', ''),
				RUBYH2::TableEntry.new('www-authenticate', ''),
			]
		end
	end

	class HPack

		def initialize
			@table_in = RUBYH2::Table.new
			@table_out = RUBYH2::Table.new
		end

		def max_size_in= i
			@table_in.max_size = i
		end
		def max_size_out= i
			@table_out.max_size = i
		end

		def parse_block bytes, &b
			bytes = bytes.to_s unless bytes.is_a? String
			#raise ArgumentError if bytes.empty?
			while !bytes.empty?
				first_byte = bytes.unpack('C').first
				if first_byte & 0x80 == 0x80
					# indexed header field representation
					pfx, index, bytes = RUBYH2::HPackEncoding.decode_int bytes, prefix_bits: 7
					raise if index == 0 # FIXME
					name, value = @table_in[index].to_a
					yield name, value
				elsif first_byte & 0xc0 == 0x40
					# literal header field with incremental indexing
					pfx, index, bytes = RUBYH2::HPackEncoding.decode_int bytes, prefix_bits: 6
					if index == 0
						name, bytes = RUBYH2::HPackEncoding.decode_string bytes
					else
						name = @table_in[index].name
					end
					value, bytes = RUBYH2::HPackEncoding.decode_string bytes
					@table_in.add name, value
					yield name, value
				elsif first_byte & 0xe0 == 0x20
					# dynamic table size update
					pfx, max_size, bytes = RUBYH2::HPackEncoding.decode_int bytes, prefix_bits: 5
					@table_in.max_size = max_size
				else
					#if first_byte & 0xf0 == 0x10
					# literal header field never indexed
					#else# first_byte & 0xf0 == 0x00
					# literal header field without indexing
					#end
					pfx, index, bytes = RUBYH2::HPackEncoding.decode_int bytes, prefix_bits: 4
					if index == 0
						name, bytes = RUBYH2::HPackEncoding.decode_string bytes
					else
						name = @table_in[index].name
					end
					value, bytes = RUBYH2::HPackEncoding.decode_string bytes
					yield name, value
				end
			end
		end

		def create_block headers
			index = true # TODO
			bytes = String.new.b
			headers.each do |name, value|
				i = @table_out.find name, value
				if i
					# generate indexed thing
					bytes << RUBYH2::HPackEncoding.encode_int( i, prefix_bits: 7, prefix: 0x80 )
					# TODO: @table_out.add name, value ???
				elsif index
					i = @table_out.find_name name
					if i
						# generate a half-indexed thing
						bytes << RUBYH2::HPackEncoding.encode_int( i, prefix_bits: 6, prefix: 0x40 )
						bytes << RUBYH2::HPackEncoding.encode_string( value )
						@table_out.add name, value
					else
						# generate a literal thing
						#bytes << RUBYH2::HPackEncoding.encode_int( 0, prefix_bits: 6, prefix: 0x40 )
						bytes << 0x40.chr
						bytes << RUBYH2::HPackEncoding.encode_string( name )
						bytes << RUBYH2::HPackEncoding.encode_string( value )
						@table_out.add name, value
					end
				else
					pfx = (index.nil? ? 0x00 : 0x10)
					i = @table_out.find_name name
					if i
						# generate a half-indexed thing
						bytes << RUBYH2::HPackEncoding.encode_int( i, prefix_bits: 4, prefix: pfx )
						bytes << RUBYH2::HPackEncoding.encode_string( value )
					else
						# generate a literal thing
						#bytes << RUBYH2::HPackEncoding.encode_int( 0, prefix_bits: 4, prefix: fx )
						bytes << pfx.chr
						bytes << RUBYH2::HPackEncoding.encode_string( name )
						bytes << RUBYH2::HPackEncoding.encode_string( value )
					end
				end
			end
			bytes
		end

	end

end

