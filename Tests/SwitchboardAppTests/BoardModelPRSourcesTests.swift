import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// The Settings window reads where PR updates come from with `sources`. An sbd that is older than the app has no
/// such op, or answers it in a shape the app can't read.
@MainActor
@Suite struct BoardModelPRSourcesTests {
  nonisolated static let sources = PRSources(
    providers: [PRSources.Source(id: "github-events", state: "live", wanted: 45, covered: 42)], pollSeconds: 30)

  /// A model whose `send` records every request and answers `sources` as `answer` says.
  func model(_ answer: @escaping @Sendable () throws -> JSON) -> (BoardModel, SentRequests) {
    let model = offlineModel()
    let sent = SentRequests()
    model.send = { op, args in
      sent.append(op, args)
      return op == "sources" ? try answer() : .null
    }
    return (model, sent)
  }

  /// Waits a moment for a change that should not come.
  func pause() async { try? await Task.sleep(nanoseconds: 200_000_000) }

  @Test func theModelStartsLoading() {
    #expect(offlineModel().prSources == .loading)
  }

  @Test func aReportShowsAsTheReport() async {
    let (model, _) = model { try JSON(encoding: Self.sources) }

    model.loadPRSources()
    await settle { model.prSources != .loading }

    #expect(model.prSources == .report(Self.sources))
  }

  /// A `recheck` argument would make each provider try again, which costs GitHub requests.
  @Test func loadPRSourcesSendsSourcesWithoutArguments() async {
    let (model, sent) = model { try JSON(encoding: Self.sources) }

    model.loadPRSources()
    await sent.wait(for: "sources")

    #expect(sent.value.filter { $0.op == "sources" }.map(\.args) == [[:]])
  }

  @Test func anUnknownRequestErrorMeansAnOlderSbd() async {
    let (model, _) = model { throw APIError("unknown request sources") }

    model.loadPRSources()
    await settle { model.prSources != .loading }

    #expect(model.prSources == .olderSbd)
  }

  /// The error's text decides, not its type.
  @Test func anUnknownRequestRefusalOfAnyTypeMeansAnOlderSbd() async {
    let (model, _) = model { throw Refusal(description: "sbd: unknown request sources") }

    model.loadPRSources()
    await settle { model.prSources != .loading }

    #expect(model.prSources == .olderSbd)
  }

  /// An answer that doesn't decode as `PRSources`, such as a provider without a state, comes from an sbd whose
  /// `sources` differs from the app's.
  @Test(arguments: [
    JSON.object(["providers": [["id": "x"]]]), JSON.object([:]), JSON.null, JSON.object(["providers": "none"]),
  ])
  func anAnswerThatDoesNotDecodeMeansAnOlderSbd(_ answer: JSON) async {
    let (model, _) = model { answer }

    model.loadPRSources()
    await settle { model.prSources != .loading }

    #expect(model.prSources == .olderSbd)
  }

  /// sbd being down or refusing for another reason says nothing about where PR updates come from.
  @Test func anotherErrorLeavesTheRowLoading() async {
    let (model, sent) = model { throw APIError("connection refused") }

    model.loadPRSources()
    await sent.wait(for: "sources")
    await pause()

    #expect(model.prSources == .loading)
  }

  @Test func anotherErrorKeepsTheLastReport() async {
    let (model, sent) = model { throw Boom() }
    model.prSources = .report(Self.sources)

    model.loadPRSources()
    await sent.wait(for: "sources")
    await pause()

    #expect(model.prSources == .report(Self.sources))
  }

  /// An "unknown request" for some other op is not an older sbd's answer to `sources`.
  @Test func anUnknownRequestOfAnotherOpIsAnotherError() async {
    let (model, sent) = model { throw APIError("unknown request live") }

    model.loadPRSources()
    await sent.wait(for: "sources")
    await pause()

    #expect(model.prSources == .loading)
  }

  @Test func aNewerReportReplacesAnOlderOne() async {
    var covered = Self.sources
    covered.providers[0].covered = 45
    let newer = covered
    let (model, _) = model { try JSON(encoding: newer) }
    model.prSources = .report(Self.sources)

    model.loadPRSources()
    await settle { model.prSources == .report(newer) }

    #expect(model.prSources == .report(newer))
  }

  /// An sbd updated after the app first asked answers the next read.
  @Test func aReportAfterAnOlderSbdReplacesIt() async {
    let (model, _) = model { try JSON(encoding: Self.sources) }
    model.prSources = .olderSbd

    model.loadPRSources()
    await settle { model.prSources == .report(Self.sources) }

    #expect(model.prSources == .report(Self.sources))
  }
}
