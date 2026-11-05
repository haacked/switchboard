import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@MainActor
@Suite struct BoardModelDescription {
  func model(description: String? = nil) -> BoardModel {
    _ = NSApplication.shared
    let model = BoardModel()
    model.groups = [
      GroupSummary(SessionGroup(id: "g1", name: "Flags", description: description, created: 0), sessions: [])
    ]
    return model
  }

  /// The request that `describeGroup` sent, and the description the Board
  /// showed right after the call. A refresh after sbd answers can replace
  /// the groups, so the test reads the description before it awaits.
  func sent(_ model: BoardModel, _ text: String) async -> (String, [String: JSON], String?) {
    var shown: String?
    let (op, args) = await withCheckedContinuation { (sent: CheckedContinuation<(String, [String: JSON]), Never>) in
      model.send = { op, args in
        sent.resume(returning: (op, args))
        return .null
      }
      model.describeGroup("g1", text)
      shown = model.groups.first { $0.id == "g1" }?.description
    }
    return (op, args, shown)
  }

  @Test func savesTheTrimmedTextAndShowsItBeforeSbdAnswers() async {
    let model = model()

    let (op, args, shown) = await sent(model, "  Flag  evaluation \n")

    #expect(op == "group-describe")
    #expect(args == ["group": "g1", "text": "Flag evaluation"])
    #expect(shown == "Flag evaluation")
  }

  @Test func blankTextClearsTheDescription() async {
    let model = model(description: "Flag evaluation")

    let (op, args, shown) = await sent(model, "   ")

    #expect(op == "group-describe")
    #expect(args == ["group": "g1", "clear": true])
    #expect(shown == nil)
  }

  @Test func unchangedOrTooLongTextSendsNothing() {
    let model = model(description: "Flag evaluation")
    let sent = Counter()
    model.send = { _, _ in
      sent.increment()
      return .null
    }

    model.describeGroup("g1", "Flag evaluation")
    model.describeGroup("g1", String(repeating: "a", count: SessionGroup.descriptionLimit + 1))

    #expect(sent.value == 0)
    #expect(model.groups[0].description == "Flag evaluation")
    #expect(model.actionError?.contains("280") == true)
  }
}
