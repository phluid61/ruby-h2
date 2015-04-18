# vim: ts=2:sts=2:sw=2

class Frame
	def initialize type, flags, sid, payload
		@type = type
		@flags = flags
		@sid = sid
		@payload = payload.dup.freeze
	end
	attr_reader :type
	attr_reader :flags
	attr_reader :sid
	attr_reader :payload
end

