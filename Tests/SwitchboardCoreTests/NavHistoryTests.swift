import Testing

@testable import SwitchboardCore

private let everything: (String) -> String? = { $0 }

private func without(_ removed: Set<String>) -> (String) -> String? {
  { removed.contains($0) ? nil : $0 }
}

/// Maps every place that starts with "a" to "a", as `BoardModel` maps an Inbox item that left the list to the
/// first item.
private let aIsOnePlace: (String) -> String? = { $0.hasPrefix("a") ? "a" : $0 }

/// A history that starts at the first place and pushes the rest with every place available.
private func history(_ places: [String], limit: Int = 50) -> NavHistory<String> {
  var h = NavHistory(start: places[0], limit: limit)
  for place in places.dropFirst() { h.push(place, resolve: everything) }
  return h
}

/// Moves to the target in `direction` and replaces it with its resolved place, as `BoardModel.goBack()` does.
/// Returns false when there is no target.
@discardableResult
private func step(
  _ h: inout NavHistory<String>, _ direction: NavDirection, resolve: (String) -> String? = everything
) -> Bool {
  guard let i = h.target(direction, resolve: resolve) else { return false }
  h.move(to: i)
  h.replace(resolve(h.entries[i])!)
  return true
}

@Suite struct NavHistoryTests {
  // MARK: Start

  @Test func aNewHistoryHoldsOnlyTheStartAtCursorZero() {
    let h = NavHistory(start: "inbox")

    #expect(h.entries == ["inbox"])
    #expect(h.cursor == 0)
    #expect(h.current == "inbox")
  }

  @Test func theLimitDefaultsToFifty() {
    #expect(NavHistory(start: "inbox").limit == 50)
  }

  @Test func aNewHistoryCannotGoBackOrForward() {
    let h = NavHistory(start: "inbox")

    #expect(!h.canGo(.back, resolve: everything))
    #expect(!h.canGo(.forward, resolve: everything))
  }

  @Test func aNewHistoryHasNoRecentPlaces() {
    #expect(NavHistory(start: "inbox").recent(resolve: everything).isEmpty)
  }

  // MARK: push

  @Test func pushAppendsThePlaceAndMovesTheCursorToIt() {
    var h = NavHistory(start: "a")

    h.push("b", resolve: everything)

    #expect(h.entries == ["a", "b"])
    #expect(h.cursor == 1)
  }

  @Test func pushOfTheCurrentPlaceLeavesTheHistoryUnchanged() {
    var h = history(["a", "b"])
    let before = h

    h.push("b", resolve: everything)

    #expect(h == before)
  }

  @Test func pushOfAPlaceThatResolvesToTheCurrentOneReplacesTheCurrentEntry() {
    var h = history(["b", "a1"])

    h.push("a2", resolve: aIsOnePlace)

    #expect(h.entries == ["b", "a2"])
    #expect(h.cursor == 1)
    #expect(h.current == "a2")
  }

  /// An unlisted session pushed after a removed one is a new navigation, though neither resolves.
  @Test func pushOfAnUnavailablePlaceAfterAnotherUnavailablePlaceRecordsIt() {
    var h = history(["a", "gone"])

    h.push("unlisted", resolve: without(["gone", "unlisted"]))

    #expect(h.entries == ["a", "gone", "unlisted"])
    #expect(h.cursor == 2)
  }

  /// A binding that writes an unavailable selection back must not add an entry for each write.
  @Test func pushOfTheSameUnavailablePlaceAgainLeavesTheHistoryUnchanged() {
    var h = history(["a", "gone"])
    let before = h

    h.push("gone", resolve: without(["gone"]))

    #expect(h == before)
  }

  @Test func pushOfAnAvailablePlaceOntoAnUnavailableCurrentRecordsIt() {
    var h = history(["a", "gone"])

    h.push("b", resolve: without(["gone"]))

    #expect(h.entries == ["a", "gone", "b"])
  }

  // MARK: Back and Forward

