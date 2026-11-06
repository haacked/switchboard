import Foundation
import Testing

@testable import SwitchboardCore

private let hourMs: Int64 = 3_600_000
private let now: Int64 = 100 * hourMs

private func turn(_ reply: String, start: Int64 = 0) -> [Event] {
  [
    event("UserPromptSubmit", start, ["prompt": "go"]),
    event("Stop", start + 1, ["last_assistant_message": .string(reply)]),
  ]
}

private func shown(_ f: SessionFacts, _ s: Session = session(), held: Bool = true) -> Verdict {
  Attention.shown(Attention.evaluate(s, f, now: now), f, held: held)
}

/// The suites nest under one name, so `--filter HeldTests` runs them all.
@Suite struct HeldTests {}

extension HeldTests {
  /// A session with a first prompt queued behind the limit is Needs you
  /// ("give it a first prompt") underneath, which is the case most likely
  /// to leak into the Inbox.
  @Suite struct Overlay {
    @Test func aNewSessionWithAQueuedPromptShowsInWaiting() {
      let f = SessionFacts()
      #expect(Attention.evaluate(session(), f, now: now).state == .needsYou)
      let v = shown(f)
      #expect(v.state == .waiting)
      #expect(v.held)
      #expect(Triage.item(f, v) == nil)
    }

    @Test func aQuestionThatTheUserRepliedToShowsInWaiting() {
      let f = facts(turn("Which schema should I use, A or B?"))
      #expect(Attention.evaluate(session(), f, now: 2).state == .needsYou)
      let v = Attention.shown(Attention.evaluate(session(), f, now: 2), f, held: true)
      #expect(v.state == .waiting)
      #expect(Triage.item(f, v) == nil)
    }

    @Test func anOfferThatTheUserRepliedToShowsInWaiting() {
      let f = facts(turn("I wrote the parser. Want me to run the tests?"))
      let v = Attention.shown(Attention.evaluate(session(), f, now: 2), f, held: true)
      #expect(v.state == .waiting)
      #expect(v.held)
      #expect(Triage.item(f, v) == nil)
    }

    @Test func aDoneSessionShowsInWaiting() {
      let v = shown(SessionFacts(), session(done: true))
      #expect(v.state == .waiting)
      #expect(v.held)
    }

    @Test func aSessionNotHeldKeepsItsState() {
      let v = shown(SessionFacts(), held: false)
      #expect(v.state == .needsYou)
      #expect(!v.held)
    }

    @Test func aRunningTurnStaysWorking() {
      let f = facts([event("UserPromptSubmit", now - 1000, ["prompt": "go"])])
      let v = shown(f)
      #expect(v.state == .working)
      #expect(!v.held)
    }

    enum OpenPrompt: CaseIterable, Sendable { case card, deferredCard, permission, question }

    /// A held start must not hide a decision that the user still has to make.
    @Test(arguments: OpenPrompt.allCases)
    func anOpenCardPermissionPromptOrQuestionKeepsItsState(_ open: OpenPrompt) {
      var f = facts(turn("Done.", start: now - 2 * hourMs))
      switch open {
      case .card, .deferredCard:
        var card = Card(event("PermissionRequest", now - hourMs, tool("Bash", ["command": "ls"])))
        card.deferred = open == .deferredCard
        f.cards = [card]
      case .permission:
        f.openPermission = ToolCall(tool: "Bash", summary: "ls", since: now - hourMs)
      case .question:
        f.openQuestion = ToolCall(tool: "AskUserQuestion", summary: "A or B", since: now - hourMs)
      }
      let v = shown(f)
      #expect(v.state == .needsYou)
      #expect(!v.held)
    }

    @Test func aHeldSessionThatWasAcknowledgedSetsBothFlags() {
      var f = facts(turn("Which schema should I use, A or B?"))
      let verdict = Attention.evaluate(session(), f, now: 2)
      f.acknowledgment = Acknowledgment(verdict, f)
      let v = Attention.shown(verdict, f, held: true)
      #expect(v.state == .waiting)
      #expect(v.held)
      #expect(v.acknowledged)
    }
  }
}

extension HeldTests {
  @Suite struct Coding {
    @Test func aSummaryOmitsHeldWhenItIsNotSet() throws {
      let s = SessionSummary(
        id: "s1", name: "s1", cwd: "/tmp", repo: nil, branch: nil, claudeSessionId: "c1", state: .waiting, reason: "",
        since: 0, lastActivity: 0, live: false, claudePid: nil, attached: false, lastReply: nil, waits: [], notes: [])
      let json = try JSON(encoding: s)
      #expect(json["held"] == nil)
      #expect(json["heldSince"] == nil)
      #expect(json["heldPosition"] == nil)
    }
  }
}
