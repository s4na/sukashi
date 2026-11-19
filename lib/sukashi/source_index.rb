require "prism"

module Sukashi
  MethodBody = Struct.new(:path, :owner, :node, keyword_init: true) do
    def key
      [owner, !node.receiver.nil?, node.name]
    end
  end

  class SourceIndex
    GROUPS = %i[describe context].freeze
    EXAMPLES = %i[it specify example].freeze
    RSPEC_HOOK = /\A(?:(?:append|prepend)_)?(?:before|after|around)\z/
    ACTION_CALLBACK = /\A(?:(?:append|prepend)_)?(?:before|after|around)_action\z/
    CONTROLLER_DISPATCH = %i[render render_to_body render_to_string process process_action dispatch send_action].freeze
    MINITEST_HOOKS = %i[before_setup setup after_setup before_teardown teardown after_teardown].freeze

    attr_reader :sources, :methods, :definitions, :tests, :routes, :dependencies, :errors, :hooks, :unscoped_hooks, :controller_hooks, :custom_http_pipeline, :refinement_scopes, :trees

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
      @custom_http_pipeline = false
      @refinement_scopes = Set.new
      @open_dispatch = Set.new
      @assigned_constants = Set.new
      @constant_owners = Hash.new { |h, k| h[k] = Set.new }
      @errors = []
      @trees = {}
      sources.each do |path, text|
        result = Prism.parse(text, filepath: path)
        if result.success?
          @trees[path] = result.value
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
      @open_dispatch_names = @open_dispatch.compact.map { |name| name.split("::").last }.to_set
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
      parts = owner.to_s.split("::")
      @assigned_constants.include?(nil) || parts.any? { |part| @assigned_constants.include?(part) || @constant_owners[part].size > 1 } ||
        @open_dispatch.include?(nil) || @open_dispatch.include?(owner) ||
        @open_dispatch_names.include?(owner.to_s.split("::").last)
    end

    # eval or a computed constant name can reach any class by a runtime string.
    def opaque?
      @open_dispatch.include?(nil) || @assigned_constants.include?(nil)
    end

    # Files that name, require or route to path (one reverse edge, not the closure).
    # Files that issue HTTP requests or visits (request, integration and system tests).
    def http_callers
      @http_calls.map(&:first).uniq
    end

    def users_of(path)
      @reverse.fetch(path, [])
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

    def rack_extension?(node)
      return true if %i[use map].include?(node.name)
      return false unless node.name == :run
      arg = node.arguments&.arguments&.first
      !(arg.is_a?(Prism::CallNode) && arg.name == :application && self.class.constant(arg.receiver) == "Rails")
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
        if name
          owner = node.constant_path.location.slice.start_with?("::") ? name : [owner, name].compact.join("::")
        end
        short_name = name.to_s.split("::").last
        @constant_owners[short_name] << owner
        definitions[short_name] << path
      when Prism::ConstantWriteNode, Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode,
           Prism::ConstantOperatorWriteNode, Prism::ConstantTargetNode, Prism::ConstantPathTargetNode
        @assigned_constants << node.name.to_s
      when Prism::ConstantPathWriteNode, Prism::ConstantPathOrWriteNode,
           Prism::ConstantPathAndWriteNode, Prism::ConstantPathOperatorWriteNode
        @assigned_constants << node.target.name.to_s
      when Prism::AliasMethodNode, Prism::UndefNode
        @open_dispatch << owner
        controller_hooks << path
      when Prism::SingletonClassNode
        @open_dispatch << dispatch_owner(node.expression, owner)
      when Prism::DefNode
        method_owner = owner
        if node.receiver && !node.receiver.is_a?(Prism::SelfNode)
          # The receiver, not this file's lexical nesting, owns the method.
          # Retain all candidates for qualified/aliased or computed receivers.
          method_owner = self.class.constant(node.receiver)
          @open_dispatch << method_owner
        end
        methods[[method_owner, !node.receiver.nil?, node.name]] << MethodBody.new(path: path, owner: method_owner, node: node)
        tests[[path, node.location.start_line]] << node if node.name.to_s.start_with?("test_")
        hooks << path if MINITEST_HOOKS.include?(node.name)
        controller_hooks << path if CONTROLLER_DISPATCH.include?(node.name)
      when Prism::CallNode
        if GROUPS.include?(node.name) && (self.class.constant(node.receiver) == "RSpec" || (in_example_group && !node.receiver))
          in_example_group = true
          # Unknown DSL at group definition time may install arbitrary hooks.
          # Inspect group statements, not the calls made inside an example.
          body = node.block.body if node.block.is_a?(Prism::BlockNode)
          if body && (!body.is_a?(Prism::StatementsNode) || body.body.any? { |n|
            !n.is_a?(Prism::CallNode) || n.receiver || !(EXAMPLES.include?(n.name) || GROUPS.include?(n.name))
          })
            hooks << path
          end
        elsif %i[configure shared_examples shared_examples_for shared_context].include?(node.name)
          in_example_group = false
        end
        if in_example_group && !node.receiver && %i[it specify example let let! subject subject! before after around].include?(node.name) &&
           node.block.is_a?(Prism::BlockNode) && node.block.body
          @local_bodies[path] << node.block.body.location
        end
        refinement_scopes << path if node.name == :using
        if node.name == :refine
          @open_dispatch << dispatch_owner(node.arguments&.arguments&.first, owner)
        end
        if %i[const_set remove_const autoload].include?(node.name)
          arg = node.arguments&.arguments&.first
          @assigned_constants << ([Prism::StringNode, Prism::SymbolNode].include?(arg.class) ? arg.unescaped : nil)
        end
        if node.name == :eval
          @open_dispatch << nil # A binding can refer to any receiver.
        elsif %i[prepend extend define_singleton_method define_method alias_method remove_method undef_method
                 class_eval class_exec module_eval module_exec instance_eval instance_exec].include?(node.name)
          @open_dispatch << dispatch_owner(node.receiver, owner)
        end
        # Initializers can retain the middleware stack and mutate it later.
        # Also cover Rack::Builder's bare use/map/run DSL in rackup files.
        if node.name == :middleware || (path.end_with?(".ru") && rack_extension?(node))
          @custom_http_pipeline = true
        end
        record_dsl(node, path)
        if %i[it specify example test].include?(node.name) && node.block.is_a?(Prism::BlockNode)
          tests[[path, node.location.start_line]] << node.block
        end
        if RSPEC_HOOK.match?(node.name) || %i[let let! subject subject! fixtures include_context include_examples
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
      node.compact_child_nodes.each { |child| scan(child, path, owner, in_example_group) }
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
      # Calling a named route helper can execute project code before dispatch.
      return unless @simple && node.is_a?(Prism::StringNode)
      entries = @entries[[verb, node.unescaped]]
      entries.first if entries.one?
    end

    private

    def add(node)
      return unless node.is_a?(Prism::CallNode) && !node.receiver && !node.block
      args = node.arguments&.arguments || []
      if node.name == :resources && args.one? && args.first.is_a?(Prism::SymbolNode)
        name = args.first.unescaped
        register(:get, "/" + name, name, "index")
        register(:post, "/" + name, name, "create")
      elsif HTTP.include?(node.name) && args.size == 2 && args.first.is_a?(Prism::StringNode) && args.last.is_a?(Prism::KeywordHashNode)
        options = {}
        args.last.elements.each do |assoc|
          return nil unless assoc.is_a?(Prism::AssocNode) && assoc.key.is_a?(Prism::SymbolNode) &&
            %w[to as].include?(assoc.key.unescaped) && [Prism::StringNode, Prism::SymbolNode].include?(assoc.value.class)
          options[assoc.key.unescaped] = assoc.value.unescaped
        end
        target = options["to"]&.match(/\A([a-z_]+)#([a-z_]\w*)\z/)
        path = args.first.unescaped.delete_prefix("/")
        return unless target && path.match?(%r{\A[\w/-]*\z})
        register(node.name, "/" + path, target[1], target[2])
      else
        return false
      end
      true
    end

    def register(verb, path, controller, action)
      key = [controller.split("_").map(&:capitalize).join + "Controller", false, action.to_sym]
      @entries[[verb, path]] << key
    end
  end
end
