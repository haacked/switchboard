import AppKit
import SwiftUI
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// The URLs that a hosted view passed to the `openURL` environment action.
final class OpenedURLs: @unchecked Sendable {
  private let lock = NSLock()
  private var opened: [URL] = []
  var urls: [URL] { lock.withLock { opened } }
  func append(_ url: URL) { lock.withLock { opened.append(url) } }
}

/// One accessibility element of a hosted view.
@MainActor
struct HostedElement {
  let role: String
  let label: String
  let object: NSObject

  /// SwiftUI's accessibility nodes do not cast to `NSAccessibilityProtocol`. The call goes through `AnyObject`.
  @discardableResult func press() -> Bool {
    (object as AnyObject).accessibilityPerformPress?() ?? false
  }

  var frame: CGRect? { (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue }
}

/// A SwiftUI view in a window that is never shown, with its accessibility elements.
@MainActor
struct HostedView {
  /// The elements hold no reference to the window. A test keeps the `HostedView` until it has pressed them.
  let window: NSWindow
  let elements: [HostedElement]

  /// SwiftUI builds no accessibility tree until an assistive client asks for one.
  private static let accessibilityOn: Void = {
    _ = NSApplication.shared
    // The NSAccessibility protocol has no setter for this attribute. The test
    // sends the deprecated message by its selector instead.
    _ = NSApp.perform(
      NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: true, with: "AXEnhancedUserInterface")
  }()

  /// Records an issue when the view exposes no accessibility elements.
  init<V: View>(_ view: V, sourceLocation: SourceLocation = #_sourceLocation) {
    Self.accessibilityOn
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: view)
    window.contentView = host
    host.layoutSubtreeIfNeeded()

    var found: [HostedElement] = []
    func walk(_ object: NSObject) {
      for case let child as NSObject in (object.value(forKey: "accessibilityChildren") as? [Any]) ?? [] {
        found.append(
          HostedElement(
            role: (child.value(forKey: "accessibilityRole") as? String) ?? "",
            label: (child.value(forKey: "accessibilityLabel") as? String) ?? "",
            object: child))
        walk(child)
      }
    }
    walk(host)
    elements = found
    if found.isEmpty {
      Issue.record(
        "The hosted view exposes no accessibility elements. AXEnhancedUserInterface did not build the tree for an unshown window.",
        sourceLocation: sourceLocation)
    }
  }

  var prLinks: [HostedElement] {
    elements.filter { $0.role == "AXLink" && $0.label.hasPrefix("Pull request") }
  }

  /// The buttons whose label names the session. The card's other buttons (notes, merge, delete) do not name it.
  func buttons(naming name: String) -> [HostedElement] {
    elements.filter { $0.role == "AXButton" && $0.label.contains(name) }
  }
}

private let prNumber = 5
private let httpsURL = "https://github.com/o/r/pull/\(prNumber)"
private let prLabel = "Pull request #\(prNumber)"

/// The PR shapes of a Board card.
enum CardPR: String, CaseIterable, CustomTestStringConvertible, Sendable {
  case https
  case httpsWithCodeOwners
  case notHttps
  case none

  static let linked: [CardPR] = [.https, .httpsWithCodeOwners]
  static let unlinked: [CardPR] = [.notHttps, .none]

  var testDescription: String { rawValue }

  var summary: PRSummary? {
    switch self {
    case .https: return pr(url: httpsURL)
    case .httpsWithCodeOwners:
      var pr = pr(url: httpsURL)
      pr.codeOwners = CodeOwnerStatus(satisfied: false, groups: [])
      return pr
    case .notHttps: return pr(url: "http://github.com/o/r/pull/\(prNumber)")
    case .none: return nil
    }
  }

  private func pr(url: String) -> PRSummary {
    PRSummary(PullRequest(id: "PR_\(prNumber)", number: prNumber, url: url, repo: "o/r"))
  }
}

private let sessionID = "pr-link-session"

private func session(_ pr: CardPR) -> SessionSummary {
  var s = needsItem(sessionID)
  s.pr = pr.summary
  return s
}