  @Test func backThenForwardReturnsToTheSamePlace() {
    var h = history(["a", "b", "c"])

    step(&h, .back)
    step(&h, .forward)

    #expect(h.current == "c")
    #expect(h.entries == ["a", "b", "c"])
  }

  @Test func backMovesTheCursorToThePreviousEntry() {
    var h = history(["a", "b", "c"])

    step(&h, .back)

    #expect(h.cursor == 1)
    #expect(h.current == "b")
  }

  @Test func pushAfterBackingUpTwiceDropsBothForwardEntries() {
    var h = history(["a", "b", "c"])
    step(&h, .back)
    step(&h, .back)

    h.push("d", resolve: everything)

    #expect(h.entries == ["a", "d"])
    #expect(h.cursor == 1)
    #expect(!h.canGo(.forward, resolve: everything))
  }

  @Test func pushAfterBackingUpToIndexZeroLeavesTwoEntries() {
    var h = history(["a", "b"])
    step(&h, .back)

    h.push("c", resolve: everything)

    #expect(h.entries == ["a", "c"])
    #expect(h.cursor == 1)
  }

  @Test func theCursorAtZeroHasNoBackTarget() {
    var h = history(["a", "b"])
    h.move(to: 0)

    #expect(h.target(.back, resolve: everything) == nil)
    #expect(h.target(.forward, resolve: everything) == 1)
  }

  @Test func theCursorAtTheEndHasNoForwardTarget() {
    let h = history(["a", "b"])

    #expect(h.target(.forward, resolve: everything) == nil)
    #expect(h.target(.back, resolve: everything) == 0)
  }

  // MARK: Cap

  @Test func pushingPastTheLimitKeepsTheNewestEntries() {
    let h = history((0..<8).map { "p\($0)" }, limit: 5)

    #expect(h.entries == ["p3", "p4", "p5", "p6", "p7"])
    #expect(h.cursor == 4)
  }

  @Test func theSmallestLimitKeepsTwoEntries() {
    let h = history(["a", "b", "c"], limit: 2)

    #expect(h.entries == ["b", "c"])
    #expect(h.cursor == 1)
  }

  @Test func pushAfterBackingUpInACappedHistoryDropsTheForwardEntries() {
    var h = history((0..<8).map { "p\($0)" }, limit: 5)
    step(&h, .back)
    step(&h, .back)

    h.push("x", resolve: everything)

    #expect(h.entries == ["p3", "p4", "p5", "x"])
    #expect(h.cursor == 3)
  }

  @Test func backFromTheOldestKeptEntryIsOff() {
    var h = history((0..<8).map { "p\($0)" }, limit: 5)
    while step(&h, .back) {}

    #expect(h.current == "p3")
    #expect(h.cursor == 0)
    #expect(!h.canGo(.back, resolve: everything))
  }

  // MARK: replace

  @Test func replaceKeepsTheForwardEntries() {
    var h = history(["a", "b", "c"])
    h.move(to: 1)

    h.replace("x")

    #expect(h.entries == ["a", "x", "c"])
    #expect(h.cursor == 1)
  }

  @Test func replaceWithThePreviousEntryMergesThemAndLowersTheCursor() {
    var h = history(["a", "b", "c"])
    h.move(to: 1)

    h.replace("a")

    #expect(h.entries == ["a", "c"])
    #expect(h.cursor == 0)
  }

  @Test func replaceWithTheNextEntryMergesThem() {
    var h = history(["a", "b", "c"])
    h.move(to: 1)

    h.replace("c")

    #expect(h.entries == ["a", "c"])
    #expect(h.cursor == 1)
  }

  @Test func replaceOfTheMiddleOfARunCollapsesTheRunToOneEntry() {
    var h = history(["a", "x", "a"])
    h.move(to: 1)

    h.replace("a")

    #expect(h.entries == ["a"])
    #expect(h.cursor == 0)
  }

  @Test func replaceOfTheOnlyEntryChangesIt() {
    var h = NavHistory(start: "a")

    h.replace("b")

    #expect(h.entries == ["b"])
    #expect(h.cursor == 0)
  }

