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
    let valid = config.hosts.values.map { hostStatus($0, link: hostLinks[$0.name]) }
    let invalid = config.invalidHosts.map {
      HostStatus(name: $0.key, kind: $0.value.kind?.rawValue, problem: $0.value.problem)
    }
    return (valid + invalid).sorted { $0.name < $1.name }
  }

  private func hostStatus(_ host: HostConfig, link: HostLink?) -> HostStatus {
    guard let link else { return HostStatus(name: host.name, kind: host.kind.rawValue) }
    let status = link.status
    return HostStatus(
      name: host.name, kind: host.kind.rawValue, destination: link.destination, link: status.state,
      since: status.since, failures: status.failures, retryAt: status.retryAt,
      error: status.error ?? remoteSites[host.name]?.setupError)
  }

  /// The host's link. It throws for a name that config.json does not list, for an invalid
  /// host, and for a hogli host with the perSession layout.
  func hostLink(_ name: String) throws -> HostLink {
    if let host = config.invalidHosts[name] { throw APIError("\(name) is not usable: \(host.problem)") }
    guard config.hosts[name] != nil else { throw APIError("no host named \(name) in \(home.config)") }
    guard let link = hostLinks[name] else {
      throw APIError("\(name) uses the perSession layout, which this version can't connect to")
    }
    return link
  }

  /// The site of the host with the name. It throws as `hostLink` does.
  func remoteSite(_ name: String) throws -> RemoteSite {
    _ = try hostLink(name)
    guard let site = remoteSites[name] else { throw APIError("no host named \(name) in \(home.config)") }
    return site
  }

  /// The machine of the host with the name. It never falls back to this Mac: it throws for a
  /// host that has no link, and the machine's commands fail while the link is not connected.
  func machine(onHost name: String) throws -> any Machine { try hostLink(name).machine }

  func hostRequest(_ op: String, _ args: JSON) throws -> JSON {
    if op == "hosts" { return try JSON(encoding: hostStatuses()) }
    guard let name = args["host"]?.string else { throw APIError("\(op) needs a host") }
    let link = try hostLink(name)
    if op == "host-connect" { link.connect() } else { link.disconnect() }
    return try JSON(encoding: hostStatus(link.config, link: link))
  }
}
