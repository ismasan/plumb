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
      accepted_type: ObjectSpace::WeakKeyMap.new,
      value_preserving: ObjectSpace::WeakKeyMap.new
    }.freeze

    LOCK = Mutex.new

    # Sentinel distinguishing "no entry" from a cached `false`/`nil` — WeakKeyMap#[]
    # returns nil for both, so a truthiness check would never cache a falsy value
    # (e.g. #value_preserving? is a boolean, false for every transform/container).
    ABSENT = Object.new.freeze
    private_constant :ABSENT

    # Presence-based so cached `false`/`nil` are returned as hits, not recomputed.
    #
    # NOTE: compute OUTSIDE the lock — computations recurse back into #fetch
    # (And/Or children, resolved_* chains) and a non-reentrant Mutex would
    # deadlock. A race may compute the same pure value twice; the first write wins.
    def self.fetch(slot, key)
      return yield unless key.frozen?

      map = MAPS.fetch(slot)
      cached = LOCK.synchronize { map.key?(key) ? map[key] : ABSENT }
      return cached unless cached.equal?(ABSENT)

      value = yield
      LOCK.synchronize { map.key?(key) ? map[key] : (map[key] = value) }
    end
  end
end
