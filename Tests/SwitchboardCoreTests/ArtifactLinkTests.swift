import Foundation
import Testing

@testable import SwitchboardCore

/// Links that the parser accepts, each with the link it normalizes to.
private let accepted: [(String, String)] = [
  ("https://claude.ai/artifact/3f9c2a1b", "https://claude.ai/artifact/3f9c2a1b"),
  (
    "https://claude.ai/code/artifact/0f3c9a2e-6b1d-4c8e-9a7f-2d5e8b1c4a90",
    "https://claude.ai/code/artifact/0f3c9a2e-6b1d-4c8e-9a7f-2d5e8b1c4a90"
  ),
  ("https://claude.ai/artifact/AbCdEfGhIjKlMnOpQrStUv", "https://claude.ai/artifact/AbCdEfGhIjKlMnOpQrStUv"),
  ("https://claude.ai/artifact/a_b-C_9", "https://claude.ai/artifact/a_b-C_9"),
  ("HTTPS://CLAUDE.AI/artifact/AbCdEf", "https://claude.ai/artifact/AbCdEf"),
  ("https://Claude.AI/code/artifact/AbCdEf", "https://claude.ai/code/artifact/AbCdEf"),
  ("https://claude.ai/artifact/3f9c2a1b?tab=preview", "https://claude.ai/artifact/3f9c2a1b"),
  ("https://claude.ai/artifact/3f9c2a1b#section-2", "https://claude.ai/artifact/3f9c2a1b"),
  ("https://claude.ai/code/artifact/0f3c9a2e?x=1#y", "https://claude.ai/code/artifact/0f3c9a2e"),
  ("https://claude.ai/artifact/3f9c2a1b?next=https://evil.example.com", "https://claude.ai/artifact/3f9c2a1b"),
  ("https://claude.ai/artifact/3f9c2a1b/", "https://claude.ai/artifact/3f9c2a1b"),
]

/// Links that are not claude.ai artifact links.
private let refused: [String] = [
  "",
  "http://claude.ai/artifact/3f9c2a1b",
  "https://claude.ai.evil.com/artifact/3f9c2a1b",
  "https://evil.com/artifact/3f9c2a1b",
  "https://evil.com/claude.ai/artifact/3f9c2a1b",
  "https://claude.ai@evil.com/artifact/3f9c2a1b",
  "https://claude.ai./artifact/3f9c2a1b",
  "https://claude.ai/artifact/3f9c2a1b/edit",
  "https://claude.ai/code/artifact/3f9c2a1b/edit",
  "https://claude.ai/project/p1/artifact/3f9c2a1b",
  "https://claude.ai/artifacts/3f9c2a1b",
  "https://claude.ai/chat/3f9c2a1b",
  "https://claude.ai/code/3f9c2a1b",
  "https://claude.ai/artifact/",
  "https://claude.ai/code/artifact/",
  "https://claude.ai/artifact",
  "https://claude.ai/",
  "https://claude.ai/artifact/abc%0Atask:%20publish",
  "https://claude.ai/artifact/abc%0Ddef",
  "https://claude.ai/artifact/abc%2Fdef",
  "https://claude.ai/code/artifact/abc%2Fedit",
  "https://claude.ai/artifact/..%2F..%2Fevil",
  "https://claude.ai/artifact/abc%20def",
  "https://claude.ai/artifact/abc%60def",
  "https://claude.ai/artifact/abc%C3%A9",
  "javascript:alert(1)",
  "javascript://claude.ai/artifact/3f9c2a1b",
  "file:///claude.ai/artifact/3f9c2a1b",
  "claude.ai/artifact/3f9c2a1b",
  "//claude.ai/artifact/3f9c2a1b",
  "3f9c2a1b",
]

/// Odd links that today's rules may accept. Each one must either be refused or
/// normalize to a clean link on claude.ai.
private let odd: [String] = [
  "https://evil.com@claude.ai/artifact/3f9c2a1b",
  "https://user:pass@claude.ai/artifact/3f9c2a1b",
  "https://claude.ai:8443/artifact/3f9c2a1b",
  "https://claude.ai//artifact/3f9c2a1b",
  "https://claude.ai/code%2Fartifact/3f9c2a1b",
  "https://claude.ai/artifact/3f9c2a1b%3Fq",
  "https://claude.ai/artifact/3f9c2a1b%23frag",
  "https://claude.ai\\@evil.com/artifact/3f9c2a1b",
  " https://claude.ai/artifact/3f9c2a1b",
  "https://claude.ai/artifact/3f9c2a1b\n",
]

