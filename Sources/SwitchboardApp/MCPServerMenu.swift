import SwiftUI
import SwitchboardCore

/// The MCP servers that a Manager conversation loads besides switchboard. Its label names the current setup,
/// and its items send `manager-mcp` changes.
struct MCPServerMenu: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary

  var body: some View {
    let answer = model.mcpAnswers[session.id]
    Menu {
      if let servers = session.mcp {
        // A server that config no longer lists stays, so the user can remove it.
        let available = answer?.available ?? []
        ForEach(available + servers.filter { !available.contains($0) }, id: \.self) { name in
          Toggle(
            name,
            isOn: Binding(
              get: { servers.contains(name) },
              set: { model.changeMCPServers(session.id, $0 ? .add(name) : .remove(name)) }))
        }
      } else {
        // sbd refuses add and rm while the conversation loads every server.
        Text("Choose Switchboard Only first to pick servers one by one")
        ForEach(answer?.available ?? [], id: \.self) { name in
          Toggle(name, isOn: .constant(true)).disabled(true)
        }
      }
      Divider()
      Button("Every MCP Server") { model.changeMCPServers(session.id, .all) }
        .disabled(session.mcp == nil)
      Button("Switchboard Only") { model.changeMCPServers(session.id, .none) }
        .disabled(session.mcp == [])
      if answer?.pending == true {
        Divider()
        Text(Manager.relaunchPendingText)
      }
    } label: {
      Text(Manager.serversText(session.mcp)).lineLimit(1)
    }
    .menuStyle(.borderlessButton)
    .fixedSize(horizontal: false, vertical: true)
    .help("The MCP servers that this conversation loads")
    .accessibilityLabel("MCP servers")
    .accessibilityValue(Manager.serversText(session.mcp))
    .accessibilityIdentifier("mcp-servers-\(session.id)")
    // A change stops claude and launches it again. Each step re-reads whether the relaunch is pending.
    .task(id: "\(session.id)/\(session.claudePid ?? 0)/\(session.live)") { model.loadMCPServers(session.id) }
  }
}
