#!/usr/bin/env ruby
require 'github/markdown'
puts GitHub::Markdown.render_gfm File.read(ARGV[0])

