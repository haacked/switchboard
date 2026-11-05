import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@MainActor
@Suite struct ReviewCardTests {
  @Test func requestReviewSendsThePickedReviewersWithTheItemsRef() async {
    _ = NSApplication.shared
    let model = BoardModel()

    let sent = await withCheckedContinuation { (sent: CheckedContinuation<(String, [String: JSON]), Never>) in
      model.send = { op, args in
        sent.resume(returning: (op, args))
        return .null
      }
      model.choose("s1", ref: "rule:x", option: 1, action: .requestReview, reviewers: ["ann", "@copilot"])
    }

    #expect(sent.0 == "choose")
    #expect(sent.1 == ["session": "s1", "option": "1", "ref": "rule:x", "reviewers": ["ann", "@copilot"]])
  }

  @Test func reviewSuggestionsAsksSbdAndReadsTheSuggestions() async throws {
    let model = BoardModel()
    let asked = Box<(String, [String: JSON])>()
    model.send = { op, args in
      asked.set((op, args))
      return [
        "session": "s1",
        "suggestions": [["login": "ann", "reason": "committed to the changed files"], ["login": "@copilot", "reason": "x"]],
      ]
    }

    let got = try await model.reviewSuggestions("s1")

    #expect(got.map(\.login) == ["ann", "@copilot"])
    #expect(asked.value?.0 == "review")
    #expect(asked.value?.1 == ["session": "s1"])
  }

  @Test func reviewSuggestionsPassesSbdsErrorOn() async {
    let model = BoardModel()
    model.send = { _, _ in throw APIError("gh: not logged in") }

    await #expect(throws: (any Error).self) { try await model.reviewSuggestions("s1") }
  }

  @Test func pickedReviewersKeepTheSuggestionsOrder() {
    let suggestions = ["ann", "bob", "@copilot"].map { ReviewerSuggestion(login: $0, reason: "") }

    #expect(ReviewerPicker.chosen(suggestions, ["@copilot", "ann"]) == ["ann", "@copilot"])
  }
}

/// A value that a request on another thread sets.
private final class Box<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: T?
  var value: T? { lock.withLock { stored } }
  func set(_ v: T) { lock.withLock { stored = v } }
}
