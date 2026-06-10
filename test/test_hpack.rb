# encoding: BINARY
# vim: ts=2:sts=2:sw=2

require 'test/unit'
require_relative 'helpers'
$VERBOSE = true

require_relative '../lib/ruby-h2/hpack'
class Test_hpack < Test::Unit::TestCase
	include TestHelpers

	def test_static_table_header_names_match_rfc7541
		table = ::RUBYH2::Table.new
		assert_equal 'accept-language', table[17].name
		assert_equal 'vary', table[59].name
	end

	def test_static_table_name_lookup_uses_standard_header_names
		table = ::RUBYH2::Table.new
		assert_equal 17, table.find_name('accept-language')
		assert_nil table.find_name('accept-languages')
		assert_equal 59, table.find_name('vary')
		assert_nil table.find_name('var')
	end

	def test_indexed_header_decoding_uses_standard_header_names
		headers = []
		hpack = ::RUBYH2::HPack.new
		hpack.parse_block("\x91\xBB".b) {|name, value| headers << [name, value] }
		assert_equal [['accept-language', ''], ['vary', '']], headers
	end
end
