# encoding: BINARY
# vim: ts=2:sts=2:sw=2

require 'test/unit'
$VERBOSE = true

require_relative '../lib/ruby-h2/http-agent'

class Test_http_agent < Test::Unit::TestCase

	def test_window_update_stops_draining_when_connection_window_exhausted
		agent = ::RUBYH2::HTTPAgent.new
		stream = ::RUBYH2::Stream.new(65_535)
		queued = ::RUBYH2::Frame.new(::RUBYH2::FrameTypes::DATA, 0, 1, 'abcdef')
		update = ::RUBYH2::Frame.new(::RUBYH2::FrameTypes::WINDOW_UPDATE, 0, 0, [1].pack('N'))

		agent.instance_variable_set(:@streams, {1 => stream})
		agent.instance_variable_set(:@window_size, 0)
		agent.instance_variable_set(:@window_queue, {1 => [queued]})

		assert_nothing_raised do
			agent.send(:handle_window_update, update)
		end

		assert_equal [queued], agent.instance_variable_get(:@window_queue)[1]
	end

end
