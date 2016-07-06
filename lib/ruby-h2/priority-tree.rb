# encoding: BINARY
# vim: ts=2 sts=2 sw=2 expandtab

require_relative 'errors'

module RUBYH2

  class PriorityTree
    Node = Struct.new(:parent_id, :weight)

    def initialize
      @nodes = {}
    end

    def add stream_id, parent_id, weight, exclusive
      # RFC 7540, Section 5.3.1
      # "A stream cannot depend on itself. An endpoint MUST treat this
      #  as a stream error (Section 5.4.2) of type PROTOCOL_ERROR."
      raise ConnectionError.new(Error::PROTOCOL_ERROR, "stream depends on itself") if parent_id == stream_id or has_parent? stream_id, stream_id

      # maybe create parent with default priority
      if parent_id != 0 && !@nodes[parent_id]
        @nodes[parent_id] = Node.new(0, 16)
      end

      if exclusive
        # insert between parent and any children
        children_of(parent_id) do |child_id|
          @nodes[child_id].parent_id = stream_id
        end
      end

      # add this stream to the tree
      @nodes[stream_id] = Node.new(parent_id, weight)

      self
    end

    def has_parent? child_id, parent_id
      node = @nodes[child_id]
      while node
        return true if node.parent_id == parent_id
        node = @nodes[node.parent_id]
      end
      false
    end

    def parents_of child_id
      parents = []
      node = @nodes[child_id]
      while node
        parents << node.parent_id if node.parent_id != 0
        node = @nodes[node.parent_id]
      end
      parents
    end

    def children_of parent_id
      pairs = @nodes.each_pair.find_all{|pair| pair[1].parent_id == parent_id }
      if block_given?
        pairs.each{|pair| yield pair[0] }
        nil
      else
        pairs.map{|pair| pair[0] }
      end
    end
  end

end

