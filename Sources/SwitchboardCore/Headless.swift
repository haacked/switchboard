import Foundation

/// A one-shot `claude -p` turn that can only answer: no tools, no MCP
/// servers, no settings, and no saved session. Its answer is JSON that a
/// schema shapes.
public enum Headless {
  /// The arguments of the `claude` command, after the program.
  public static func arguments(model: String, schema: JSON, system: String) -> [String] {
    [
      "-p", "--model", model, "--output-format", "json", "--json-schema", schema.text, "--tools", "",
      "--strict-mcp-config", "--no-session-persistence", "--setting-sources", "", "--disable-slash-commands",
      "--system-prompt", system,
    ]
  }

  /// The JSON object that the output of `claude -p --output-format json` answers with.
  public static func answer(_ output: String) throws -> [String: JSON] {
    guard let envelope = JSON.parse(output) else {
      throw APIError("claude printed no JSON: \(oneLine(output, max: 200))")
    }
    if envelope["is_error"]?.bool == true {
      throw APIError("claude failed: \(oneLine(envelope["result"]?.string ?? output, max: 200))")
    }
    let payload =
      envelope["structured_output"]
      ?? envelope["result"]?.string.flatMap { JSON.parse(unfenced($0)) }
    guard let object = payload?.object else { throw APIError("claude's answer holds no JSON object") }
    return object
  }

  /// The text without a Markdown code fence around it.
  static func unfenced(_ text: String) -> String {
    var lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
    if lines.first?.hasPrefix("```") == true, lines.last?.hasPrefix("```") == true, lines.count >= 2 {
      lines.removeFirst()
      lines.removeLast()
    }
    return lines.joined(separator: "\n")
  }
}
