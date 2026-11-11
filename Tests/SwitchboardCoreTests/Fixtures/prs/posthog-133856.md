## Problem

- When a flag targets a dynamic cohort with an unsupported group type such as `XOR`, the result depends on child order.
- `OR[XOR, match]` fails evaluation, while `OR[match, XOR]` matches.
- [sdk-specs#207](https://github.com/PostHog/sdk-specs/pull/207) proposed copying this into the SDK spec. This PR fixes the service instead.

Closes #133410

## Changes

- An unsupported group's membership is now unknown, and a sibling decides the result in either order:

| Children | Result |
| --- | --- |
| `OR[X,T]`, `OR[T,X]` | match |
| `AND[X,F]`, `AND[F,X]` | no match |
| `OR[X,F]`, `AND[X,T]`, lone `X` | error, as before |

- A cohort that references a cohort with unknown membership follows the same rule. `not_in` and negation don't turn unknown into a match.
- A root group with the legacy type `property` now evaluates as AND instead of failing.
- Malformed leaves and the depth limit still fail the cohort.

## How did you test this code?

**Test rationale:** new `cohort_operations` cases cover both child orders, nesting, empty groups, referenced cohorts, and negation. The order cases failed before the fix. Not run: the database-backed suites.

## Release status

- No feature flag controls this change <!-- release-status: no-feature-flag -->

## Docs update

- None.

## 🤖 Agent context

**Autonomy:** Human-driven (agent-assisted)

**Agent:** Claude Code, Claude Fable 5.2 and Claude Opus 5.5

**Skills:** `/writing-tests`, `/writing-code-comments`, `/simplify`, `/writing-pr-descriptions`, `/create-pr`, `/plain-writing`

<details>
<summary>More context for AI agents</summary>

- **Session:** https://claude.ai/code/session_01AovXvZ9CFnkzDPEs2L2DE6, cargo test and clippy, plus simplify and code-reviewer subagents
- **Decisions:** root and nested groups share one struct with an enum type, so the two parse paths can't disagree.
- **Decisions:** unsupported leaves such as behavioral filters stay a non-match, because the issue covers groups only.
- **Follow-ups:** SDKs can keep the spec from before sdk-specs#207, falling back to the server only when the result stays unknown.
- **Read closely:** `evaluate_group` and `evaluate_dynamic_cohorts` in `rust/feature-flags/src/cohorts/cohort_operations.rs`.

</details>

https://claude.ai/code/session_01AovXvZ9CFnkzDPEs2L2DE6

