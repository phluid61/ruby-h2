# vim: ts=2:sts=2:sw=2

require_relative 'frame-deserialiser'
require_relative 'headers-hook'

require 'logger'

class Receiver

	# paired with a single socket
	def initialize
		logger = Logger.new STDERR
		logger.progname = 'Receiver'
		logger.datetime_format = '%Y-%m-%d %H:%M:%S'
		logger.sev_threshold = Logger::DEBUG

		@desil = FrameDeserialiser.new
		@headers_hook = HeadersHook.new

		@desil.on_frame do |f|
			@headers_hook << f
		end

		@headers_hook.on_frame do |f|
			logger.info "received frame #{f.inspect}"
		end
		@headers_hook.on_stream do |sid, block|
			logger.info "new stream #{sid}\n#{block.inspect}"
		end
	end

	# pipe bytes in here
	def << bytes
		@desil << bytes
	end

end

