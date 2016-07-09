# encoding: BINARY
# vim: ts=2 sts=2 sw=2 expandtab

require_relative 'http-message'

module RUBYH2

  class HTTPRequest < HTTPMessage
    def initialize method, path, headers=nil, body=nil
      headers = headers ? headers.dup : {}
      headers[':method'] = method
      headers[':path'] = path
      super %w( :method :path :authority :scheme ), headers, body
    end
  end

end

