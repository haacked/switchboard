import Foundation
import SwitchboardCore

/// Where a request came from. sbd sets it from the socket that the request arrived on, never from the request.
public enum RequestOrigin: Equatable, Sendable {
  /// sbd's own socket, `$SB_HOME/sbd.sock`, which only this Mac's user can reach.
  case mac
  /// The socket of the named remote host, `$SB_HOME/hosts/<host>/sbd.sock`, which any program on that host can
  /// reach through the forward.
  case remote(String)
}

/// The listeners on `$SB_HOME/hosts/<host>/sbd.sock`, one for each remote host that has a link. They listen
/// from the time sbd starts, so a forward always has a near end.
public enum HostServer {
  /// macOS holds a socket path in 104 bytes with its NUL.
  static let maxPathBytes = 103
  /// A hook payload can hold a tool's whole output. No request of a host is longer than this.
  static let maxLineBytes = 64 * 1024 * 1024

  /// Starts a listener for each host that has a link. A host whose socket can't listen gets the reason as
  /// its setup error, because its hooks could not reach sbd.
  public static func start(service: Service) {
    for (host, site) in service.remoteSites.sorted(by: { $0.key < $1.key }) {
      do {
        try listen(service: service, host: host).run()
      } catch {
        logLine("host \(host): \(error)")
        site.listenerProblem = "\(error)"
      }
    }
  }

  /// The path of the host's socket in the home. It throws for a path that a socket address can't hold.
  static func socketPath(for host: String, in home: Home) throws -> String {
    let path = home.hostSocket(host)
    guard path.utf8.count <= maxPathBytes else {
      throw APIError(
        "the socket for \(host), \(path), is \(path.utf8.count) bytes long, and a socket path holds at most "
          + "\(maxPathBytes). Move Switchboard's folder to a shorter path")
    }
    return path
  }

  /// Creates the host's folder for this user only and listens on its socket.
  static func listen(service: Service, host: String) throws -> Server {
    let path = try socketPath(for: host, in: service.home)
    let folder = (path as NSString).deletingLastPathComponent
    for dir in [service.home.hostsFolder, folder] {
      if mkdir(dir, 0o700) != 0, errno != EEXIST { throw APIError("can't create \(dir): \(UnixSocket.errnoText())") }
      var info = stat()
      // The socket is the only thing that names a request's host, so its folder must be a real folder of
      // this user that no one else can enter.
      guard lstat(dir, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
        throw APIError("\(dir) must be a folder of this user and not a link")
      }
      guard chmod(dir, 0o700) == 0 else { throw APIError("can't set the mode of \(dir): \(UnixSocket.errnoText())") }
    }
    return try Server(service: service, path: path, origin: .remote(host), maxLineBytes: maxLineBytes)
  }
}
