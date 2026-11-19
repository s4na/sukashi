require "prism"
require_relative "source_index"

module Sukashi
  # Opt-in assumption `constant_reachability`: project code reaches a project
  # class only by naming it (a constant reference, a string or symbol holding a
  # form of its name, or a subclass relation), not through state shared between
  # tests. Under that assumption a test file outside the escape closure U of the
  # changed files cannot observe the change.
  #
  # The closure starts from the changed files and repeatedly adds
  #   - files that refer to a file in U (constants, factories, shared examples,
  #     routes, require_relative),
  #   - Ruby files whose string or symbol literals contain a name form of a
  #     class or module defined in U,
  #   - the files defining the superclass of a class in U (STI, descendants),
  #     unless that superclass declares `self.abstract_class = true`,
  #   - every file that issues HTTP requests or visits, once U contains a
  #     controller, a view helper or config/routes.rb (requests reach
  #     controllers through routing and templates call helpers by method
  #     name, not by naming them).
  #
  # Anything the assumption cannot bound makes #closure return nil, and the
  # caller keeps the existing per-test analysis. See docs/selection-safety.md.
  class ConstantReachability
    STRING_REFLECTION = %i[constantize safe_constantize].freeze
    NAME_REFLECTION = %i[const_get const_defined? const_source_location qualified_const_get].freeze
    REFLECTION = %i[descendants subclasses direct_descendants each_object const_missing inflections].freeze
    METHOD_OBJECTS = %i[method public_method instance_method].freeze
    SENDS = %i[send public_send __send__ try try!].freeze
    # Receiverless calls whose block runs when the file loads or is included.
    EAGER_BLOCKS = %i[included prepended class_methods extended inherited describe context shared_examples
                      shared_examples_for shared_context].freeze
    # Load-time receivers that do not keep project objects.
    INERT_RECEIVERS = %w[RSpec FactoryBot Struct Data Set Regexp Hash Array String Integer Float Rational Complex
                         BigDecimal].freeze
    IRREGULAR = { "person" => "people", "man" => "men", "child" => "children", "mouse" => "mice",
                  "louse" => "lice" }.freeze

    Facts = Struct.new(:blob, :classes, :global_write, :load_receivers, :abstract)

    ROUTES = "config/routes.rb".freeze

    attr_reader :forms, :escape

    # shared: path -> true when it matches full_on. external: normalized names
    # of gems whose namespaces a project file must not reopen.
    def initialize(index, test_paths, shared:, external:)
      @index, @shared, @external = index, shared, external
      @test_paths = test_paths
      @hook_paths = (index.hooks - test_paths) | index.unscoped_hooks
      @facts = {}
      @reflective = []
      @abstract = Set.new
      index.trees.each do |path, tree|
        facts = Facts.new(String.new(encoding: Encoding::BINARY), [], false, [], [])
        walk(tree, path, facts, nil, false)
        @facts[path] = facts
        @abstract.merge(facts.abstract)
      end
    end

    # http: start with every HTTP caller, for changes rendered by templates.
    def closure(changed, http: false)
      return escape!("eval or computed constant name") if @index.opaque?
      return escape!("reflective lookup in #{@reflective.first}") unless @reflective.empty?
      reach = Set.new
      queue = []
      push = ->(path) { queue << path if reach.add?(path) }
      segments = Set.new
      @forms = Set.new
      @http = false
      pull_http = lambda do
        next if @http
        @http = true
        @index.http_callers.each(&push)
      end
      changed.each(&push)
      pull_http.call if http
      until queue.empty?
        current = queue.shift
        @index.users_of(current).each(&push)
        facts = @facts[current]
        pull_http.call if current == ROUTES || http_surface?(current, facts)
        next unless facts
        facts.classes.each { |name, _| segments.merge(name.split("::")) }
        # Application code does not name or instantiate test classes.
        next if @test_paths.include?(current)
        facts.classes.each do |name, superclass|
          name_forms(name.split("::").last).each do |form|
            next unless @forms.add?(form)
            needle = form.b
            @facts.each { |other, f| push.(other) if f.blob.include?(needle) }
          end
          next if !superclass || @abstract.include?(superclass)
          @index.definitions.fetch(superclass.split("::").last, []).each do |other|
            push.(other) if @facts[other]&.classes&.any? { |n, _| n == superclass || n.end_with?("::#{superclass}") }
          end
        end
      end
      reach.each do |path|
        # The route table is drawn at boot and only maps requests to controllers.
        next if path == ROUTES && !@hook_paths.include?(path)
        return escape!("shared setup or full_on path #{path}") if @hook_paths.include?(path) || @shared.call(path)
        facts = @facts[path] or next
        return escape!("global variable write in #{path}") if facts.global_write
        facts.load_receivers.each do |root|
          next if root && (segments.include?(root) || INERT_RECEIVERS.include?(root))
          return escape!("load-time call on #{root || 'a dynamic receiver'} in #{path}")
        end
        facts.classes.each do |name, _|
          root = name.split("::").first
          return escape!("reopens external namespace #{root} in #{path}") if external?(root)
        end
      end
      reach
    end

    # Whether the last closure pulled in every HTTP caller.
    def http?
      @http
    end

    def self.normalize(name)
      name.downcase.delete("_-")
    end

    private

    def escape!(reason)
      @escape = reason
      nil
    end

    # Controllers and view helpers: reached through requests and templates.
    def http_surface?(path, facts)
      path.start_with?("app/controllers/", "app/helpers/") ||
        facts&.classes&.any? { |name, _| name.end_with?("Controller", "Helper") }
    end

    def external?(root)
      @external.include?(self.class.normalize(root)) ||
        (root.match?(/\A[A-Z]\w*\z/) && Object.const_defined?(root, false))
    end

    def name_forms(short)
      under = short.gsub(/([A-Z\d]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
      words = under.split("_")
      last = words.last.to_s
      prefix = short.end_with?(last.capitalize) ? short.delete_suffix(last.capitalize) : nil
      forms = [short, under]
      [stem(last), IRREGULAR[last]].compact.each do |word|
        forms << (words[0...-1] + [word]).join("_")
        forms << prefix + word.capitalize if prefix
      end
      forms.select { |form| form.length >= 3 }.uniq
    end

    # A prefix of every common English plural: drop -es/-ies/-ves endings.
    def stem(word)
      cut = if word.length >= 5 || word.end_with?("fe")
              2
            elsif word.end_with?("y", "f", "s")
              1
            else
              0
            end
      stemmed = word[0, word.length - cut]
      stemmed.length >= 3 ? stemmed : word
    end

    def literal?(node)
      node.is_a?(Prism::StringNode) || node.is_a?(Prism::SymbolNode)
    end

    def root_of(node)
      node = node.receiver while node.is_a?(Prism::CallNode) && node.receiver
      node
    end

    def load_receiver(node)
      root = root_of(node)
      case root
      when Prism::SelfNode, Prism::LocalVariableReadNode, Prism::CallNode, Prism::StringNode, Prism::SymbolNode,
           Prism::IntegerNode, Prism::FloatNode, Prism::ArrayNode, Prism::HashNode, Prism::RegularExpressionNode
        :inert
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        SourceIndex.constant(root)&.split("::")&.first
      end
    end

    def reflective?(node)
      args = node.arguments&.arguments || []
      first = args.first
      case node.name
      when *STRING_REFLECTION then !literal?(node.receiver)
      when *NAME_REFLECTION then !literal?(first)
      when *REFLECTION then true
      when *METHOD_OBJECTS, *SENDS
        if literal?(first)
          (STRING_REFLECTION + NAME_REFLECTION + REFLECTION).include?(first.unescaped.to_sym)
        elsif first
          METHOD_OBJECTS.include?(node.name) || args.size > 1 || node.block.is_a?(Prism::BlockArgumentNode)
        else
          false
        end
      else
        false
      end
    end

    def walk(node, path, facts, owner, deferred)
      return unless node

      case node
      when Prism::ClassNode, Prism::ModuleNode
        name = SourceIndex.constant(node.constant_path)
        if name
          owner = node.constant_path.location.slice.start_with?("::") ? name : [owner, name].compact.join("::")
          superclass = SourceIndex.constant(node.superclass) if node.is_a?(Prism::ClassNode)
          facts.classes << [owner, superclass]
          facts.abstract << owner if abstract?(node.body)
        else
          facts.load_receivers << nil unless deferred
        end
        walk(node.superclass, path, facts, owner, deferred) if node.is_a?(Prism::ClassNode)
        walk(node.body, path, facts, owner, deferred)
        return
      when Prism::DefNode, Prism::LambdaNode
        node.compact_child_nodes.each { |child| walk(child, path, facts, owner, true) }
        return
      when Prism::StringNode, Prism::SymbolNode
        facts.blob << node.unescaped.to_s.b << "\0"
      when Prism::GlobalVariableWriteNode, Prism::GlobalVariableOrWriteNode, Prism::GlobalVariableAndWriteNode,
           Prism::GlobalVariableOperatorWriteNode, Prism::GlobalVariableTargetNode
        facts.global_write = true
      when Prism::CallNode
        @reflective << path if reflective?(node) && !@reflective.include?(path)
        if !deferred && node.receiver
          root = load_receiver(node.receiver)
          facts.load_receivers << root unless root == :inert
        end
        walk(node.receiver, path, facts, owner, deferred)
        walk(node.arguments, path, facts, owner, deferred)
        block_deferred = deferred || (!node.receiver && !EAGER_BLOCKS.include?(node.name))
        walk(node.block, path, facts, owner, block_deferred)
        return
      end
      node.compact_child_nodes.each { |child| walk(child, path, facts, owner, deferred) }
    end

    def abstract?(body)
      return false unless body.is_a?(Prism::StatementsNode)
      body.body.any? do |n|
        n.is_a?(Prism::CallNode) && n.name == :abstract_class= && n.receiver.is_a?(Prism::SelfNode) &&
          n.arguments&.arguments&.first.is_a?(Prism::TrueNode)
      end
    end
  end
end
