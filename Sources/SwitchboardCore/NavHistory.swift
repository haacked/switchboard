import Foundation

public enum NavDirection: Sendable {
  case back, forward
}

/// The places the user went, in order, with a cursor at the place that shows now. Back and Forward move the
/// cursor as a browser does, and a new place drops every entry after the cursor.
///
/// Every query takes `resolve`, which returns nil for a place the user can't go to now, such as a removed
/// session, and otherwise the place as it would show now. An entry stays when it resolves to nil, so a place
/// that comes back is reachable again.
public struct NavHistory<Location: Hashable>: Equatable {
  public private(set) var entries: [Location]
  public private(set) var cursor: Int
  public let limit: Int

  public init(start: Location, limit: Int = 50) {
    precondition(limit >= 2)
    entries = [start]
    cursor = 0
    self.limit = limit
  }

  public var current: Location { entries[cursor] }

  /// Records a navigation to `new`. A place that resolves to the current one replaces it instead, so a
  /// repeat adds no entry. Two different places that both resolve to nil are not repeats.
  public mutating func push(_ new: Location, resolve: (Location) -> Location?) {
    if new == current || resolve(new).map({ $0 == resolve(current) }) == true {
      entries[cursor] = new
      return
    }
    entries.removeSubrange((cursor + 1)...)
    entries.append(new)
    let excess = entries.count - limit
    if excess > 0 { entries.removeFirst(excess) }
    cursor = entries.count - 1
  }

  /// Sets the current entry to `new` without a navigation, and merges it with an equal neighbor. Forward
  /// entries stay.
  public mutating func replace(_ new: Location) {
    entries[cursor] = new
    while cursor > 0 && entries[cursor - 1] == entries[cursor] {
      entries.remove(at: cursor)
      cursor -= 1
    }
    while cursor + 1 < entries.count && entries[cursor + 1] == entries[cursor] {
      entries.remove(at: cursor + 1)
    }
  }

  /// The index of the nearest entry in `direction` that the user can go to and that differs from the
  /// current place, or nil when there is none.
  public func target(_ direction: NavDirection, resolve: (Location) -> Location?) -> Int? {
    let here = resolve(current)
    let step = direction == .back ? -1 : 1
    var i = cursor + step
    while entries.indices.contains(i) {
      if let place = resolve(entries[i]), place != here { return i }
      i += step
    }
    return nil
  }

  public func canGo(_ direction: NavDirection, resolve: (Location) -> Location?) -> Bool {
    target(direction, resolve: resolve) != nil
  }

  public mutating func move(to index: Int) {
    precondition(entries.indices.contains(index))
    cursor = index
  }

  /// The places of the other entries as they resolve now, newest entry first, at most `limit`. Each place
  /// shows once, and the current place and places the user can't go to are left out.
  public func recent(limit: Int = 10, resolve: (Location) -> Location?) -> [Location] {
    let here = resolve(current)
    var seen: Set<Location> = []
    var places: [Location] = []
    for i in entries.indices.reversed() where i != cursor && places.count < limit {
      guard let place = resolve(entries[i]), place != here, seen.insert(place).inserted else { continue }
      places.append(place)
    }
    return places
  }
}

extension NavHistory: Sendable where Location: Sendable {}
