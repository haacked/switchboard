import Foundation

/// A model prompt or guide that lives in `prompts/<name>.md` instead of in a Swift literal, so an edit to its
/// text needs no recompile. A file marks each value that code supplies with `{{key}}`.
public enum Prompt: String, CaseIterable, Sendable {
  case operatorRole = "operator"
  case managerGuide = "manager-guide"
  case chatGuide = "chat-guide"
  case skillClassifier = "skill-classifier"
  case mergeBrief = "merge-brief"
  case quickAsk = "quick-ask"
  case triageSummarizer = "triage-summarizer"
  case topupPick = "topup-pick"
  case operatorReplyGate = "operator-reply-gate"
  case operatorCIFailure = "operator-ci-failure"
  case sessionNamer = "session-namer"
  case planUpdates = "plan-updates"
  case triageCard = "triage-card"

  public var fileName: String { rawValue + ".md" }

  /// The values that fill the file's placeholders. A file must name exactly these keys.
  var values: [String: String] {
    switch self {
    case .operatorRole:
      return ["managerOperatorName": Manager.operatorName, "eventSubscriptionsGuidance": EventSubscriptions.guidance]
    case .managerGuide:
      return [
        "childQuestionsGuidance": ChildQuestions.guidance, "sessionLinkGuidance": SessionLink.guidance,
        "managerOperatorName": Manager.operatorName, "eventSubscriptionsGuidance": EventSubscriptions.guidance,
        "mcpToolServerDefaultEventLimit": String(MCPToolServer.defaultEventLimit),
      ]
    case .chatGuide:
      return ["childQuestionsGuidance": ChildQuestions.guidance, "sessionLinkGuidance": SessionLink.guidance]
    case .skillClassifier, .mergeBrief, .quickAsk, .topupPick, .operatorReplyGate, .sessionNamer:
      return [:]
    case .triageSummarizer:
      return Self.triageLimits
    case .operatorCIFailure:
      return ["ciFailureMaxMessage": String(OperatorJudge.CIFailure.maxMessage)]
    case .planUpdates:
      return ["planUpdatesCellLength": String(PlanUpdates.cellLength)]
    case .triageCard:
      return Self.triageLimits.merging([
        "pendingDecisionDetailLength": String(PendingDecision.detailLength),
        "triageDraftsReplyToLength": String(TriageDrafts.replyToLength),
      ]) { $1 }
    }
  }

  /// The limits that both the summarizer's prompt and the card format quote.
  private static var triageLimits: [String: String] {
    [
      "triageTitleLength": String(Triage.titleLength), "triageCardLineLength": String(TriageCard.lineLength),
      "triageSummarizerMaxDecisions": String(TriageSummarizer.maxDecisions),
      "triageCardMaxOptions": String(TriageCard.maxOptions),
      "triageCardMaxCallouts": String(TriageCard.maxCallouts),
      "triageCardLabelLength": String(TriageCard.labelLength),
      "pendingDecisionHeaderLength": String(PendingDecision.headerLength),
      "pendingDecisionQuestionLength": String(PendingDecision.questionLength),
      "pendingDecisionContextLength": String(PendingDecision.contextLength),
      "pendingDecisionMinOptions": String(PendingDecision.minOptions),
      "pendingDecisionMaxOptions": String(PendingDecision.maxOptions),
      "triageDraftsMaxDrafts": String(TriageDrafts.maxDrafts),
    ]
  }
}

public struct PromptError: Error, CustomStringConvertible, Equatable {
  public var description: String
}

/// Fills `{{key}}` placeholders. It fills in one pass, so a value that contains `{{` stays as it is.
enum PromptTemplate {
  static func placeholders(in text: String) -> [String] {
    var names: [String] = []
    scan(text) { names.append($0) }
    return names
  }

