# shellcheck shell=bash
# bin/bundle, bin/install, and bin/update source it.
#
# bin/install replaces the installed app and restarts sbd, but an app that is
# already running keeps its old code. A build that lacks a commit of the
# installed build can be older than the running app. That app then sends
# requests that the older sbd does not understand. bin/bundle records the
# commit that it built in Info.plist, and the guard refuses a build that does
# not contain that commit.

build_commit_key=SBBuildCommit
# A build from uncommitted changes holds more than its commit, so no later
# commit can be shown to contain it.
build_dirty_key=SBBuildDirty

# Prints the commit that the app at `app` was built from. It prints nothing
# when the app is not installed or records no commit.
installed_build_commit() {
  /usr/libexec/PlistBuddy -c "Print :$build_commit_key" "$1/Contents/Info.plist" 2>/dev/null || true
}

# Refuses unless `rev` contains the commit of the app at `app`. An app that is
# not installed refuses nothing.
require_newer_than_installed() {
  local app=$1 rev=$2 plist="$1/Contents/Info.plist" installed status
  [ -e "$plist" ] || return 0
  installed=$(installed_build_commit "$app")
  if [ -z "$installed" ]; then
    echo "Refusing to install: $app records no build commit, so this build can be older. Pass --force to install anyway." >&2
    return 1
  fi
  if [ "$(/usr/libexec/PlistBuddy -c "Print :$build_dirty_key" "$plist" 2>/dev/null)" = true ]; then
    echo "Refusing to install: $app was built from uncommitted changes to $installed. Pass --force to install anyway." >&2
    return 1
  fi
  status=0
  git merge-base --is-ancestor "$installed" "$rev" 2>/dev/null || status=$?
  case $status in
    0) ;;
    1)
      echo "Refusing to install: $rev lacks $(git log -1 --format='%h "%s"' "$installed"), which $app was built from. Merge it first, or pass --force to install anyway." >&2
      return 1
      ;;
    *)
      echo "Refusing to install: this checkout does not have commit $installed, which $app was built from. Pass --force to install anyway." >&2
      return 1
      ;;
  esac
}
