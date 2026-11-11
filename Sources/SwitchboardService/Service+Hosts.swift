import Foundation
import SwitchboardCore

extension Service {
  /// A link for each valid host that has one ssh destination. Every link starts disconnected,
  /// because an open ssh connection wakes a stopped devbox and keeps it running.
  static func makeHostLinks(config: Config, home: Home) -> [String: HostLink] {
    let ssh = findExecutable(config.ssh) ?? config.ssh
    var links: [String: HostLink] = [:]
    for (name, host) in config.hosts {
      guard let destination = host.sshDestination else { continue }
      links[name] = HostLink(config: host, destination: destination, ssh: ssh, home: home, now: { nowMs() })
    }
    return links
  }

  /// Starts each link's next attempt when its time has come. `tick` calls it. A link runs ssh
  /// on its own queue, so this never waits for a host.
  func superviseHosts(now: Int64) {
    for link in hostLinks.values { link.poll(now: now) }
  }

  /// One row for each host in config.json, valid or not, sorted by name.
  func hostStatuses() -> [HostStatus] {
    (Array(config.hosts.keys) + Array(config.hostProblems.keys)).sorted().compactMap(hostStatus)
  }

  private func hostStatus(_ name: String) -> HostStatus? {
    if let problem = config.hostProblems[name] {
      return HostStatus(name: name, kind: config.invalidHostKinds[name]?.rawValue, problem: problem)
    }
    guard let host = config.hosts[name] else { return nil }
    guard let link = hostLinks[name] else { return HostStatus(name: name, kind: host.kind.rawValue) }
    let status = link.status
    return HostStatus(
      name: name, kind: host.kind.rawValue, destination: link.destination, link: status.state, since: status.since,
      failures: status.failures, retryAt: status.retryAt, error: status.error)
  }

  /// The host's link. It throws for a name that config.json does not list, for an invalid
  /// host, and for a host with a link per box.
  private func hostLink(_ name: String) throws -> HostLink {
    if let problem = config.hostProblems[name] { throw APIError("\(name) is not usable: \(problem)") }
    guard config.hosts[name] != nil else { throw APIError("no host named \(name) in \(home.config)") }
    guard let link = hostLinks[name] else {
      throw APIError("\(name) has a link per box, which this version does not open")
    }
    return link
  }

  /// The machine of the host with the name. It never falls back to this Mac: it throws for a
  /// host that has no link, and the machine's commands fail while the link is not connected.
  func machine(onHost name: String) throws -> any Machine { try hostLink(name).machine }

  func hostRequest(_ op: String, _ args: JSON) throws -> JSON {
    if op == "hosts" { return try JSON(encoding: hostStatuses()) }
    guard let name = args["host"]?.string else { throw APIError("\(op) needs a host") }
    let link = try hostLink(name)
    if op == "host-connect" { link.connect() } else { link.disconnect() }
    return try JSON(encoding: hostStatus(name))
  }
}
