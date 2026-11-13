import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct OfferTextTitle {
  @Test func theExamplesLastParagraphNamesTheBranch() {
    let previous = "The `haacked/round-trip-drop-old-bounds-v2` branch still exists on origin with the same commits."

    let title = OfferText.title(question: "Do you want me to delete it?", previous: previous)

    #expect(title == "Delete the branch haacked/round-trip-drop-old-bounds-v2?")
  }

  /// One row for each entry of `Attention.offerStarts`.
  @Test(arguments: [
    ("Want me to push?", "Push?"),
    ("Should I push?", "Push?"),
    ("Shall I tag v2?", "Tag v2?"),
    ("Would you like me to rebase?", "Rebase?"),
    ("Do you want me to open the PR?", "Open the PR?"),
    ("Should we ship?", "Ship?"),
    ("Shall we merge?", "Merge?"),
    ("Ready for me to push?", "Push?"),
    ("Ok to merge?", "Merge?"),
    ("Okay to merge?", "Merge?"),
    ("Want to see the diff?", "See the diff?"),
    ("Want me to merge it?", "Merge it?"),
    ("SHOULD I push?", "Push?"),
  ])
  func stripsTheOfferStart(_ question: String, _ title: String) {
    #expect(OfferText.title(question: question, previous: nil) == title)
  }

  @Test func aQuestionThatOnlyStartsLikeAnOfferKeepsItsWords() {
    #expect(OfferText.title(question: "Should it be renamed?", previous: nil) == "Should it be renamed?")
  }

  // MARK: Pronouns (Risk 3)

  @Test(arguments: [
    // One code span.
    ("I wrote `cleanup.sh` for the old builds.", "Want me to run it?", "Run cleanup.sh?"),
    // One slash token and no code span. The word before it is a noun.
    ("The branch haacked/foo-v2 still exists on origin.", "Should I delete it?", "Delete the branch haacked/foo-v2?"),
    // A code span and a slash token: the code span is the one candidate.
    ("I moved `deploy.sh` into tools/scripts.", "Want me to commit it?", "Commit deploy.sh?"),
    // The same code span twice is one candidate.
    ("I kept `tools/run` and fixed `tools/run` too.", "Should I delete it?", "Delete tools/run?"),
    // A URL is not a candidate, so the slash token is the only one.
    ("docs/links.md now holds https://example.com/a/b.", "Should I open it?", "Open docs/links.md?"),
    ("I wrote `notes.md` in the repo.", "Want me to commit this?", "Commit notes.md?"),
    ("The tag `v2.0` points at main.", "Should I push that?", "Push the tag v2.0?"),
  ])
  func resolvesAPronounWithOneCandidate(_ previous: String, _ question: String, _ title: String) {
    #expect(OfferText.title(question: question, previous: previous) == title)
  }

  @Test(arguments: ["branch", "file", "folder", "directory", "worktree", "tag", "commit", "PR"])
  func aNounAfterTheCandidateNamesIt(_ noun: String) {
    let title = OfferText.title(question: "Should I delete it?", previous: "The `x/y` \(noun) is stale.")

    #expect(title == "Delete the \(noun) x/y?")
  }

  @Test(arguments: ["branch", "file", "folder", "directory", "worktree", "tag", "commit", "PR"])
  func aNounBeforeTheCandidateNamesIt(_ noun: String) {
    let title = OfferText.title(question: "Should I delete it?", previous: "I left the \(noun) `x/y` behind.")

    #expect(title == "Delete the \(noun) x/y?")
  }

  @Test(arguments: [
    // Two code spans.
    ("I updated `a.swift` and `b.swift`.", "Want me to commit it?", "Commit it?"),
    // Two slash tokens.
    ("I compared main/a and main/b.", "Should I merge it?", "Merge it?"),
    // A URL alone.
    ("The docs are at https://example.com/a/b now.", "Should I open it?", "Open it?"),
    // A slash without a letter or digit on each side.
    ("I left a / in the name.", "Should I fix it?", "Fix it?"),
    // No candidate at all.
    ("The build passes.", "Should I merge it?", "Merge it?"),
    // The pronoun is not the second word.
    ("The `foo` branch exists.", "Should I push the changes to it?", "Push the changes to it?"),
    ("The `foo` branch exists.", "Should I delete them?", "Delete them?"),
    ("The `foo` branch exists.", "Should I delete these?", "Delete these?"),
    ("The `foo` branch exists.", "Should I delete those?", "Delete those?"),
    // The one candidate follows a preposition, so it is a target and not the object.
    ("I rebased the branch onto origin/main.", "Want me to force-push it?", "Force-push it?"),
    ("The tests pass on `main`.", "Should I merge it?", "Merge it?"),
    ("I copied https://example.com/a/b into docs/links.md today.", "Should I open it?", "Open it?"),
    // A date has no letter, so it is not a candidate.
    ("CI passed 11/12.", "Want me to merge it?", "Merge it?"),
  ])
  func leavesThePronounWithoutExactlyOneCandidate(_ previous: String, _ question: String, _ title: String) {
    #expect(OfferText.title(question: question, previous: previous) == title)
  }

  @Test func leavesThePronounWhenTheQuestionStartsItsParagraph() {
    #expect(OfferText.title(question: "Do you want me to delete it?", previous: nil) == "Delete it?")
  }

  @Test func aResolvedTitleOverTheLimitDropsTheNounFirst() {
    let name = "haacked/round-trip-drop-old-bounds-and-more-v2"

    let title = OfferText.title(question: "Should I delete it?", previous: "The `\(name)` branch still exists.")

    #expect(title == "Delete \(name)?")
  }

  @Test func aNameTooLongForTheTitleLeavesThePronoun() {
    let name = "haacked/round-trip-drop-old-bounds-and-the-rest-of-the-cleanup-v2"

    let title = OfferText.title(question: "Should I delete it?", previous: "The `\(name)` branch still exists.")

    #expect(title == "Delete it?")
  }

  @Test(arguments: [
    ("The `haacked/foo-v2` branch still exists.", "Should I delete it?"),
    ("I wrote **`cleanup.sh`** for the old builds.", "Want me to run it?"),
    ("The tag `v2.0` points at main.", "Should I push that?"),
  ])
  func theTitleIsPlainText(_ previous: String, _ question: String) {
    let title = OfferText.title(question: question, previous: previous)

    #expect(!title.contains("`"))
    #expect(!title.contains("*"))
  }
}

