# Switchboard

A macOS app and background service that run many Claude Code sessions and show which ones need the user. See README.md for the user-facing description.

## Plan

The design plan is `~/dev/haacked/notes/Dev/repositories/haacked/switchboard/plans/switchboard.md`. Read it before starting work. It records the decisions, the measurements behind them, and the phases. Work starts with its Phase 0 tests.

## Names

- **Switchboard:** the app.
- **`sb`:** the CLI.
- **`sbd`:** the background service, a launchd agent.
- **`SB_SESSION_ID`:** the environment variable that each session gets.

## Constraints

- Swift for the app and the service.
- Sessions run the unmodified `claude` CLI under the user's Claude subscription. Never call the Claude API with a subscription login.
- Only Xcode's Command Line Tools are installed (Swift 6.4). The service, the CLI, and the app bundle build with SwiftPM.

## Tests

CI runs the full suite on every push to a PR, in the `swift-test` and `gui-test` jobs. About 15 sessions share this Mac, so a local full run repeats CI's work and slows the other sessions.

- Before you push, run `bin/test`. With no arguments it runs only the tests that your changes against `origin/main` can affect, and it prints what it picked and why. A change to `Sources/` leaves IntegrationTests to CI. Never run bare `swift test`, which runs every test and ignores the selection.
- After you push, wait for `swift-test` and `gui-test`, then fix what they report. The `ci-monitor` step of `/go` does the waiting.
- Run `bin/test --all` only to reproduce a CI failure, or for a change whose effects `bin/test` can't see, such as a test that reads a file at run time through a path the selection doesn't know about.

## Design before adding code

Before you implement a feature or fix, read the code it touches and ask whether the current design makes the change easy. If it doesn't, refactor first, then implement. Examples are a type or view that does two jobs, logic duplicated where the change would add a third copy, a missing abstraction the change would hard-code around, or a long function the change would make longer.

- Refactor only what the change touches or what makes it simpler. Don't clean up unrelated code.
- A refactor doesn't change behavior. Keep the tests passing, and put it in its own commit before the feature commits.
- If the refactor is large enough to review on its own, open it as a separate PR first and build the feature on top.
- In the plan, list the refactors as their own stage before the implementation stages.
- In the PR description, say what you restructured and why the feature needed it.
- In review, treat code that works around a design problem instead of fixing it as a finding.

## Branch upkeep and merging

Every session in this repo follows the `/go --yolo` workflow. Don't stop to ask about routine branch upkeep.

- When the PR conflicts with main or falls behind it, merge `origin/main` into the branch, resolve the conflicts, run the tests, push, and continue. Don't ask first.
- Never rebase a pushed branch, and never force-push.
- When `/go` is done, its merge gate passed, and CI is green, merge with `gh pr merge <n> --merge --match-head-commit <sha>`, where `<sha>` is the head commit that CI passed on. Never use `--admin` or `--auto`.
- If the merge gate or the merge command refuses, say so in one line and stop. Don't try another way to merge. The Manager merges finished Switchboard PRs.
