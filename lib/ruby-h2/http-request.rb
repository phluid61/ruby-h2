# encoding: BINARY
# vim: ts=2 sts=2 sw=2 expandtab

require_relative 'http-message'

module RUBYH2

  class HTTPRequest < HTTPMessage
    def initialize stream, method, path, headers=nil, body=nil
      headers = headers ? headers.dup : {}
      headers[':method'] = method
      headers[':path'] = path
      super stream, %w( :method :path :authority ), headers, body
    end
  end

end

