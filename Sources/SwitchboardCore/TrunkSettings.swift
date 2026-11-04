import Foundation

/// How sbd runs `trunk merge status`.
public struct TrunkSettings: Codable, Equatable, Sendable {
  /// The trunk CLI. sbd looks a name without a slash up on PATH and in the
  /// usual bin folders, then in Trunk's launcher cache.
  public var path: String = "trunk"
  /// How long one `trunk merge status` may run.
  public var timeoutSeconds: Double = 30

  public init() {}

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = TrunkSettings()
    path = try c.decodeIfPresent(String.self, forKey: .path) ?? d.path
    timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? d.timeoutSeconds
  }

  /// The trunk that `path` names, or nil when there is none.
  public func executable(home: String = NSHomeDirectory()) -> String? {
    findExecutable(path) ?? (path.contains("/") ? nil : TrunkSettings.launcherCache(home: home, name: path))
  }

  /// The newest `<home>/.cache/trunk/cli/<version>/<name>`. Trunk's launcher
  /// downloads the CLI there, and it isn't on PATH. Versions compare by their
  /// numbers, so 1.25.0 is newer than 1.9.0.
  public static func launcherCache(home: String, name: String = "trunk") -> String? {
    let root = "\(home)/.cache/trunk/cli"
    let versions = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
    return
      versions
      .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
      .map { "\(root)/\($0)/\(name)" }
      .first { FileManager.default.isExecutableFile(atPath: $0) }
  }
}
