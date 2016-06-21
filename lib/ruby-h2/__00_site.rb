# encoding: BINARY
# vim: ts=2 sts=2 sw=2

require_relative '__01_library'

Application.port = 8888
Application.https = true

get '/' do
	<<HTML
<!DOCTYPE html>
<html lang="en"><head><title>Index</title></head><body><h1>Index</h1><p>This is the index.</p><ul><li><a href="/">simple test</a></li><li><a href="/padded">padding test</a></li></ul></body></html>
HTML
end

get '/padded' do |request, response|
	response.pad!
	<<HTML
<!DOCTYPE html>
<html lang="en"><head><title>Padded</title></head><body><h1>Padded</h1><p>This response should be padded.</p><ul><li><a href="/">simple test</a></li><li><a href="/padded">padding test</a></li></ul></body></html>
HTML
end