  // MARK: target skips unavailable and repeated places

  @Test func backSkipsARemovedPlace() {
    let h = history(["a", "b", "c"])

    #expect(h.target(.back, resolve: without(["b"])) == 0)
  }

  @Test func forwardSkipsARemovedPlace() {
    var h = history(["a", "b", "c"])
    h.move(to: 0)

    #expect(h.target(.forward, resolve: without(["b"])) == 2)
  }

  @Test func backIsOffWhenEveryEarlierPlaceIsRemoved() {
    let h = history(["a", "b", "c"])

    #expect(h.target(.back, resolve: without(["a", "b"])) == nil)
    #expect(!h.canGo(.back, resolve: without(["a", "b"])))
  }

  @Test func forwardIsOffWhenEveryLaterPlaceIsRemoved() {
    var h = history(["a", "b", "c"])
    h.move(to: 0)

    #expect(h.target(.forward, resolve: without(["b", "c"])) == nil)
  }

  @Test func backSkipsAnEntryThatResolvesToTheCurrentPlace() {
    let h = history(["b", "a1", "a2"])

    #expect(h.target(.back, resolve: aIsOnePlace) == 0)
  }

  @Test func forwardSkipsAnEntryThatResolvesToTheCurrentPlace() {
    var h = history(["a1", "a2", "b"])
    h.move(to: 0)

    #expect(h.target(.forward, resolve: aIsOnePlace) == 2)
  }

  @Test func backFromARepeatAroundARemovedPlaceGoesPastBoth() {
    let h = history(["z", "a", "x", "a"])

    #expect(h.target(.back, resolve: without(["x"])) == 0)
  }

  @Test func backFromARepeatAroundARemovedPlaceIsOffWithNothingBefore() {
    let h = history(["a", "x", "a"])

    #expect(h.target(.back, resolve: without(["x"])) == nil)
  }

  @Test func aPlaceThatIsAvailableAgainIsReachableAgain() {
    let h = history(["a", "b", "c"])

    #expect(h.target(.back, resolve: without(["b"])) == 0)
    #expect(h.target(.back, resolve: everything) == 1)
  }

  @Test func backFromAnUnavailableCurrentPlaceLandsOnTheNearestAvailableOne() {
    let h = history(["a", "b", "gone"])

    #expect(h.target(.back, resolve: without(["gone"])) == 1)
  }

  @Test func targetLeavesTheHistoryUnchanged() {
    let h = history(["a", "b", "c"])
    let before = h

    _ = h.target(.back, resolve: everything)
    _ = h.canGo(.forward, resolve: everything)
    _ = h.recent(resolve: everything)

    #expect(h == before)
  }

  // MARK: The guard's property over every shape

  /// A history and a `resolve`, with the index that `target` must land on in each direction: the nearest
  /// entry that resolves and differs from the resolved current place.
  struct Shape: Sendable, CustomTestStringConvertible {
    var name: String
    var entries: [String]
    var cursor: Int
    var back: Int?
    var forward: Int?
    var removed: Set<String> = []
    var normalizes = false
    var testDescription: String { name }

    func resolve(_ place: String) -> String? {
      if removed.contains(place) { return nil }
      return normalizes && place.hasPrefix("a") ? "a" : place
    }

    func build() -> NavHistory<String> {
      var h = history(entries)
      h.move(to: cursor)
      return h
    }
  }

