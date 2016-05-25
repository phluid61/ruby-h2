# encoding: BINARY
# vim: ts=2:sts=2:sw=2

require_relative 'frame'
require_relative 'frame-types'

module RUBYH2
	module Settings

		HEADER_TABLE_SIZE      = 0x1
		ENABLE_PUSH            = 0x2
		MAX_CONCURRENT_STREAMS = 0x3
		INITIAL_WINDOW_SIZE    = 0x4
		MAX_FRAME_SIZE         = 0x5
		MAX_HEADER_LIST_SIZE   = 0x6

		class << self

			def frame_from pairs
				b = String.new.b
				pairs.each_pair do |k,v|
					b << [k, v].pack('nN')
				end
				RUBYH2::Frame.new FrameTypes::SETTINGS, 0, 0, b
			end

			def pairs_from frame
				raise if frame.type != FrameTypes::SETTINGS #FIXME
				hash = {}
				bytes = frame.payload
				while !bytes.empty?
					raise if bytes.bytesize < 6
					k, v, bytes = bytes.unpack('nNa*')
					hash[k] = v
				end
				hash
			end

		end
	end
end

