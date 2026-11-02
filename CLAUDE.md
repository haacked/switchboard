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
