import Foundation
import Testing

@testable import SwitchboardApp

/// A click on a `switchboard:` link in a terminal pane goes straight to the app.
@MainActor
@Suite struct TerminalSessionLinkTests {
  @Test func routesASessionLinkToTheApp() {
    let view = ThemedTerminalView(frame: .zero)
    var received: [URL] = []
    view.openSessionLink = { received.append($0) }
    view.requestOpenLink(source: view, link: "switchboard://session/swb_pknjy", params: [:])
    #expect(received == [URL(string: "switchboard://session/swb_pknjy")!])
  }

  @Test func routesAnUppercaseSchemeToo() {
    let view = ThemedTerminalView(frame: .zero)
    var received: [URL] = []
    view.openSessionLink = { received.append($0) }
    view.requestOpenLink(source: view, link: "Switchboard://session/swb_pknjy", params: [:])
    #expect(received == [URL(string: "switchboard://session/swb_pknjy")!])
  }

  @Test func leavesOtherLinksToTheSystem() {
    #expect(ThemedTerminalView.sessionLinkURL("https://example.com/switchboard") == nil)
    #expect(ThemedTerminalView.sessionLinkURL("switchboardx://session/swb_pknjy") == nil)
    #expect(ThemedTerminalView.sessionLinkURL("not a url") == nil)
  }
}
