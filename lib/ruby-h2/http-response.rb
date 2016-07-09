# encoding: BINARY
# vim: ts=2 sts=2 sw=2 expandtab

require_relative 'http-message'

module RUBYH2

  class HTTPResponse < HTTPMessage
    def initialize status=nil, headers=nil, body=nil
      headers = headers ? headers.dup : {}
      headers[':status'] = status
      super %w( :status ), headers, body
    end
  end

end

