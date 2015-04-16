# vim: ts=2:sts=2:sw=2

module TestHelpers

	def byte b
		b = b.ord if b.is_a? String
		b
	end

	def bits b
		b = b.to_s(2) unless b.is_a? String
		b.scan(/./).map{|c|c.to_i}
	end

	def equal_tests list
		list.each do |i, x|
			o = yield i
			assert_equal x, o
		end
	end

end
