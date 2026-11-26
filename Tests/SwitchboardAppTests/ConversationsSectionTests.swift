import AppKit
import SwiftUI
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// The sidebar's Conversations section, whose header starts a Manager conversation.
@MainActor
@Suite struct ConversationsSectionTests {
  /// `HostedView` cannot walk a `List`'s rows, whose accessibility objects have no `accessibilityChildren` key. A
  /// stack lays out the section's header and rows instead.
  func host(_ model: BoardModel) -> HostedView {
    HostedView(VStack { ConversationsSection(activeAccount: "", removableSelection: 0) }.environmentObject(model))
  }

  @Test func withNoConversationsTheHeaderStillStartsOne() async throws {
    let (model, sent) = recordingModel([needsItem("w", state: .working)])
    #expect(model.managers.isEmpty)
    let hosted = host(model)

    let button = try #require(hosted.buttons(naming: "New Manager conversation").first)
    #expect(button.press())
    await sent.wait(for: "manager")
    #expect(sent.value.first { $0.op == "manager" }?.args["new"] == .bool(true))
  }

  /// A sidebar `List` gives an empty section's header a row of its own.
  @Test func aSidebarListShowsTheHeaderOfNoConversations() throws {
    let (model, _) = recordingModel([needsItem("w", state: .working)])
    let host = NSHostingView(
      rootView: List { ConversationsSection(activeAccount: "", removableSelection: 0) }
        .listStyle(.sidebar)
        .frame(width: 300, height: 300)
        .environmentObject(model))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.layoutSubtreeIfNeeded()

    func outline(in view: NSView) -> NSOutlineView? {
      view as? NSOutlineView ?? view.subviews.lazy.compactMap(outline).first
    }
    let list = try #require(outline(in: host))
    #expect(list.numberOfRows == 1)
  }

  @Test func withConversationsTheHeaderShowsOnceWithTheirRows() throws {
    let (model, _) = recordingModel([needsItem("m", manager: true, state: .working)])
    let hosted = host(model)

    #expect(hosted.buttons(naming: "New Manager conversation").count == 1)
    #expect(!hosted.buttons(naming: "Pin m").isEmpty)
  }
}

/// Where a group chat shows its conversations (Decision 9): a column beside the terminals when the detail has room
/// for both, else a Conversations menu in the chat's header.
@Suite struct ConversationsSectionTestsColumnFit {
  /// The two terminals' minimum widths with the shell open.
  static let terminals = SessionView.claudeMinWidth + SessionView.shellMinWidth
  /// A 1024 pt window leaves this much for the detail with the widest and the narrowest sidebar.
  static let detailAt1024: [CGFloat] = [724, 784]

  @Test func theColumnIs200PointsWide() {
    #expect(GroupConversationsColumn.width == 200)
  }

  @Test(arguments: detailAt1024)
  func theColumnFitsBesideBothTerminalsAt1024(_ width: CGFloat) {
    #expect(GroupConversationsColumn.fits(width: width, beside: Self.terminals))
  }

  @Test func theColumnFitsAtExactlyItsWidthPlusTheTerminals() {
    #expect(
      GroupConversationsColumn.fits(width: GroupConversationsColumn.width + Self.terminals, beside: Self.terminals))
  }

  @Test func aDetailOnePointTooNarrowShowsTheMenu() {
    #expect(
      !GroupConversationsColumn.fits(width: GroupConversationsColumn.width + Self.terminals - 1, beside: Self.terminals)
    )
  }

  @Test func withTheShellClosedTheColumnFitsInANarrowerDetail() {
    #expect(GroupConversationsColumn.fits(width: 560, beside: SessionView.claudeMinWidth))
    #expect(!GroupConversationsColumn.fits(width: 560, beside: Self.terminals))
  }

  /// The column takes room before the side panel. At 1024 pt the side panel no longer fits beside the column and
  /// both terminals.
  @Test(arguments: detailAt1024)
  func theSidePanelDoesNotFitBesideTheColumnAndBothTerminalsAt1024(_ width: CGFloat) {
    #expect(!SidePanel.fits(width: width - GroupConversationsColumn.width, beside: Self.terminals))
  }
}
