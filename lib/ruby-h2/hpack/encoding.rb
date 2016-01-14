# encoding: BINARY
# vim: ts=2:sts=2:sw=2

require_relative 'huffman-codes'

module RUBYH2
	module HPackEncoding

		HUFFMAN_BIT = 0x80

		#
		# Returns one or more bytes encoding the integer +i+.
		#
		# @param Integer i the integer to encode
		# @param Integer prefix_bits
		# @param byte prefix the current value of the first byte
		#
		def self.encode_int i, prefix_bits: 8, prefix: 0
			raise ArgumentError if i < 0
			raise ArgumentError if prefix_bits < 1 || prefix_bits > 8
			case prefix
			when Integer
				raise ArgumentError if prefix < 0x00 || prefix > 0xFF
			when String
				raise ArgumentError if prefix.bytesize != 1
				prefix = prefix.unpack('C').first
			when nil
				prefix = 0
			else
				raise ArgumentError
			end
			prefix_mask = (2 ** prefix_bits) - 1
			raise ArgumentError if (prefix & prefix_mask) != 0
			if i < prefix_mask
				[prefix | i].pack('C')
			else
				bytes = ''
				bytes << [prefix | prefix_mask].pack('C')
				i -= prefix_mask
				while i >= 0x80
					bytes << [(i & 0x7F) | 0x80].pack('C')
					i >>= 7
				end
				bytes << [i].pack('C')
			end
		end

		#
		# Decodes an integer.
		#
		# @param String bytes
		# @param Integer prefix_bits
		# @return byte prefix, Integer i, String rest
		#
		def self.decode_int bytes, prefix_bits: 8
			bytes = bytes.to_s unless bytes.is_a? String
			raise ArgumentError if bytes.empty?
			raise ArgumentError if prefix_bits < 1 || prefix_bits > 8
			prefix_mask = (2 ** prefix_bits) - 1
			prefix, bytes = bytes.unpack('Ca*')
			i = prefix & prefix_mask
			prefix = [prefix - i].pack('C')
			if i >= prefix_mask
				shift = 1
				loop do
					b, bytes = bytes.unpack('Ca*')
					i += (b & 0x7F) * shift
					shift <<= 7
					break unless (b & 0x80) == 0x80
				end
			end
			[prefix, i, bytes]
		end

		#
		# Length-encodes a string literal.
		#
		# Uses Huffman coding iff that results in a shorter string.
		#
		def self.encode_string str
			huff = self.huffman_code_for str
			if huff.bytesize < str.bytesize
				self.encode_int(huff.bytesize, prefix_bits: 7, prefix: HUFFMAN_BIT) + huff
			else
				self.encode_int(str.bytesize, prefix_bits: 7) + str
			end
		end

		#
		# Reads a length-encoded string literal from the start
		# of a sequence of bytes.
		#
		# Decodes Huffman coded strings.
		#
		# @return [String str, String rest]
		#
		def self.decode_string bytes
			bytes = bytes.to_s unless bytes.is_a? String
			raise ArgumentError if bytes.empty?
			prefix, length, bytes = self.decode_int bytes, prefix_bits: 7
			raise ArgumentError if bytes.bytesize < length
			string = ''
			if length > 0
				string = bytes.byteslice(0, length)
				bytes = bytes.byteslice(length..-1)
			end
			# Handle Huffman-coded strings.
			if (prefix.unpack('C').first & HUFFMAN_BIT) == HUFFMAN_BIT
				string = self.string_from(string)
			end
			[string, bytes]
		end

		#
		# Get the Huffman code for a string.
		#
		def self.huffman_code_for str
			RUBYH2::HuffmanCodes.encode str
		end

		#
		# Get the string from a Huffman code.
		#
		# @throws RuntimeError if the code is invalid
		#
		def self.string_from huff
			RUBYH2::HuffmanCodes.decode huff
		end
	end
end

