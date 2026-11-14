import Foundation
import SwitchboardCore

extension Service {
  /// Writes one top-level setting into config.json and keeps every other setting there. It refuses to rewrite a
  /// file that it can't read as a JSON object.
  func saveSetting(_ key: String, _ value: JSON) throws {
    try updateSettings { $0[key] = value }
  }

  /// Reads config.json's top-level settings, lets `change` edit them, and writes them back. It refuses to rewrite a
  /// file that it can't read as a JSON object.
  func updateSettings(_ change: (inout [String: JSON]) throws -> Void) throws {
    var settings: [String: JSON] = [:]
    if FileManager.default.fileExists(atPath: home.config) {
      let text = try String(contentsOfFile: home.config, encoding: .utf8)
      guard let object = JSON.parse(text)?.object else {
        throw APIError("\(home.config) isn't a JSON object, so sbd can't save settings there")
      }
      settings = object
    }
    try change(&settings)
    try (JSON.object(settings).prettyText + "\n").write(toFile: home.config, atomically: true, encoding: .utf8)
  }
}