  static let shapes = [
    Shape(name: "a single entry", entries: ["a"], cursor: 0, back: nil, forward: nil),
    Shape(name: "cursor at zero", entries: ["a", "b", "c"], cursor: 0, back: nil, forward: 1),
    Shape(name: "cursor at the end", entries: ["a", "b", "c"], cursor: 2, back: 1, forward: nil),
    Shape(name: "cursor in the middle", entries: ["a", "b", "c"], cursor: 1, back: 0, forward: 2),
    Shape(name: "removed behind", entries: ["a", "b", "c"], cursor: 2, back: 0, forward: nil, removed: ["b"]),
    Shape(name: "removed ahead", entries: ["a", "b", "c"], cursor: 0, back: nil, forward: 2, removed: ["b"]),
    Shape(
      name: "every entry behind removed", entries: ["a", "b", "c"], cursor: 2, back: nil, forward: nil,
      removed: ["a", "b"]),
    Shape(
      name: "every entry ahead removed", entries: ["a", "b", "c"], cursor: 0, back: nil, forward: nil,
      removed: ["b", "c"]),
    Shape(
      name: "equal to current behind", entries: ["b", "a1", "a2"], cursor: 2, back: 0, forward: nil, normalizes: true),
    Shape(
      name: "equal to current ahead", entries: ["a1", "a2", "b"], cursor: 0, back: nil, forward: 2, normalizes: true),
    Shape(
      name: "A X A with X removed and nothing before", entries: ["a", "x", "a"], cursor: 2, back: nil, forward: nil,
      removed: ["x"]),
    Shape(
      name: "A X A with X removed after Z", entries: ["z", "a", "x", "a"], cursor: 3, back: 0, forward: nil,
      removed: ["x"]),
    Shape(
      name: "A X A with X removed, from the first A", entries: ["a", "x", "a"], cursor: 0, back: nil, forward: nil,
      removed: ["x"]),
    Shape(name: "current removed", entries: ["a", "b", "gone"], cursor: 2, back: 1, forward: nil, removed: ["gone"]),
    Shape(
      name: "everything removed", entries: ["a", "b", "c"], cursor: 1, back: nil, forward: nil,
      removed: ["a", "b", "c"]),
  ]

  @Test(arguments: shapes)
  func backLandsOnTheNearestAvailablePlaceThatDiffersFromTheCurrentOne(_ shape: Shape) {
    #expect(shape.build().target(.back, resolve: shape.resolve) == shape.back)
  }

  @Test(arguments: shapes)
  func forwardLandsOnTheNearestAvailablePlaceThatDiffersFromTheCurrentOne(_ shape: Shape) {
    #expect(shape.build().target(.forward, resolve: shape.resolve) == shape.forward)
  }

  // MARK: recent

  @Test func recentListsTheNewestEntryFirst() {
    let h = history(["a", "b", "c", "d"])

    #expect(h.recent(resolve: everything) == ["c", "b", "a"])
  }

  @Test func recentIncludesForwardEntriesFirst() {
    var h = history(["a", "b", "c", "d"])
    h.move(to: 1)

    #expect(h.recent(resolve: everything) == ["d", "c", "a"])
  }

  @Test func recentListsEachPlaceOnceAtItsNewestEntry() {
    let h = history(["a", "b", "a", "c", "b", "d"])

    #expect(h.recent(resolve: everything) == ["b", "c", "a"])
  }

  @Test func recentListsResolvedPlacesOnce() {
    let h = history(["a1", "b", "a2", "c"])

    #expect(h.recent(resolve: aIsOnePlace) == ["a", "b"])
  }

  @Test func recentLeavesOutTheCurrentPlace() {
    let h = history(["a", "b", "a"])

    #expect(h.recent(resolve: everything) == ["b"])
  }

  @Test func recentLeavesOutAnEntryThatResolvesToTheCurrentPlace() {
    let h = history(["a1", "b", "a2"])

    #expect(h.recent(resolve: aIsOnePlace) == ["b"])
  }

  @Test func recentLeavesOutRemovedPlaces() {
    let h = history(["a", "b", "c", "d"])

    #expect(h.recent(resolve: without(["b"])) == ["c", "a"])
  }

  @Test func recentStopsAtTheLimit() {
    let h = history((0..<8).map { "p\($0)" })

    #expect(h.recent(limit: 3, resolve: everything) == ["p6", "p5", "p4"])
  }

  @Test func recentCountsTheLimitAfterRemovingRepeats() {
    let h = history(["a", "b", "c", "b", "c", "d"])

    #expect(h.recent(limit: 3, resolve: everything) == ["c", "b", "a"])
  }
}