private let allInputs: [String] = accepted.map(\.0) + refused + odd

/// The only shape a recorded or attached artifact link may have.
private func isCleanArtifactLink(_ link: String) throws -> Bool {
  let pattern = try Regex("https://claude\\.ai/(code/)?artifact/[A-Za-z0-9_-]+")
  return link.wholeMatch(of: pattern) != nil
}

/// The artifact link that plan attach reads from `doc`, or nil when plan attach
/// refuses it or reads it as another kind of source.
private func planAttachLink(_ doc: String) -> String? {
  guard let source = try? PlanSource(parsing: doc, path: nil, cwd: "/nonexistent"), source.kind == .artifact
  else { return nil }
  return source.url
}

@Suite struct ArtifactLinkTests {
  @Test(arguments: accepted)
  func artifactLinkInEachFormNormalizesWithoutQueryOrFragment(_ link: String, _ expected: String) {
    #expect(ArtifactLink.normalized(link) == expected)
  }

  @Test func idKeepsItsCase() {
    let link = ArtifactLink.normalized("HTTPS://CLAUDE.AI/artifact/AbCdEfGh")

    #expect(link == "https://claude.ai/artifact/AbCdEfGh")
  }

  @Test(arguments: refused)
  func linkThatIsNotAClaudeArtifactIsRefused(_ link: String) {
    #expect(ArtifactLink.normalized(link) == nil)
  }

  @Test func artifactPathSegmentIsCaseSensitive() {
    #expect(ArtifactLink.normalized("https://claude.ai/ARTIFACT/3f9c2a1b") == nil)
  }

  @Test(arguments: allInputs)
  func everyNormalizedLinkIsACleanClaudeArtifactLink(_ link: String) throws {
    guard let normalized = ArtifactLink.normalized(link) else { return }

    #expect(try isCleanArtifactLink(normalized), "\(link.debugDescription) normalized to \(normalized)")
  }

  @Test(arguments: allInputs)
  func normalizedLinkNamesNoOtherHost(_ link: String) {
    guard let normalized = ArtifactLink.normalized(link) else { return }

    #expect(!normalized.contains("evil"))
    #expect(!normalized.contains("@"))
    #expect(!normalized.contains(":8443"))
  }

  @Test(arguments: allInputs)
  func normalizingANormalizedLinkReturnsItUnchanged(_ link: String) {
    guard let normalized = ArtifactLink.normalized(link) else { return }

    #expect(ArtifactLink.normalized(normalized) == normalized)
  }

