require_relative "source_index"

module Sukashi
  # Mask literals inside eligible arms, then compare the *entire* blob. An edit
  # elsewhere, including to the predicate, cannot accidentally become an arm edit.
  class BranchDiff
    LITERALS = [Prism::IntegerNode, Prism::FloatNode, Prism::StringNode, Prism::SymbolNode].freeze

    def self.between(old, new_index, path)
      left, before = template(old, path)
      right, after = template(new_index, path)
      return unless left == right && before.map(&:first) == after.map(&:first)
      changes = before.zip(after).filter_map { |(key, a), (_, b)| key if a != b }.uniq
      changes unless changes.empty?
    end

    def self.template(index, path)
      literals = []
      index.methods.each_value do |definitions|
        next unless definitions.one?
        method = definitions.first
        next unless method.path == path && method.node.receiver.is_a?(Prism::SelfNode)
        params = method.node.parameters
        body = method.node.body
        next unless params && params.compact_child_nodes.one? && params.requireds.one? && body.is_a?(Prism::StatementsNode) && body.body.one?
        branch = body.body.first
        next unless branch.is_a?(Prism::IfNode) && branch.if_keyword == "if" && branch.subsequent.is_a?(Prism::ElseNode)
        next unless branch.predicate.is_a?(Prism::LocalVariableReadNode) && branch.predicate.name == params.requireds.first.name
        [[true, branch.statements], [false, branch.subsequent.statements]].each do |arm, statements|
          next unless statements
          statements.body.each do |statement|
            values = if statement.is_a?(Prism::CallNode) && statement.receiver && !statement.block
              statement.arguments&.arguments || []
            else
              [statement]
            end
            values.each do |v|
              literals << [v.location, method.key + [arm], v.type] if LITERALS.include?(v.class)
            end
          end
        end
      end
      source = index.sources.fetch(path).b
      pieces = []
      values = []
      offset = 0
      literals.sort_by { |loc, _, _| loc.start_offset }.each do |loc, key, type|
        pieces << source.byteslice(offset...loc.start_offset) << type
        values << [key, loc.slice]
        offset = loc.end_offset
      end
      [pieces << source.byteslice(offset..), values]
    end
  end

  # Only discard a test if every modeled call path is known. Unknown calls,
  # callbacks, dynamic URL construction and multiple possible definitions keep it.
  class Reachability
    ASSERTIONS = %i[expect to not_to to_not eq eql be assert_equal assert_nil assert refute refute_equal].freeze
    attr_reader :evidence

    def initialize(index, targets, test_paths, broad_users)
      @index, @targets, @broad_users = index, targets, broad_users
      @users = index.dependents(targets.values.flat_map { |t| t[:paths] }.uniq)
      @global_hook = !index.unscoped_hooks.empty? || !(index.hooks - test_paths).empty?
      @controller_users = index.dependents(index.controller_hooks.to_a)
      @hook_users = index.dependents(index.hooks.to_a)
    end

    def inspect_test(path, line)
      @evidence = []
      @unknown = false
      return :file if @broad_users.include?(path)
      return :unknown if @global_hook || @hook_users.include?(path)
      nodes = @index.tests[[path, line]]
      return :unknown unless nodes.one?
      trace(nodes.first.body, {}, [])
      return :affected if @evidence.any? { |key, arm| @targets.fetch(key)[:arms].include?(arm) }
      return :unknown if @unknown
      return :other_arm unless @evidence.empty?
      @users.include?(path) ? :unknown : :unrelated
    end

    private

    def trace(node, bindings, stack)
      return unless node
      case node
      when Prism::StatementsNode, Prism::ArgumentsNode, Prism::KeywordHashNode, Prism::AssocNode
        node.each_child_node { |n| trace(n, bindings, stack) }
      when Prism::CallNode
        trace_call(node, bindings, stack)
      when Prism::IntegerNode, Prism::FloatNode, Prism::TrueNode, Prism::FalseNode, Prism::NilNode,
           Prism::StringNode, Prism::SymbolNode
        # Literal with no further calls.
      when Prism::LocalVariableReadNode
        @unknown = true unless bindings.key?(node.name)
      else
        @unknown = true
      end
    end

    def trace_call(node, bindings, stack)
      return @unknown = true if node.block
      args = node.arguments&.arguments || []
      if !node.receiver && (Routes::HTTP.include?(node.name) || node.name == :visit)
        key = @index.routes&.lookup(node.name == :visit ? :get : node.name, args.first)
        return @unknown = true unless key && args.one?
        return follow(key, [], stack, controller_action: true)
      end
      if (owner = SourceIndex.constant(node.receiver))
        args.each { |a| trace(a, bindings, stack) }
        values = args.map do |a|
          case a
          when Prism::TrueNode then true
          when Prism::FalseNode then false
          when Prism::LocalVariableReadNode then bindings[a.name]
          end
        end
        key = [owner, true, node.name]
        return @unknown = true if @index.shadowed?(key)
        return follow(key, values, stack)
      end
      # Reading the Rack response after a request does not issue a new request.
      if node.name == :body && args.empty? && node.receiver.is_a?(Prism::CallNode) &&
         node.receiver.name == :response && !node.receiver.receiver && !node.receiver.arguments
        return
      end
      if ASSERTIONS.include?(node.name) || plain_render?(node)
        trace(node.receiver, bindings, stack)
        args.each { |a| trace(a, bindings, stack) }
      else
        @unknown = true
      end
    end

    def plain_render?(node)
      return false unless node.is_a?(Prism::CallNode) && !node.receiver && node.name == :render && !node.block
      args = node.arguments&.arguments
      return false unless args&.one? && args.first.is_a?(Prism::KeywordHashNode) && args.first.elements.one?
      assoc = args.first.elements.first
      assoc.is_a?(Prism::AssocNode) && assoc.key.is_a?(Prism::SymbolNode) && assoc.key.unescaped == "plain"
    end

    def follow(key, values, stack, controller_action: false)
      return @unknown = true if @index.dynamic_dispatch?(key.first)
      definitions = @index.methods[key]
      return @unknown = true unless definitions.one? && !stack.include?(key)
      method = definitions.first
      if controller_action
        return @unknown = true if @index.custom_http_pipeline
        body = method.node.body
        return @unknown = true unless body.is_a?(Prism::StatementsNode) && plain_render?(body.body.last)
      end
      return @unknown = true if @controller_users.include?(method.path)
      if @targets.key?(key)
        arm = values.first
        return @unknown = true unless arm == true || arm == false
        @evidence << [key, arm]
        branch = method.node.body.body.first
        taken = arm ? branch.statements : branch.subsequent.statements
        trace(taken, { method.node.parameters.requireds.first.name => arm }, stack + [key])
      else
        params = method.node.parameters
        names = params ? params.requireds.map(&:name) : []
        return @unknown = true unless names.size == values.size && (!params || params.compact_child_nodes.size == names.size)
        trace(method.node.body, names.zip(values).to_h, stack + [key])
      end
    end
  end
end
