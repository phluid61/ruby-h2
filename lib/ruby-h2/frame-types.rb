# encoding: BINARY
# vim: ts=2:sts=2:sw=2

module RUBYH2
	module FrameTypes
		DATA          = 0x0
		HEADERS       = 0x1
		PRIORITY      = 0x2
		RST_STREAM    = 0x3
		SETTINGS      = 0x4
		PUSH_PROMISE  = 0x5
		PING          = 0x6
		GOAWAY        = 0x7
		WINDOW_UPDATE = 0x8
		CONTINUATION  = 0x9

		GZIPPED_DATA  = 0xf0 # Experimental
		DROPPED_FRAME = 0xf1
	end
end

