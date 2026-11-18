require "prism"
require "set"

module Sukashi
  MethodBody = Struct.new(:path, :owner, :node, keyword_init: true) do
    def key
      [owner, !node.receiver.nil?, node.name]
    end
  end

  class SourceIndex
    ACTION_CALLBACK = /\A(?:(?:append|prepend)_)?(?:before|after|around)_action\z/
    MINITEST_HOOKS = %i[before_setup setup after_setup before_teardown teardown after_teardown].freeze

    attr_reader :sources, :methods, :definitions, :tests, :routes, :dependencies, :errors, :hooks, :unscoped_hooks, :controller_hooks

    def initialize(sources)
      @sources = sources
      @methods = Hash.new { |h, k| h[k] = [] }
      @definitions = Hash.new { |h, k| h[k] = Set.new }
      @http_calls = []
      @named_defs = Hash.new { |h, k| h[k] = Set.new }
      @named_uses = Hash.new { |h, k| h[k] = Set.new }
      @references = Hash.new { |h, k| h[k] = Set.new }
      @dependencies = Hash.new { |h, k| h[k] = Set.new }
      @local_bodies = Hash.new { |h, k| h[k] = [] }
      @tests = Hash.new { |h, k| h[k] = [] }
      @hooks = Set.new
      @unscoped_hooks = Set.new
      @controller_hooks = Set.new
      @open_dispatch = Set.new
      @errors = []
      sources.each do |path, text|
        result = Prism.parse(text, filepath: path)
        if result.success?
          scan(result.value, path, nil)
          @routes = Routes.new(result.value) if path == "config/routes.rb"
        else
          errors << path
        end
      end
      @references.each do |path, names|
        names.each { |name| dependencies[path].merge(definitions[name]) }
      end
      @named_uses.each do |path, names|
        names.each { |name| dependencies[path].merge(@named_defs[name]) }
      end
      @http_calls.each do |path, verb, arg|
        route = routes&.lookup(verb, arg)
        dependencies[path].merge(definitions[route.first]) if route
      end
      @shadowed_methods = Set.new
      methods.each_key do |owner, singleton, name|
        next unless owner
        parts = owner.split("::")
        (1...parts.size).each { |i| @shadowed_methods << [parts.drop(i).join("::"), singleton, name] }
      end
      @reverse = Hash.new { |h, k| h[k] = [] }
      dependencies.each { |user, defs| defs.each { |d| @reverse[d] << user } }
    end

    # Compare the bytes outside local DSL bodies. A change to a top-level
    # require, global configuration or group declaration falls back to the graph.
    def local_spec_template(path)
      spans = @local_bodies[path]
      return if spans.empty? || unscoped_hooks.include?(path)
      source = sources.fetch(path).b
      offset = 0
      chunks = []
      spans.each do |span|
        next if span.start_offset < offset
        chunks << source.byteslice(offset...span.start_offset)
        offset = span.end_offset
      end
      chunks << source.byteslice(offset..)
    end

    def dynamic_dispatch?(owner)
      @open_dispatch.include?(nil) || @open_dispatch.include?(owner) ||
        @open_dispatch.include?(owner.to_s.split("::").last)
    end

    def shadowed?(key)
      @shadowed_methods.include?(key)
    end

    def self.constant(node)
      case node
      when Prism::ConstantReadNode then node.name.to_s
      when Prism::ConstantPathNode then node.full_name&.delete_prefix("::")
      end
    rescue Prism::ConstantPathNode::DynamicPartsInConstantPathError
      nil
    end

    def dependents(paths)
      queue = paths.dup
      visited = paths.to_set
      i = 0
      while i < queue.size
        @reverse[queue[i]].each { |p| queue << p if visited.add?(p) }
        i += 1
      end
      visited
    end

    private

    def record_dsl(node, path)
      arg = node.arguments&.arguments&.first
      return unless arg.is_a?(Prism::SymbolNode) || arg.is_a?(Prism::StringNode)
      name = arg.unescaped
      case node.name
      when :factory then @named_defs[[:factory, name]] << path
      when :build, :create, :build_stubbed, :attributes_for then @named_uses[path] << [:factory, name]
      when :shared_examples, :shared_examples_for, :shared_context then @named_defs[[:shared, name]] << path
      when :include_examples, :include_context, :it_behaves_like then @named_uses[path] << [:shared, name]
      end
    end

    def dispatch_owner(receiver, lexical_owner)
      if receiver.is_a?(Prism::CallNode) && receiver.name == :singleton_class
        receiver = receiver.receiver
      end
      return lexical_owner if !receiver || receiver.is_a?(Prism::SelfNode)
      self.class.constant(receiver)
    end

    def scan(node, path, owner, in_example_group = false)
      case node
      when Prism::ClassNode, Prism::ModuleNode
        name = self.class.constant(node.constant_path)
        owner = [owner, name].compact.join("::") if name
        definitions[name.to_s.split("::").last] << path
      when Prism::SingletonClassNode
        @open_dispatch << dispatch_owner(node.expression, owner)
      when Prism::DefNode
        methods[[owner, !node.receiver.nil?, node.name]] << MethodBody.new(path: path, owner: owner, node: node)
        tests[[path, node.location.start_line]] << node if node.name.to_s.start_with?("test_")
        hooks << path if MINITEST_HOOKS.include?(node.name)
      when Prism::CallNode
        if %i[describe context].include?(node.name) && self.class.constant(node.receiver) == "RSpec"
          in_example_group = true
        elsif %i[configure shared_examples shared_examples_for shared_context].include?(node.name)
          in_example_group = false
        end
        if in_example_group && !node.receiver && %i[it specify example let let! subject subject! before after around].include?(node.name) &&
           node.block.is_a?(Prism::BlockNode) && node.block.body
          @local_bodies[path] << node.block.body.location
        end
        if %i[prepend extend define_singleton_method define_method alias_method class_eval class_exec module_eval].include?(node.name)
          @open_dispatch << dispatch_owner(node.receiver, owner)
        end
        record_dsl(node, path)
        if %i[it specify example test].include?(node.name) && node.block.is_a?(Prism::BlockNode)
          tests[[path, node.location.start_line]] << node.block
        end
        if %i[before after around let let! subject subject! fixtures include_context include_examples
              it_behaves_like setup teardown].include?(node.name)
          hooks << path
          unscoped_hooks << path unless in_example_group && !node.receiver
        elsif ACTION_CALLBACK.match?(node.name) || node.name == :set_callback
          owner ? controller_hooks << path : unscoped_hooks << path
        end
        if !node.receiver && (Routes::HTTP.include?(node.name) || node.name == :visit)
          @http_calls << [path, node.name == :visit ? :get : node.name, node.arguments&.arguments&.first]
        end
        if node.name == :require_relative && (arg = node.arguments&.arguments&.first).is_a?(Prism::StringNode)
          target = File.expand_path(arg.unescaped, File.dirname("/" + path)).delete_prefix("/")
          dependencies[path] << (target.end_with?(".rb") ? target : target + ".rb")
        end
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        @references[path] << node.name.to_s
      end
      node.each_child_node { |child| scan(child, path, owner, in_example_group) }
    end
  end

  class Routes
    HTTP = %i[get post put patch delete].freeze

    def initialize(tree)
      @entries = Hash.new { |h, k| h[k] = [] }
      top = tree.statements.body
      root = top.first
      @simple = top.one? && root.is_a?(Prism::CallNode) && root.name == :draw && root.block.is_a?(Prism::BlockNode)
      return unless @simple
      Array(root.block.body&.body).each { |n| @simple = false unless add(n) }
    end

    def lookup(verb, node)
      return unless @simple
      path = case node
      when Prism::StringNode then node.unescaped
      when Prism::CallNode then node.name.to_s if !node.receiver && !node.arguments
      end
      entries = @entries[[verb, path]]
      entries.first if entries.one?
    end

    private

    def add(node)
      return unless node.is_a?(Prism::CallNode) && !node.receiver && !node.block
      args = node.arguments&.arguments || []
      if node.name == :resources && args.one? && args.first.is_a?(Prism::SymbolNode)
        name = args.first.unescaped
        register(:get, "/" + name, name, "index", name)
        register(:post, "/" + name, name, "create", name)
      elsif HTTP.include?(node.name) && args.size == 2 && args.first.is_a?(Prism::StringNode) && args.last.is_a?(Prism::KeywordHashNode)
        options = {}
        args.last.elements.each do |assoc|
          return unless assoc.is_a?(Prism::AssocNode) && assoc.key.is_a?(Prism::SymbolNode) &&
            %w[to as].include?(assoc.key.unescaped) && [Prism::StringNode, Prism::SymbolNode].include?(assoc.value.class)
          options[assoc.key.unescaped] = assoc.value.unescaped
        end
        target = options["to"]&.match(/\A([a-z_]+)#([a-z_]\w*)\z/)
        path = args.first.unescaped.delete_prefix("/")
        return unless target && path.match?(%r{\A[\w/-]*\z})
        register(node.name, "/" + path, target[1], target[2], options["as"])
      else
        return false
      end
      true
    end

    def register(verb, path, controller, action, helper)
      key = [controller.split("_").map(&:capitalize).join + "Controller", false, action.to_sym]
      @entries[[verb, path]] << key
      @entries[[verb, helper + "_path"]] << key if helper
    end
  end
end