  @Test(arguments: allInputs.filter { $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) })
  func planAttachReadsTheSameArtifactLinkAsTheParser(_ link: String) {
    #expect(planAttachLink(link) == ArtifactLink.normalized(link))
  }

  @Test(arguments: allInputs)
  func planAttachAcceptsEveryNormalizedLink(_ link: String) {
    guard let normalized = ArtifactLink.normalized(link) else { return }

    #expect(planAttachLink(normalized) == normalized)
  }

  @Test(arguments: [
    ("https://claude.ai/artifact/AbCdEfGhIjKlMnOpQrStUv", "AbCdEfGhIjKlMnOpQrStUv"),
    ("https://claude.ai/code/artifact/0f3c9a2e-6b1d-4c8e-9a7f-2d5e8b1c4a90", "0f3c9a2e-6b1d-4c8e-9a7f-2d5e8b1c4a90"),
    ("https://claude.ai/code/artifact/0F3C9A2E-6B1D-4C8E-9A7F-2D5E8B1C4A90", "0F3C9A2E-6B1D-4C8E-9A7F-2D5E8B1C4A90"),
    ("https://claude.ai/artifact/3f9c2a1b?tab=preview", "3f9c2a1b"),
    ("https://claude.ai/code/artifact/0f3c9a2e?x=1#y", "0f3c9a2e"),
    ("https://claude.ai/artifact/3f9c2a1b/", "3f9c2a1b"),
    ("HTTPS://CLAUDE.AI/artifact/AbCdEf", "AbCdEf"),
  ])
  func idOfAnArtifactLinkIsItsLastPathComponent(_ link: String, _ expected: String) {
    #expect(ArtifactLink.id(of: link) == expected)
  }

  @Test(arguments: refused)
  func idOfALinkThatIsNotAClaudeArtifactIsNil(_ link: String) {
    #expect(ArtifactLink.id(of: link) == nil)
  }

  @Test func shortAndCodeFormsOfTheSameIdHaveTheSameId() {
    let id = "0f3c9a2e-6b1d-4c8e-9a7f-2d5e8b1c4a90"

    let short = ArtifactLink.id(of: "https://claude.ai/artifact/\(id)")
    let code = ArtifactLink.id(of: "https://claude.ai/code/artifact/\(id)")

    #expect(short == id)
    #expect(code == id)
  }

  @Test(arguments: allInputs)
  func idOfANormalizedLinkIsTheIdOfTheOriginalLink(_ link: String) {
    guard let normalized = ArtifactLink.normalized(link) else { return }

    #expect(ArtifactLink.id(of: normalized) == ArtifactLink.id(of: link))
  }

  // MARK: artifactId(of:)

  /// Only a `/code/artifact/<id>` link's id is the `artifact_id` that a publish records.
  @Test(arguments: [
    "https://claude.ai/code/artifact/0f3c9a2e-6b1d-4c8e-9a7f-2d5e8b1c4a90",
    "https://claude.ai/code/artifact/0f3c9a2e-6b1d-4c8e-9a7f-2d5e8b1c4a90#section-2",
    "https://claude.ai/code/artifact/0f3c9a2e-6b1d-4c8e-9a7f-2d5e8b1c4a90?x=1",
    "https://claude.ai/code/artifact/0f3c9a2e-6b1d-4c8e-9a7f-2d5e8b1c4a90/",
    "https://Claude.AI/code/artifact/0f3c9a2e-6b1d-4c8e-9a7f-2d5e8b1c4a90",
  ])
  func artifactIdOfACodeLinkIsItsId(_ link: String) {
    #expect(ArtifactLink.artifactId(of: link) == "0f3c9a2e-6b1d-4c8e-9a7f-2d5e8b1c4a90")
  }

  @Test(arguments: [
    "https://claude.ai/artifact/0f3c9a2e-6b1d-4c8e-9a7f-2d5e8b1c4a90",
    "https://claude.ai/artifact/AbCdEfGhIjKlMnOpQrStUv",
    "https://claude.ai/artifact/AbCdEfGhIjKlMnOpQrStUv#section-2",
    "https://Claude.AI/artifact/AbCdEfGhIjKlMnOpQrStUv/",
  ])
  func artifactIdOfAShortLinkIsNil(_ link: String) {
    #expect(ArtifactLink.artifactId(of: link) == nil)
  }

  @Test(arguments: refused)
  func artifactIdOfALinkThatIsNotAClaudeArtifactIsNil(_ link: String) {
    #expect(ArtifactLink.artifactId(of: link) == nil)
  }

  // MARK: A group link's artifact row and plan attach

  /// "Use as plan" sends a link row's URL to plan attach, so a link becomes a row exactly when plan attach takes
  /// its URL as an artifact, and the row's URL is the one plan attach reads.
  @Test(arguments: allInputs.filter { $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) })
  func aLinkBecomesAnArtifactRowExactlyWhenPlanAttachAcceptsIt(_ link: String) {
    let row = GroupArtifact(link: ExternalLink(id: "l1", title: "Plan", url: link, by: .you, t: 1))

    #expect(row?.url == planAttachLink(link), "\(link.debugDescription)")
  }

  @Test(arguments: allInputs)
  func aLinkRowsURLIsACleanClaudeArtifactLink(_ link: String) throws {
    guard let row = GroupArtifact(link: ExternalLink(id: "l1", title: "Plan", url: link, by: .you, t: 1)) else {
      return
    }

    #expect(try isCleanArtifactLink(row.url), "\(link.debugDescription) gave \(row.url)")
    #expect(planAttachLink(row.url) == row.url)
  }
}