@Suite struct OfferTextYesNo {
  @Test(arguments: [
    "Want me to push?", "Do you want me to delete it?", "Should I update the error message?",
    "Want me to reorder the imports?", "Should I fix the color?",
  ])
  func aQuestionWithoutTheWordOrIsYesOrNo(_ question: String) {
    #expect(OfferText.isYesNo(question))
  }

  @Test(arguments: [
    "Should I push now or wait for CI?", "Want me to push, or keep it local?", "Want me to push (or wait)?",
    "Want me to push OR wait?", "Next, I'll update the docs.", "Want me to push.",
  ])
  func aChoiceOrAStatementIsNotYesOrNo(_ sentence: String) {
    #expect(!OfferText.isYesNo(sentence))
  }
}

/// The classifier and the title stripper must agree on which sentences are
/// offers, or a title could strip words from a question.
@Suite struct OfferTextParity {
  static let sentences: [(String, Bool)] = [
    ("Should I push?", true),
    ("SHOULD I push?", true),
    ("Should I\tpush?", true),
    ("Ok to merge?", true),
    ("Okay to merge?", true),
    ("Want to see it?", true),
    ("Do you want me to delete it?", true),
    ("Should it be renamed?", false),
    ("Should Ingrid review it?", false),
    ("Wanting more?", false),
    ("Want to?", false),
    ("Okay tomorrow?", false),
    ("Shall weigh in?", false),
  ]

  @Test(arguments: sentences)
  func classifyFindsAnOfferExactlyWhenTheOfferPrefixDoes(_ sentence: String, _ isOffer: Bool) {
    var classified = false
    if case .offer = Attention.classify(sentence) { classified = true }

    #expect(classified == isOffer)
    #expect((Attention.offerPrefix(sentence) != nil) == isOffer)
  }

  @Test(arguments: sentences)
  func theTitleStripsExactlyTheOffers(_ sentence: String, _ isOffer: Bool) {
    let title = OfferText.title(question: sentence, previous: nil)

    #expect((title != sentence) == isOffer, "\(title)")
  }
}
