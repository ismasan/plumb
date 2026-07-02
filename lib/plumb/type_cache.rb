# frozen_string_literal: true

module Plumb
  # Process-level memoization for computed type graphs (resolved input/output
  # and accepted types — see Plumb::Subtyping). Keyed by type identity in
  # WeakKeyMaps, so entries are pruned by GC together with their types. Only
  # frozen types are cached: a mutable type (an unfrozen Pipeline, a Deferred)
  # may change its answer over time, so it always recomputes.
  module TypeCache
    MAPS = {
      resolved_input: ObjectSpace::WeakKeyMap.new,
      resolved_output: ObjectSpace::WeakKeyMap.new,
      accepted_type: ObjectSpace::WeakKeyMap.new
    }.freeze

    LOCK = Mutex.new

    # NOTE: compute OUTSIDE the lock — computations recurse back into #fetch
    # (Or children, resolved_* chains) and a non-reentrant Mutex would deadlock.
    # A race may compute the same pure value twice; the first write wins.
    def self.fetch(slot, key)
      return yield unless key.frozen?

      map = MAPS.fetch(slot)
      cached = LOCK.synchronize { map[key] }
      return cached if cached

      value = yield
      LOCK.synchronize { map[key] || (map[key] = value) }
    end
  end
end
