import Foundation

/// The date on a plan's "status as of" line. `PlanUpdates.dated` writes it.
/// `Plans.checkRewrite` checks an artifact chat's rewrite of it. Both read
/// the line with `find`, so they agree on which date the line holds.
enum StatusDates {
  static let phrase = "status as of"

  private static let months =
    "January|February|March|April|May|June|July|August|September|October|November|December"
  private static let shortMonths = "Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sept|Sep|Oct|Nov|Dec"

  /// The date shapes that a "status as of" line can hold, with the format
  /// that writes each one. A date starts and ends away from letters and
  /// digits. `\b` would miss a date between underscores, as in an italic
  /// `_status as of Nov 1, 2026_`.
  static let shapes: [(NSRegularExpression, String)] = [
    (#"\d{4}-\d{2}-\d{2}"#, "yyyy-MM-dd"),
    (#"(\#(months)) \d{1,2}, \d{4}"#, "MMMM d, yyyy"),
    (#"(\#(shortMonths)) \d{1,2}, \d{4}"#, "MMM d, yyyy"),
    (#"(\#(shortMonths))\. \d{1,2}, \d{4}"#, "MMM. d, yyyy"),
    (#"\d{1,2} (\#(months)) \d{4}"#, "d MMMM yyyy"),
    (#"\d{1,2} (\#(shortMonths)) \d{4}"#, "d MMM yyyy"),
    (#"\d{1,2} (\#(shortMonths))\. \d{4}"#, "d MMM. yyyy"),
  ].map { (try! NSRegularExpression(pattern: "(?<![A-Za-z0-9])(?:\($0.0))(?![A-Za-z0-9])"), $0.1) }

  /// The first date after the first "status as of" on the line, with the
  /// format of each shape that matches it, in the order of `shapes`. "May"
  /// is both a month and its short name, so a May date has two formats.
  /// Nil when a letter or digit sits between the phrase and that date,
  /// because then the date may belong to other text on the line.
  static func find(in line: String) -> (range: Range<String.Index>, formats: [String])? {
    guard let asOf = line.range(of: phrase, options: .caseInsensitive) else { return nil }
    let from = NSRange(asOf.upperBound..., in: line)
    let found = shapes.compactMap { regex, format in
      regex.firstMatch(in: line, range: from).map { ($0.range, format) }
    }
    guard let first = found.min(by: { $0.0.location < $1.0.location }), let range = Range(first.0, in: line),
      !line[asOf.upperBound..<range.lowerBound].contains(where: { $0.isLetter || $0.isNumber })
    else {
      return nil
    }
    return (range, found.filter { $0.0 == first.0 }.map(\.1))
  }

  /// True when `b` is `a` with its status date replaced by a date of the same
  /// shape: both lines hold a date, the text before and after it is the same,
  /// and some shape matches both dates.
  static func onlyDateDiffers(_ a: String, _ b: String) -> Bool {
    guard let x = find(in: a), let y = find(in: b) else { return false }
    return a[..<x.range.lowerBound] == b[..<y.range.lowerBound]
      && a[x.range.upperBound...] == b[y.range.upperBound...]
      && x.formats.contains(where: y.formats.contains)
  }
}
