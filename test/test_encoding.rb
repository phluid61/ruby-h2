# encoding: BINARY
# vim: ts=2:sts=2:sw=2

require 'test/unit'
require_relative 'helpers'
$VERBOSE = true

require_relative '../lib/ruby-h2/hpack/encoding'
class Test_encoding < Test::Unit::TestCase
	include TestHelpers

	def test_encode_int
		list = [
			[0x00, [0x00]],
			[0x01, [0x01]],
			[0xFE, [0xFE]],
			[0xFF, [0xFF,0x00]],
			[0x100,[0xFF,0x01]],
		]
		equal_tests(list) {|i| ::RUBYH2_HPackEncoding.encode_int(i).bytes }
	end

	def test_encode_int2
		list = [
			[[0x01, 8], [0x01]],
			[[0xFF, 8], [0xFF,0x00]],
			[[0x01, 7], [0x01]],
			[[0x7E, 7], [0x7E]],
			[[0x7F, 7], [0x7F,0x00]],
			[[0xFE, 7], [0x7F,0x7F]],
			[[0xFF, 7], [0x7F,0x80,0x01]],
			[[0x100,7], [0x7F,0x81,0x01]],
		]
		equal_tests(list) {|i,b| ::RUBYH2_HPackEncoding.encode_int(i, prefix_bits: b).bytes }
	end

	def test_encode_int3
		list = [
			[[0x01, 8, 0],     [0x01]],
			[[0x01, 8, "\0"],  [0x01]],
			[[0x01, 7, 0],     [0x01]],
			[[0x01, 7, "\x0"], [0x01]],
			[[0x01, 7, 0x80],  [0x81]],
		]
		equal_tests(list) {|i,b,p| ::RUBYH2_HPackEncoding.encode_int(i, prefix_bits: b, prefix: p).bytes }
	end

	def test_encode_int__error
		[
			[-1, 8, 0], # i < 0
			[1, 0, 0],  # prefix bits < 0
			[1, 9, 0],  # prefix bits > 8
			[1, 8, -1], # prefix < 0x00
			[1, 8, 0x100], # prefix > 0xFF
			[1, 8, ""],   # prefix not 1 byte
			[1, 8, "XX"], # prefix not 1 byte
			[1, 8, self], # prefix not Integer|String|NilClass
			[1, 4, 0xFF], # prefix sets masked bits
		].each do |i,b,p|
			assert_raise(ArgumentError) { ::RUBYH2_HPackEncoding.encode_int(i, prefix_bits: b, prefix: p) }
		end
	end

	def test_decode_int
		list = [
			["\x00", ["\x00", 0x00, '']],
			["\x01", ["\x00", 0x01, '']],
			["\xFE", ["\x00", 0xFE, '']],
			["\xFF\x00",    ["\x00", 0xFF, '']],
			["\xFF\x01",    ["\x00", 0x100,'']],
			["\x00abc",     ["\x00", 0x00, 'abc']],
			["\xFF\x01abc", ["\x00", 0x100,'abc']],
		]
		equal_tests(list) {|i| ::RUBYH2_HPackEncoding.decode_int i }
	end

	def test_decode_int2
		list = [
			[["\x00",         8], ["\x00", 0x00, '']],
			[["\xFF\x00",     8], ["\x00", 0xFF, '']],
			[["\x01",         7], ["\x00", 0x01, '']],
			[["\x7E",         7], ["\x00", 0x7E, '']],
			[["\x7F\x00",     7], ["\x00", 0x7F, '']],
			[["\x7F\x7F",     7], ["\x00", 0xFE, '']],
			[["\x7F\x80\x01", 7], ["\x00", 0xFF, '']],
			[["\x7F\x81\x01", 7], ["\x00", 0x100,'']],
			[["\x81",         7], ["\x80", 0x01, '']],
			[["\xFF\x81\x01", 7], ["\x80", 0x100,'']],
			[["\x00abc",      8], ["\x00", 0x00, 'abc']],
			[["\x01abc",      7], ["\x00", 0x01, 'abc']],
		]
		#assert_equal( x.inspect, ::RUBYH2_HPackEncoding.decode_int(b, prefix_bits: p).inspect )
		equal_tests(list) {|i,p| ::RUBYH2_HPackEncoding.decode_int i, prefix_bits: p }
	end

	def test_decode_int__error
		[
			['', 8], # no bytes
			["\x00", -1], # prefix bits < 0
			["\x00", 9], # prefix bits > 8
		].each do |b, p|
			assert_raise(ArgumentError) { ::RUBYH2_HPackEncoding.decode_int(b, prefix_bits: p) }
		end
	end

	def test_huffman_code_for
		list = [
			['', ''],
			[';', "\xFB"], # encodes to 8 bits
			['/', 'c'],    # encodes to 6 bits, plus padding
			['--', 'Yo'],  # encodes to 12 bits, plus padding
			['www.example.com', "\xF1\xE3\xC2\xE5\xF2\x3A\x6B\xA0\xAB\x90\xF4\xFF"],
			['/.well-known/host-meta', "\x61\x7F\x05\xA2\x85\xBA\xD4\x7F\x15\x31\x39\xD0\x95\xA9\x2A\x47"],
		]
		equal_tests(list) {|i| ::RUBYH2_HPackEncoding.huffman_code_for i }
	end

	def test_string_from
		list = [
			['', ''],
			["\xFB", ';'], # decode 8 bits
			['c', '/'],    # decode 6 bits, plus padding
			['Yo', '--'],  # decode 12 bits, plus padding
			["\xF1\xE3\xC2\xE5\xF2\x3A\x6B\xA0\xAB\x90\xF4\xFF", 'www.example.com'],
			["\x61\x7F\x05\xA2\x85\xBA\xD4\x7F\x15\x31\x39\xD0\x95\xA9\x2A\x47", '/.well-known/host-meta'],
		]
		equal_tests(list) {|i| ::RUBYH2_HPackEncoding.string_from i }
	end

	def test_string_from__error
		[
			"\xEA", # \xE9 would be 'j', but wrong padding
			"\x3F\xFF\xFF\xFF", # Valid encoding oF EOS
		].each do |i|
			assert_raise(ArgumentError, "#{i.inspect} should be invalid") { ::RUBYH2_HPackEncoding.string_from i }
		end
	end

	def test_encode_string
		foo = '<?>'*86
		list = [
			['', "\x00"],
			['Hello', "\x84\xC6\x5A\x28\x3F"],
			[foo, "\x7F\x83\x01#{foo}"],
		]
		equal_tests(list) {|i| ::RUBYH2_HPackEncoding.encode_string i }
	end

	def test_decode_string
		foo = 'foo'*86
		list = [
			["\x00", ['', '']],
			["\x05Hello", ['Hello', '']],
			["\x84\xC6\x5A\x28\x3F", ['Hello', ''],],
			["\x7F\x83\x01#{foo}", [foo,'']],
			["\x00bar", ['','bar']],
			["\x7F\x83\x01#{foo}bar", [foo,'bar']],
		]
		equal_tests(list) {|i| ::RUBYH2_HPackEncoding.decode_string i }
	end

	def test_decode_string__error
		[
			'', # no bytes
			"\x01", # not enough bytes
		].each do |i|
			assert_raises(ArgumentError) { ::RUBYH2_HPackEncoding.decode_string i }
		end
	end

end

