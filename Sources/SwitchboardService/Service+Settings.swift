import Foundation
import SwitchboardCore

extension Service {
  /// The `auto-mode` request. With `autoMode`, it saves the setting in config.json and applies it to the sessions
  /// created after it. Sessions that exist keep their mode. The answer is the setting.
  func autoModeRequest(_ args: JSON) throws -> JSON {
    if let value = args["autoMode"] {
      guard let on = value.bool else { throw APIError("auto mode is on or off") }
      try saveSetting("autoMode", .bool(on))
      defaultAutoMode = on
      logLine(on ? "new sessions start in auto mode" : "new sessions start without auto mode")
    }
    return .object(["autoMode": .bool(defaultAutoMode)])
  }

  /// Writes one top-level setting into config.json and keeps every other setting there. It refuses to rewrite a
  /// file that it can't read as a JSON object.
  func saveSetting(_ key: String, _ value: JSON) throws {
    try updateSettings { $0[key] = value }
  }

  /// Writes one setting into a top-level object of config.json, such as `manager`, and keeps every other setting,
  /// including the object's other keys. It refuses to replace a value of `section` that isn't an object.
  func saveSetting(section: String, _ key: String, _ value: JSON) throws {
    try updateSettings { settings in
      var object: [String: JSON] = [:]
      if let existing = settings[section] {
        guard let existing = existing.object else {
          throw APIError("config.json's \(section) isn't a JSON object, so sbd can't save \(key) there")
        }
        object = existing
      }
      object[key] = value
      settings[section] = .object(object)
    }
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
