# frozen_string_literal: true

module Plumb
  # Mix-in that turns a module into a namespace of named Plumb types: every
  # {Composable} assigned to one of its constants is named after that constant,
  # so it inspects under the module's path rather than as an anonymous type.
  #
  # There are two ways to attach it, and they cover different lifecycles:
  #
  # ## `extend TypeRegistry` — name a module's own constants
  #
  # Extend a module to make it a type registry. From that point, {#const_added}
  # fires for each constant assigned on it and names the type in place. Nested
  # modules are extended automatically, so naming continues down the tree.
  #
  # @example Defining your own registry
  #   module MyTypes
  #     extend Plumb::TypeRegistry
  #
  #     # `String | Integer` builds an anonymous Or; assigning it names it.
  #     Name  = Plumb::Types::String.present
  #     Score = Plumb::Types::Integer[0..100]
  #   end
  #
  #   MyTypes::Name.inspect  # => "MyTypes::Name"
  #   MyTypes::Score.inspect # => "MyTypes::Score"
  #
  # ## `include <a registry>` — re-home its types into your namespace
  #
  # Including a module that is already a registry triggers {#included}, which
  # extends the host (so its future constants are named too) and copies the
  # source's predefined types into the host under the host's own namespace.
  # Composable types are `dup`ed so the shared originals are left untouched;
  # nested namespace modules are rebuilt recursively.
  #
  # @example Inheriting an existing registry's types
  #   module MyTypes
  #     include Plumb::Types   # Plumb::Types is itself a registry (see below)
  #
  #     # `String`/`Integer` now resolve to MyTypes' own copies.
  #     Foo = String | Integer
  #   end
  #
  #   MyTypes::String.inspect # => "MyTypes::String" (a copy, host-namespaced)
  #   MyTypes::Foo.inspect    # => "MyTypes::Foo"
  #
  # {Plumb::Types} is the canonical registry: it does `extend TypeRegistry` so
  # all its built-in types (`String`, `Integer`, `Lax::*`, …) are named, and
  # so `include Plumb::Types` re-homes them into your own module.
  #
  # @note {#const_added} names the assigned instance *in place*. Assigning a
  #   type that composes/derives another (e.g. `Types::Integer[18..]`,
  #   `Types::String.present`) builds a fresh instance, so only the new
  #   constant is named. Aliasing an existing type directly
  #   (`Age = Types::Integer`) assigns the same shared instance and renames
  #   the original — assign a derived copy if you want an independent name.
  module TypeRegistry
    # `Module#const_added` hook (Ruby >= 3.2). Fires whenever a constant is
    # assigned on a host extended with this module. Names the assigned type
    # instance after the constant, and extends nested modules so the naming
    # continues down the tree.
    #
    # @param const_name [Symbol] the name of the just-assigned constant
    # @return [void]
    def const_added(const_name)
      obj = const_get(const_name)
      case obj
      when Module
        obj.extend TypeRegistry
      when Composable
        anc = [name, const_name].join('::')
        obj.freeze.name.set(anc)
      end
    end

    # `Module#included` hook. Fires when a module carrying this registry (e.g.
    # {Plumb::Types}) is included into a host. Copies every predefined type
    # from the source into the host under the host's namespace, and extends the
    # host so that constants assigned afterwards are named via {#const_added}.
    #
    # Composable types are `dup`ed before renaming so the shared originals are
    # left untouched; nested namespace modules are rebuilt so their own
    # constants are recursively re-homed under the host.
    #
    # @param host [Module] the module or class including the source
    # @return [void]
    def included(host)
      host.extend TypeRegistry
      constants(false).each do |const_name|
        const = const_get(const_name)

        anc = [host.name, const_name].join('::')
        case const
        when Module
          next if const.is_a?(Class)

          child_mod = Module.new
          child_mod.define_singleton_method(:name) do
            anc
          end
          child_mod.send(:include, const)
          host.const_set(const_name, child_mod)
        when Composable
          type = const.dup
          type.freeze.name.set(anc)
          host.const_set(const_name, type)
        end
      end
    end
  end
end
