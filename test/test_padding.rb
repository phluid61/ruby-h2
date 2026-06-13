# encoding: BINARY
# frozen_string_literal: true
# vim: ts=2:sts=2:sw=2:expandtab

require 'test/unit'
require_relative 'helpers'
$VERBOSE = true

require_relative '../lib/ruby-h2/http-agent'

class Test_padding < Test::Unit::TestCase
  include TestHelpers

  FLAG_PADDED = RUBYH2::HTTPAgent::FLAG_PADDED

  def setup
    @agent = RUBYH2::HTTPAgent.new
  end

  def pad data, modulus=256
    hash = {:bytes => data.b, :flags => 0}
    @agent.send(:_pad, hash, modulus)
    hash
  end

  def strip bytes
    @agent.send(:strip_padding, bytes)
  end

  # Basic padding: total payload should be a multiple of modulus,
  # FLAG_PADDED should be set, and strip_padding recovers the original data.
  def test_basic_padding
    data = 'x' * 100
    h = pad(data)
    assert_equal FLAG_PADDED, h[:flags] & FLAG_PADDED, 'FLAG_PADDED should be set'
    assert_equal 0, h[:bytes].bytesize % 256, 'padded payload should be a multiple of 256'
    assert_equal data.b, strip(h[:bytes]), 'strip_padding should recover original data'
  end

  # Padding round-trips for various data sizes across a full modulus cycle.
  def test_roundtrip_various_lengths
    (0..255).each do |len|
      data = 'a' * len
      h = pad(data)
      assert_equal data.b, strip(h[:bytes]), "round-trip failed for len=#{len}"
    end
  end

  # Padded payload must never exceed @max_frame_size.
  def test_never_exceeds_max_frame_size
    @agent.instance_variable_set(:@max_frame_size, 512)
    (490..512).each do |len|
      h = pad('b' * len)
      assert h[:bytes].bytesize <= 512,
        "payload #{h[:bytes].bytesize} exceeds max_frame_size=512 for len=#{len}"
    end
  end

  # Off-by-one regression (issue #3):
  # With max_frame_size=511 and len=500, modulus=256, the natural padded size
  # would be 512 (= 256*2). The old guard (len+rem > max) was false at 511,
  # allowing a 512-byte payload. The fix (len+rem+1 > max) clamps it to 511.
  def test_off_by_one_regression
    @agent.instance_variable_set(:@max_frame_size, 511)
    h = pad('c' * 500)
    assert_equal 511, h[:bytes].bytesize,
      'payload should be clamped to max_frame_size, not max_frame_size+1'
  end

  # When data length already meets or exceeds max_frame_size, no padding is
  # applied (FLAG_PADDED stays clear and the payload is unchanged).
  def test_no_padding_when_no_room
    @agent.instance_variable_set(:@max_frame_size, 100)
    data = 'z' * 100
    h = pad(data)
    assert_equal 0, h[:flags] & FLAG_PADDED, 'FLAG_PADDED should not be set when no room'
    assert_equal data.b, h[:bytes], 'bytes should be unchanged when no padding applied'
  end
end
