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

  @Test func withConversationsTheHeaderShowsAboveThem() throws {
    let (model, _) = recordingModel([needsItem("m", manager: true, state: .working)])
    let hosted = host(model)

    #expect(hosted.buttons(naming: "New Manager conversation").count == 1)
    #expect(!hosted.buttons(naming: "Pin m").isEmpty)
  }
}
