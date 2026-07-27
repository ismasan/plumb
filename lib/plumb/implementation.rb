# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  # Turn a custom Ruby class into a first-class Plumb type.
  #
  # {Plumb::Function} wraps a callable you hand it; an Implementation goes the
  # other way round — YOUR class owns its constructor and state, and the mixin
  # gives it the typed-node interface (`#input_type`, `#output_type`,
  # composition, subtyping, visitors). The declared pair is given as a one-pair
  # Hash literal, exactly like {Plumb::Encoder}.
  #
  # The mixin owns the public `#call(Result) => Result`; you implement a private
  # `#_call(Result) => Result`. `#call` runs the declared checks around it:
  #
  #   result.map(input_type).map(_call).map(output_type)
  #
  # ie. the input is validated (and coerced, if the input type converts) before
  # `#_call` sees it, and what it returns is validated against the output type.
  #
  # INCLUDE it to make INSTANCES typed steps — the case for a parameterized
  # step, where the constructor arguments are part of what the step does:
  #
  #   class UserFinder
  #     include Plumb::Implementation[Types::UUID::V4 => User]
  #
  #     def initialize(scope) = @scope = scope
  #
  #     private def _call(result)
  #       user = User.where(level: @scope).find_by(id: result.value)
  #       return result.invalid(errors: 'no user!') unless user
  #
  #       result.valid(user)
  #     end
  #   end
  #
  #   finder = UserFinder.new('admin')
  #   finder.parse(some_uuid)      # => a User (raises unless the input is a UUID)
  #   finder >> some_other_step    # composition, type-checked at build time
  #   Types::UUID::V4 >> finder    # ...on both sides
  #   finder <= User               # true: identified by what it produces
  #   finder.to_json_schema        # describes the INPUT side, like any function
  #
  # EXTEND it to make THE CLASS ITSELF the step — no instantiation, the class
  # implements `self._call(result)` and answers `.input_type` / `.output_type`:
  #
  #   class ParseUUID
  #     extend Plumb::Implementation[Types::String => Types::UUID::V4]
  #
  #     def self._call(result) = result.valid(result.value.downcase)
  #   end
  #
  #   ParseUUID.parse(str)         # the class is the step
  #   ParseUUID >> UserFinder.new('admin')
  #   Types::Hash[id: ParseUUID]
  #
  # This mirrors `include Plumb::Composable` / `extend Plumb::Composable`, and
  # like those the two forms are alternatives — pick one per class. The extended
  # form deliberately does NOT get {Plumb::Naming}/{Plumb::Equality} (see
  # Composable.included): a class must keep Ruby's own `#name`, `#inspect`,
  # `#==` and `#<=` (module ancestry). Ask for the subtype relation explicitly
  # instead: `Plumb::Subtyping.subtype?(ParseUUID, Types::String)`.
  #
  # Either way the step reports `node_name` `:function`, so every visitor, JSON
  # Schema handler and base-type resolution that already understands a
  # conversion node understands it too. Define your own `#node_name` (or
  # `self.node_name`) after the mixin if you have visitors of your own.
  #
  # Declaring no pair (`include`/`extend Plumb::Implementation`) is the OPAQUE
  # case: both ends are `Types::Any`, like {Plumb::Function.opaque} — the
  # checks can't fail and `#>>` opts out of type-checking.
  module Implementation
    # Build the mixin: `Implementation[Input => Output]`.
    # Both sides are wrapped as Plumb types, so raw Ruby classes/Hashes work
    # (`Implementation[{id: Types::String} => User]`).
    #
    # @param pair [Hash] a one-pair Hash: input type => output type
    # @return [Module] a mixin to include (typed instances) or extend (typed class)
    def self.[](pair)
      unless pair.is_a?(::Hash) && pair.size == 1
        raise ArgumentError,
              'Plumb::Implementation[Input => Output] expects a one-pair Hash ' \
              "(eg. Plumb::Implementation[Types::String => User]), got #{pair.inspect}"
      end

      input, output = pair.first
      build(Composable.wrap(input), Composable.wrap(output))
    end

    # `include`/`extend Plumb::Implementation` with no declared types — the
    # opaque case.
    def self.included(base) = setup_instances(base, Types::Any, Types::Any)
    def self.extended(base) = setup_class(base, Types::Any, Types::Any)

    # @param input [Composable]
    # @param output [Composable]
    # @return [Module]
    def self.build(input, output)
      label = "Plumb::Implementation[#{input.inspect} => #{output.inspect}]"
      mod = Module.new
      mod.define_singleton_method(:included) { |base| Implementation.setup_instances(base, input, output) }
      mod.define_singleton_method(:extended) { |base| Implementation.setup_class(base, input, output) }
      mod.define_singleton_method(:inspect) { label }
      mod.define_singleton_method(:to_s) { label }
      mod
    end
    private_class_method :build

    # The INCLUDE path: instances of `base` become typed steps.
    #
    # Order matters. Composable goes in FIRST so that TypeInterface — included
    # after it, therefore ahead of it in the ancestor chain — wins over the
    # `#input_type = self` / `#output_type = self` defaults every plain type
    # carries, and over Callable#call. #node_name is defined on the class itself
    # because Naming defines it there too (a module could not override it); a
    # `def node_name` in the class body after the include still wins over both.
    #
    # @api private
    def self.setup_instances(base, input, output)
      base.include(Composable)
      base.include(TypeInterface)
      base.include(Inspect)
      base.include(types_module(input, output))
      base.define_method(:node_name) { :function }
    end

    # The EXTEND path: `base` itself becomes a typed step. Same interface, all
    # of it on the singleton — and WITHOUT Naming/Equality, which would
    # otherwise take over the class' own #name/#inspect/#==/#<= (this is why it
    # goes through #extend rather than `singleton_class.include`, mirroring
    # `extend Plumb::Composable`).
    #
    # @api private
    def self.setup_class(base, input, output)
      base.extend(Composable)
      base.extend(TypeInterface)
      base.extend(types_module(input, output))
      base.define_singleton_method(:node_name) { :function }
    end

    # The declared pair, as a module so that a `def input_type` in the host can
    # override it and still reach the declaration with `super`.
    def self.types_module(input, output)
      Module.new do
        define_method(:input_type) { input }
        define_method(:output_type) { output }
      end
    end
    private_class_method :types_module

    # The typed-node interface, shared by both paths. Mirrors
    # {Plumb::Function}: a conversion is identified for subtyping by what it
    # PRODUCES, and accepts what its input type accepts.
    module TypeInterface
      # The step interface, owned by the mixin: the declared checks around the
      # host's #_call. Included AFTER Composable, so this is the #call that runs
      # (Callable#call, the "implement me" stub, sits behind it).
      #
      # @param result [Result]
      # @return [Result]
      def call(result)
        result = result.map(input_type)
        return result if result.invalid?

        out = _call(result)
        unless out.is_a?(Result)
          raise Plumb::TypeError,
                "#{_host_name}#_call(Plumb::Result) must return a Plumb::Result, got #{out.inspect}"
        end

        out.map(output_type)
      end

      # The value-level contract, implemented by the host (privately, by
      # convention — it is the inside of #call, not part of the step interface).
      #
      # @param result [Result] already validated against #input_type
      # @return [Result] validated against #output_type by #call
      def _call(_result)
        raise NotImplementedError,
              "Implement #{is_a?(::Module) ? 'self.' : '#'}_call(Plumb::Result) => Plumb::Result in #{_host_name}"
      end

      # Visitors (and Composable#==) read a node's children.
      def children = [input_type, output_type]

      # @see Composable#subtype_identity
      def subtype_identity = output_type

      # @see Composable#accepted_type, Function#accepted_type
      def accepted_type = Plumb::Subtyping.accepted_type(input_type)

      # The host, for error messages — the class itself when extended, the
      # instance's class when included.
      private def _host_name
        is_a?(::Module) ? (name || inspect) : (self.class.name || self.class.inspect)
      end
    end

    # INCLUDE path only: an instance would otherwise inspect as Ruby's
    # `#<UserFinder:0x…>` (or, through Naming, as an empty string until frozen).
    # An extended CLASS already inspects as itself, and overriding Module#inspect
    # would change how it prints everywhere.
    #
    # Not routed through Naming#name either: a user class may well define its
    # own #name, and its inspect should not depend on that.
    module Inspect
      def inspect = _inspect

      private def _inspect
        "#{self.class.name || 'Implementation'}(#{input_type.inspect} -> #{output_type.inspect})"
      end
    end
  end
end
