import Foundation
import Testing

@testable import SwitchboardCore

private func event(_ kind: String, session: String? = nil, _ data: JSON) -> ActivityEvent {
  ActivityEvent(t: 1, kind: kind, session: session, data: data)
}

@Suite struct ActivityKindsTests {
  // MARK: Accepted

  @Test(arguments: [
    event("app", ["event": "launch"]),
    event("app", ["event": "quit"]),
    event("nav", ["from": "inbox", "to": "session", "via": "list", "state": "needs_you"]),
    event("terminal.ready", session: "sab2cd", ["ms": 1500, "wasLive": true, "left": false, "timedOut": true]),
    event("command", ["name": "nextNeedingYou", "via": "key"]),
    event("window", ["width": 1440, "height": 900, "fullScreen": false]),
    event("error", ["where": "open", "code": "refused"]),
    event("error", ["where": "other", "code": "other"]),
  ])
  func acceptsAnEventWhoseFieldsAllPassTheirRules(_ e: ActivityEvent) {
    #expect(ActivityKinds.accepts(e))
  }

  @Test func acceptsASubsetOfTheListedFields() {
    #expect(ActivityKinds.accepts(event("nav", ["to": "board"])))
  }

  @Test func acceptsAKnownKindWithNoFields() {
    #expect(ActivityKinds.accepts(event("nav", [:])))
  }

  @Test func acceptsAFractionalNumber() {
    #expect(ActivityKinds.accepts(event("terminal.ready", ["ms": 12.5])))
  }

  @Test func acceptsEveryNavState() {
    for state in AttentionState.allCases {
      #expect(ActivityKinds.accepts(event("nav", ["to": "session", "state": .string(state.rawValue)])))
    }
  }

  // MARK: Kinds

  @Test(arguments: ["unknown", "", "resume.ready", "send", "NAV", "nav "])
  func refusesAKindThatIsNotListed(_ kind: String) {
    #expect(!ActivityKinds.accepts(event(kind, [:])))
  }

  @Test(arguments: [JSON.null, .array([]), .string("launch"), .number(1), .bool(true)])
  func refusesDataThatIsNotAnObject(_ data: JSON) {
    #expect(!ActivityKinds.accepts(event("app", data)))
  }

  // MARK: Fields

  @Test(arguments: [
    event("nav", ["to": "session", "query": "secret"]),
    event("nav", ["to": "session", "ms": 10]),
    event("app", ["event": "launch", "text": "hello"]),
    event("error", ["where": "open", "code": "APIError", "message": "no such session"]),
    event("command", ["name": "back", "path": "/Users/me"]),
    event("window", ["width": 800, "event": "launch"]),
  ])
  func refusesAFieldThatIsNotListedForTheKind(_ e: ActivityEvent) {
    #expect(!ActivityKinds.accepts(e))
  }

  @Test(arguments: [
    event("nav", ["to": "settings"]),
    event("nav", ["via": "keyboard"]),
    event("nav", ["state": "busy"]),
    event("app", ["event": "crash"]),
    event("command", ["name": "deleteEverything"]),
    event("command", ["via": "voice"]),
    event("nav", ["to": "Session"]),
    event("nav", ["to": ""]),
  ])
  func refusesAStringOutsideTheOneOfSet(_ e: ActivityEvent) {
    #expect(!ActivityKinds.accepts(e))
  }

  @Test(arguments: [JSON.number(1), .bool(true), .null, .array(["inbox"]), .object(["to": "inbox"])])
  func refusesANonStringForAOneOfField(_ value: JSON) {
    #expect(!ActivityKinds.accepts(event("nav", ["to": value])))
  }

  @Test(arguments: [
    JSON.number(.nan), .number(.infinity), .number(-.infinity), .string("1500"), .bool(true), .null, .array([1]),
  ])
  func refusesANonFiniteOrNonNumberForANumberField(_ value: JSON) {
    #expect(!ActivityKinds.accepts(event("terminal.ready", ["ms": value])))
  }

  @Test(arguments: [JSON.number(1), .number(0), .string("true"), .null])
  func refusesANonBoolForABoolField(_ value: JSON) {
    #expect(!ActivityKinds.accepts(event("terminal.ready", ["wasLive": value])))
  }

  // MARK: Errors

  @Test(arguments: [
    "", "rebase-onto-main-please", "hunter2", "APIError", "open\n", "/Users/me", "secret query",
  ])
  func refusesAnErrorPlaceThatIsNotARequest(_ s: String) {
    #expect(!ActivityKinds.accepts(event("error", ["where": .string(s)])))
  }

  @Test(arguments: ["APIError", "sbd failed", "no session sx", "Boom"])
  func refusesAnErrorCodeOutsideTheKinds(_ s: String) {
    #expect(!ActivityKinds.accepts(event("error", ["code": .string(s)])))
  }

  @Test func errorCodeNamesTheKindOfFailureWithoutTheMessage() {
    struct Boom: Error {}
    #expect(ActivityKinds.errorCode(APIError("no session x")) == "refused")
    #expect(ActivityKinds.errorCode(APIError(APIError.closed)) == "connection")
    #expect(ActivityKinds.errorCode(POSIXError(.ECONNREFUSED)) == "connection")
    #expect(
      ActivityKinds.errorCode(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x"))) == "decoding")
    #expect(ActivityKinds.errorCode(Boom()) == "other")
  }

  // MARK: Session

  @Test(arguments: ["sab2cd", "s23456", "szzzzz"])
  func acceptsASessionIdOfShortIdsShape(_ session: String) {
    #expect(ActivityKinds.accepts(event("nav", session: session, ["to": "session"])))
  }

  @Test(arguments: ["", "hunter2", "sab12", "sab12cd", "sabl2c", "sab0cd", "Sab2cd", "s/ab2c", "sab2c\n"])
  func refusesASessionThatIsNotAShortId(_ session: String) {
    #expect(!ActivityKinds.accepts(event("nav", session: session, ["to": "session"])))
  }
}
