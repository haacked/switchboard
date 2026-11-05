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
      model.choose("s1", ref: "rule:x", option: 1, action: .requestReview, text: "ann,@copilot")
    }

    #expect(sent.0 == "choose")
    #expect(sent.1 == ["session": "s1", "option": "1", "ref": "rule:x", "text": "ann,@copilot"])
  }

  @Test func reviewSuggestionsAsksSbdAndReadsTheSuggestions() async throws {
    let model = BoardModel()
    let asked = MessageAttachmentTests.Sent()
    model.send = { op, args in
      asked.add(op, args)
      return [
        "session": "s1",
        "suggestions": [
          ["login": "ann", "reason": "committed to the changed files"], ["login": "@copilot", "reason": "x"],
        ],
      ]
    }

    let got = try await model.reviewSuggestions("s1")

    #expect(got.map(\.login) == ["ann", "@copilot"])
    #expect(asked.all.map(\.op) == ["review"])
    #expect(asked.all.first?.args == ["session": "s1"])
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
