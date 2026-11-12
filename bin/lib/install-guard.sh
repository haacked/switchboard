# shellcheck shell=bash
# Defines require_current_main. bin/install sources it.
#
# bin/install replaces the installed app and restarts sbd, but an app that is
# already running keeps its old code. A build from a branch that lacks commits
# of origin/main can be older than the running app. That app then sends
# requests that the older sbd does not understand. bin/update fetches before
# it installs, and every worktree shares origin/main. A HEAD that contains
# origin/main therefore contains every main commit of the installed build.

# Returns 1 with a message on stderr unless the repository's HEAD contains
# origin/main.
require_current_main() {
  if ! git rev-parse --verify -q 'origin/main^{commit}' >/dev/null; then
    echo "Refusing to install: this checkout has no origin/main to compare against. Pass --force to install anyway." >&2
    return 1
  fi
  if ! git merge-base --is-ancestor origin/main HEAD; then
    echo "Refusing to install: HEAD lacks commits of origin/main, so this build can be older than the installed app. Merge origin/main first, or pass --force to install anyway." >&2
    return 1
  fi
}
