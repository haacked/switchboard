import Foundation

/// Any JSON value. Hook payloads and API arguments use it, because their
/// fields vary by event and Claude Code release.
public enum JSON: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSON])
  case object([String: JSON])

  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let b = try? c.decode(Bool.self) {
      self = .bool(b)
    } else if let n = try? c.decode(Double.self) {
      self = .number(n)
    } else if let s = try? c.decode(String.self) {
      self = .string(s)
    } else if let a = try? c.decode([JSON].self) {
      self = .array(a)
    } else {
      self = .object(try c.decode([String: JSON].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let b): try c.encode(b)
    case .number(let n): try c.encode(n)
    case .string(let s): try c.encode(s)
    case .array(let a): try c.encode(a)
    case .object(let o): try c.encode(o)
    }
  }

  /// Any Encodable value as JSON.
  public init(encoding value: some Encodable) throws {
    self = try JSONCoding.convert(value, to: JSON.self)
  }

  public subscript(key: String) -> JSON? { object?[key] }

  public var object: [String: JSON]? {
    if case .object(let o) = self { return o }
    return nil
  }

  public var string: String? {
    if case .string(let s) = self { return s }
    return nil
  }

  /// Nil for a number that isn't a whole number in Int's range. Int(n) would
  /// stop the process on such a number. A client can send any number.
  public var int: Int? {
    if case .number(let n) = self { return Int(exactly: n) }
    return nil
  }

  public var double: Double? {
    if case .number(let n) = self { return n }
    return nil
  }

  public var bool: Bool? {
    if case .bool(let b) = self { return b }
    return nil
  }

  public var array: [JSON]? {
    if case .array(let a) = self { return a }
    return nil
  }

  /// The value as compact JSON text.
  public var text: String {
    let data = (try? JSONCoding.encoder.encode(self)) ?? Data()
    return String(decoding: data, as: UTF8.self)
  }

  /// The value as indented JSON text, for a file that people read.
  public var prettyText: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
  }

  public static func parse(_ text: String) -> JSON? {
    try? JSONCoding.decoder.decode(JSON.self, from: Data(text.utf8))
  }

  /// Decodes `data` as UTF-8 before it parses. A byte that isn't valid UTF-8
  /// becomes U+FFFD and does not fail the parse.
  public static func parse(_ data: Data) -> JSON? {
    parse(String(decoding: data, as: UTF8.self))
  }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
  public init(stringLiteral value: String) { self = .string(value) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(integerLiteral value: Int) { self = .number(Double(value)) }
  public init(floatLiteral value: Double) { self = .number(value) }
  public init(arrayLiteral elements: JSON...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, JSON)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
  }
}

public enum JSONCoding {
  public static let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return e
  }()

  public static let decoder = JSONDecoder()

  public static func encode<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  public static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
    try decoder.decode(type, from: Data(text.utf8))
  }

  /// Converts between two Codable types through JSON.
  public static func convert<T: Decodable>(_ value: some Encodable, to type: T.Type) throws -> T {
    try decoder.decode(type, from: encoder.encode(value))
  }
}
