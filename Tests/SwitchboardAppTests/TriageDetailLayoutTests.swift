import AppKit
import SwiftUI
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// The Inbox detail's header at the detail's minimum width, and at the width it has in a 1024 pt window.
@MainActor
@Suite struct TriageDetailHeaderLayout {
  static let longName = "Typo-tolerant search with fuzzy matching across every field"
  static let repoName = "posthog"
  static let branch = "haacked/typo-tolerant-search-with-fuzzy-matching"
  static let head = "haacked/typo-tolerant-search"

  func session(name: String, head: String = "") -> SessionSummary {
    var s = needsItem("layout")
    s.name = name
    s.repo = "/Users/me/dev/posthog/\(Self.repoName)"
    s.branch = Self.branch
    var pr = PRSummary(
      PullRequest(
        id: "PR_4812", number: 4812, url: "https://github.com/PostHog/posthog/pull/4812", repo: "PostHog/posthog",
        title: "Add typo-tolerant search", head: head))
    pr.checks = "SUCCESS"
    s.pr = pr
    return s
  }

  /// The detail's width in a 1024 pt window, where the sidebar hides and the list has its ideal width.
  static let narrowWindowWidth: CGFloat = {
    typealias Split = ListDetailSplit<EmptyView, EmptyView>
    return 1024 - Split.listIdealWidth - Split.dividerWidth
  }()

  func host(_ session: SessionSummary, width: CGFloat? = nil) -> HostedView {
    HostedView(
      TriageDetail(session: session)
        .environmentObject(offlineModel())
        .frame(width: width ?? ListDetailSplit<EmptyView, EmptyView>.detailMinWidth))
  }

  @Test func aLongNameShowsInFullWithTheRepoAndPRInA1024PointWindow() throws {
    let hosted = host(session(name: Self.longName), width: Self.narrowWindowWidth)

    let name = try #require(hosted.staticTexts(Self.longName).first?.frame?.width)
    #expect(name >= idealWidth(Text(verbatim: Self.longName).fontWeight(.medium)) - 1)
    #expect(hosted.staticTexts(Self.repoName).count == 1)
    #expect(hosted.prLinks.map(\.label) == [PRLink.accessibilityLabel("#4812")])
  }

  @Test func aLongNameLeavesThePRNumberReadableInFull() throws {
    let hosted = host(session(name: Self.longName))

    let link = try #require(hosted.prLinks.first)
    #expect(link.label == PRLink.accessibilityLabel("#4812"))
    let width = try #require(link.frame?.width)
    let ideal = idealWidth(PRLink(text: "#4812", url: URL(string: "https://example.com")!).font(.caption))
    #expect(width >= ideal - 1)
  }

  @Test func aLongNameDropsTheRepoAndBranchWholeInsteadOfShrinkingThem() throws {
    let hosted = host(session(name: Self.longName, head: Self.head))

    #expect(hosted.staticTexts(Self.longName).count == 1)
    for (label, font) in [(Self.repoName, Font.body), (Self.branch, .body), ("uses \(Self.head)", .caption)] {
      for element in hosted.staticTexts(label) {
        let width = try #require(element.frame?.width)
        #expect(width >= idealWidth(Text(verbatim: label).font(font)) - 1, "\(label) is \(width) pt wide")
      }
    }
  }

  @Test func aShortNameDropsOnlyTheLongBranch() throws {
    let hosted = host(session(name: "x", head: "h"))

    #expect(hosted.staticTexts(Self.repoName).count == 1)
    #expect(hosted.staticTexts(Self.branch).isEmpty)
    #expect(hosted.staticTexts("uses h").count == 1)
    #expect(hosted.prLinks.map(\.label) == [PRLink.accessibilityLabel("#4812")])
  }

  @Test func thePRLinkHelpCarriesTheStatusTitleAndHead() throws {
    let s = session(name: Self.longName, head: Self.head)
    let hosted = host(s)

    let link = try #require(hosted.prLinks.first)
    #expect(link.object.value(forKey: "accessibilityValue") as? String == s.pr?.status.rawValue)
    let help = link.object.value(forKey: "accessibilityHelp") as? String ?? ""
    #expect(help.contains(try #require(s.pr?.line)))
    #expect(help.contains("checks success"))
    #expect(help.contains("Add typo-tolerant search"))
    #expect(help.contains(Self.head))
  }
}