  /// Throws unless the text names exactly the keys of `values`, and every `{{` opens a placeholder.
  static func fill(_ text: String, with values: [String: String], file: String) throws -> String {
    let found = placeholders(in: text)
    let names = Set(found)
    let missing = names.subtracting(values.keys).sorted()
    let unused = Set(values.keys).subtracting(names).sorted()
    var problems: [String] = []
    if !missing.isEmpty {
      problems.append("it names no value for \(missing.map { "{{\($0)}}" }.joined(separator: ", "))")
    }
    if !unused.isEmpty { problems.append("it never uses \(unused.map { "{{\($0)}}" }.joined(separator: ", "))") }
    if text.components(separatedBy: "{{").count - 1 != found.count {
      problems.append("it has a `{{` that is not a placeholder like {{name}}")
    }
    guard problems.isEmpty else { throw PromptError(description: "\(file): \(problems.joined(separator: "; "))") }
    var out = ""
    var rest = Substring(text)
    while let open = rest.range(of: "{{") {
      out += rest[..<open.lowerBound]
      let afterOpen = rest[open.upperBound...]
      let close = afterOpen.range(of: "}}")!
      out += values[String(afterOpen[..<close.lowerBound])]!
      rest = afterOpen[close.upperBound...]
    }
    return out + rest
  }

  private static func scan(_ text: String, _ found: (String) -> Void) {
    var rest = Substring(text)
    while let open = rest.range(of: "{{") {
      let afterOpen = rest[open.upperBound...]
      guard let close = afterOpen.range(of: "}}") else { return }
      let name = String(afterOpen[..<close.lowerBound])
      if !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber }) { found(name) }
      rest = afterOpen[close.upperBound...]
    }
  }
}

/// Every prompt, read and filled once.
public struct PromptLibrary: Sendable {
  public let directory: URL
  let texts: [Prompt: String]

  /// Reads every prompt from `directory`. It throws, naming the file, when one is missing, unreadable, or
  /// does not name the placeholders that code fills.
  public init(directory: URL) throws {
    var texts: [Prompt: String] = [:]
    for prompt in Prompt.allCases {
      let url = directory.appendingPathComponent(prompt.fileName)
      var text: String
      do { text = try String(contentsOf: url, encoding: .utf8) } catch {
        throw PromptError(description: "can't read prompt \(url.path): \(error.localizedDescription)")
      }
      // An editor adds a newline at the end of a file. A prompt ends with its last character.
      if text.hasSuffix("\n") { text.removeLast() }
      texts[prompt] = try PromptTemplate.fill(text, with: prompt.values, file: url.path)
    }
    self.directory = directory
    self.texts = texts
  }
}

public enum Prompts {
  public static let folderName = "Prompts"

  private nonisolated(unsafe) static var current: PromptLibrary?
  private static let lock = NSLock()

  /// Where the prompt files are, in this order:
  /// 1. `SB_PROMPTS_DIR`, for a test or an edit that needs no build.
  /// 2. `Contents/Resources/Prompts` of the Switchboard app that holds `executable`.
  /// 3. `prompts` in the checkout that compiled this module, for a SwiftPM build.
  public static func folder(
    executable: URL = ownExecutable(), environment: [String: String] = ProcessInfo.processInfo.environment,
    sourceFile: String = #filePath
  ) -> URL {
    if let path = environment["SB_PROMPTS_DIR"], !path.isEmpty { return URL(fileURLWithPath: path) }
    if let app = AppBundle.containing(executable: executable) {
      return app.appendingPathComponent("Contents/Resources/\(folderName)")
    }
    var root = URL(fileURLWithPath: sourceFile)
    for _ in 0..<3 { root.deleteLastPathComponent() }
    return root.appendingPathComponent("prompts")
  }

  /// Reads every prompt and makes them the ones that `text` returns. sbd calls it at start, so a missing or
  /// broken file stops sbd with an error and never reaches a model.
  @discardableResult
  public static func load(directory: URL = folder()) throws -> PromptLibrary {
    let library = try PromptLibrary(directory: directory)
    lock.lock()
    current = library
    lock.unlock()
    return library
  }

  /// The folder that the loaded prompts came from, or the one `load` would read.
  public static var folderInUse: URL {
    lock.lock()
    defer { lock.unlock() }
    return current?.directory ?? folder()
  }

  /// The prompt's text. A process that did not call `load` reads the files on first use. It exits when it
  /// can't, because a program can't run without its prompts.
  public static func text(_ prompt: Prompt) -> String {
    lock.lock()
    defer { lock.unlock() }
    if current == nil {
      do { current = try PromptLibrary(directory: folder()) } catch {
        FileHandle.standardError.write(Data("switchboard: \(error)\n".utf8))
        exit(EX_CONFIG)
      }
    }
    return current!.texts[prompt]!
  }
}
