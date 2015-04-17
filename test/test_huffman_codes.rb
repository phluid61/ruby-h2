# encoding: BINARY
# vim: ts=2:sts=2:sw=2

require 'test/unit'
require_relative 'helpers'
$VERBOSE = true

require_relative '../lib/ruby-h2/hpack/huffman-codes'
class Test_huffman_codes < Test::Unit::TestCase
	include TestHelpers

	def test_encode_byte
		list = [
			[byte(' '), [0x14,6]],
			[byte('$'), [0x1ff9,13]],
			[byte('Z'), [0xfd,8]],
			[byte(253), [0x7ffffef,27]],
			[byte(256), [0x3fffffff,30]], # special case (??)
		]
		equal_tests(list) {|i| ::RUBYH2_HuffmanCodes.encode_byte i }
	end
	def test_encode_byte__error
		assert_raise ArgumentError do
			::RUBYH2_HuffmanCodes.encode_byte 257
		end
	end

	def test_decode_byte
		list = [
			[bits('010101'),   [37,[]]],
			[bits('01010101'), [37,[0,1]]],
		]
		equal_tests(list) {|i| ::RUBYH2_HuffmanCodes.decode_byte i }
	end
	def test_decode_byte__error
		assert_raise ArgumentError do
			::RUBYH2_HuffmanCodes.decode_byte bits('11111111')
		end
	end

	def test_encode
		list = [
			['www.example.com', "\xf1\xe3\xc2\xe5\xf2\x3a\x6b\xa0\xab\x90\xf4\xff"],
			['no-cache', "\xa8\xeb\x10\x64\x9c\xbf"],
			['Thu, 24 Oct 2013 18:32:21 GMT', "\xdf\x3d\xbf\x4a\x09\xa5\x35\x11\x2a\x08\x01\x65\x40\xbd\x71\x91\x5c\x10\x54\xc5\xa3\x7f"],
		]
		equal_tests(list) {|i| ::RUBYH2_HuffmanCodes.encode i }
	end

	def test_decode
		list = [
			["\xf1\xe3\xc2\xe5\xf2\x3a\x6b\xa0\xab\x90\xf4\xff", 'www.example.com'],
			["\xa8\xeb\x10\x64\x9c\xbf", 'no-cache'],
			["\xdf\x3d\xbf\x4a\x09\xa5\x35\x11\x2a\x08\x01\x65\x40\xbd\x71\x91\x5c\x10\x54\xc5\xa3\x7f", 'Thu, 24 Oct 2013 18:32:21 GMT'],
		]
		equal_tests(list) {|i| ::RUBYH2_HuffmanCodes.decode i }
	end
	def test_decode__error
		assert_raise ArgumentError do
			::RUBYH2_HuffmanCodes.decode 'Not a Huffman Sequence'
		end
	end
end