@MainActor
private func recording<V: View>(_ view: V, model: BoardModel, into opened: OpenedURLs) -> some View {
  view
    .environmentObject(model)
    .environment(
      \.openURL,
      OpenURLAction {
        opened.append($0)
        return .handled
      })
}

@Suite struct PRLinkLabel {
  @Test func labelNamesThePullRequest() {
    #expect(PRLink.accessibilityLabel("#123") == "Pull request #123")
  }
}

@MainActor
@Suite struct HostedPRLink {
  let url = URL(string: httpsURL)!
  let opened = OpenedURLs()

  @Test func pressOnTheOnlyLinkOpensTheURLOnce() throws {
    let hosted = HostedView(recording(PRLink(text: "#\(prNumber)", url: url), model: offlineModel(), into: opened))
    let links = hosted.elements.filter { $0.role == "AXLink" }
    #expect(links.map(\.label) == [prLabel])

    try #require(links.first).press()

    #expect(opened.urls == [url])
  }
}

@MainActor
@Suite struct BoardCardPRLink {
  let model = offlineModel()
  let opened = OpenedURLs()

  func host(_ pr: CardPR, draggable: Bool) -> HostedView {
    let card = BoardCard(session: session(pr))
    return HostedView(
      recording(draggable ? AnyView(card.draggable(sessionID)) : AnyView(card), model: model, into: opened))
  }

  @Test(arguments: CardPR.linked, [false, true])
  func pressOnTheLinkOpensThePRAndLeavesTheModelUnchanged(_ pr: CardPR, draggable: Bool) throws {
    let hosted = host(pr, draggable: draggable)
    #expect(hosted.prLinks.map(\.label) == [prLabel])
    let (selection, inboxFocus, mainView) = (model.selection, model.inboxFocus, model.mainView)

    try #require(hosted.prLinks.first).press()

    #expect(opened.urls == [try #require(pr.summary?.link)])
    #expect(model.selection == selection)
    #expect(model.inboxFocus == inboxFocus)
    #expect(model.mainView == mainView)
  }

  @Test(arguments: CardPR.linked, [false, true])
  func linkCoversThePRNumberOnTheCard(_ pr: CardPR, draggable: Bool) throws {
    let hosted = host(pr, draggable: draggable)
    let link = try #require(hosted.prLinks.first?.frame)
    let card = try #require(hosted.buttons(naming: sessionID).first?.frame)

    #expect(card.contains(link))
    #expect(link.minX > card.midX)
  }

  @Test(arguments: CardPR.unlinked, [false, true])
  func cardWithoutAnHttpsPRExposesNoLink(_ pr: CardPR, draggable: Bool) {
    #expect(host(pr, draggable: draggable).prLinks.isEmpty)
  }

  @Test(arguments: [false, true])
  func cardWithANonHttpsPRShowsTheNumberAsText(draggable: Bool) throws {
    let card = try #require(host(.notHttps, draggable: draggable).buttons(naming: sessionID).first)
    #expect(card.label.contains("#\(prNumber)"))
  }

  @Test(arguments: CardPR.allCases, [false, true])
  func pressOnTheCardSelectsTheSessionAndOpensNoURL(_ pr: CardPR, draggable: Bool) throws {
    let hosted = host(pr, draggable: draggable)
    let cards = hosted.buttons(naming: sessionID)
    #expect(cards.count == 1)

    try #require(cards.first).press()

    #expect(model.selection == sessionID)
    #expect(opened.urls.isEmpty)
  }
}

@MainActor
@Suite struct SessionRowPRLink {
  let opened = OpenedURLs()

  @Test func pressOnTheOnlyLinkOpensThePROnce() throws {
    let hosted = HostedView(
      recording(
        SessionRow(session: session(.https), activeAccount: ClaudeAccount.defaultFolder), model: offlineModel(),
        into: opened))
    #expect(hosted.prLinks.map(\.label) == [prLabel])

    try #require(hosted.prLinks.first).press()

    #expect(opened.urls == [try #require(CardPR.https.summary?.link)])
  }
}
