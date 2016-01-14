# vim: ts=2 sts=2 sw=2

require_relative '__01_library'

$port = 8888

get '/' do
	<<HTML
<!DOCTYPE html>
<html lang="en"><head><title>Index</title></head><body><h1>Index</h1><p>This is the index.</p></body></html>
HTML
end

