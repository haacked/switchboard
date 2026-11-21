# shellcheck shell=bash
# Sets `args` to the flags that swift needs to find Swift Testing in the
# active developer directory, and defines build_tests and list_tests.
# bin/test, bin/test-gui, and CI source it.
#
# The Command Line Tools' build system can leave out the folder that holds
# Swift Testing's macro plugin. SwiftPM's native build system, the default
# before Swift 6.4, looks for Testing.framework only in
# <dev>/Developer/Library/Frameworks. The Command Line Tools keep it in
# <dev>/Library/Developer/Frameworks. Testing.framework loads
# lib_TestingInterop.dylib, which the Command Line Tools keep in
# <dev>/Library/Developer/usr/lib. The rpaths in Testing.framework do not
# reach that folder.

# Scripts and tests source this file from other folders, so the path to
# swiftpm is absolute.
swiftpm="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/swiftpm"

# xcode-select -p reads DEVELOPER_DIR. It resolves an Xcode app path to the
# app's Contents/Developer folder, as swift does.
dev="$(xcode-select -p)"
plugins="$dev/usr/lib/swift/host/plugins/testing"
clt_frameworks="$dev/Library/Developer/Frameworks"
clt_framework="$clt_frameworks/Testing.framework"
xcode_framework="$dev/Platforms/MacOSX.platform/Developer/Library/Frameworks/Testing.framework"
clt_lib="$dev/Library/Developer/usr/lib"
args=()
if [ -d "$plugins" ]; then args+=(-Xswiftc -plugin-path -Xswiftc "$plugins"); fi
if [ -e "$clt_framework" ]; then
  args+=(-Xswiftc -F -Xswiftc "$clt_frameworks" -Xlinker -rpath -Xlinker "$clt_frameworks")
fi
if [ -e "$clt_lib/lib_TestingInterop.dylib" ]; then args+=(-Xlinker -rpath -Xlinker "$clt_lib"); fi

require_swift_testing() {
  if [ -e "$clt_framework" ] || [ -e "$xcode_framework" ]; then
    return 0
  fi
  echo "The tests need Swift Testing, which comes with Xcode 16 or later and with its Command Line Tools." >&2
  echo "The developer directory $dev has no Testing.framework." >&2
  echo "Install one of them, then select it with xcode-select -s or DEVELOPER_DIR." >&2
  exit 1
}

# Warns on stderr when the selected Swift Testing ignores
# SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH, as the one in Xcode 26.0
# (Swift 6.2) does. That Swift Testing starts every test at once. Tests with a
# time limit then fail under load. A Swift Testing that reads the
# variable holds its name as a string. The check prints nothing when it finds
# no Testing binary.
warn_if_tests_start_at_once() {
  local binary
  for binary in "$clt_framework/Testing" "$xcode_framework/Testing"; do
    [ -f "$binary" ] || continue
    if ! LC_ALL=C grep -qaF SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH "$binary"; then
      echo "bin/test: the Swift Testing in $dev starts every test at once, so tests with a time limit can fail under load. Select an Xcode with Swift 6.3 or later with xcode-select -s." >&2
    fi
    return 0
  done
}

build_tests() {
  "$swiftpm" build --build-tests ${args[@]+"${args[@]}"}
}

# build_test_bundles <test-target>…
# Builds only the named test targets' bundles, and what each one depends on,
# including the executables it runs. The other bundles keep whatever the last
# build left in them, so a caller runs only the tests of the targets it names.
# swift build honors only the last --product it is given, so each bundle gets
# its own build.
build_test_bundles() {
  local target
  for target in "$@"; do
    "$swiftpm" build --product "$target" ${args[@]+"${args[@]}"}
  done
}

# test_bundles_exist <test-target>…
# Succeeds when the build folder holds a bundle of its own for each named test
# target. swift test --skip-build fails when any test target's bundle is
# missing, so build_test_bundles is safe only after this succeeds. A new
# worktree has no bundles. SwiftPM's native build system, the default before
# Swift 6.4, makes one bundle for all test targets and no product for each, so
# this fails there too.
test_bundles_exist() {
  local bin target
  bin=$(swift build --show-bin-path) || return 1
  for target in "$@"; do
    [ -e "$bin/$target.xctest" ] || return 1
  done
}

# Prints one line per test, such as SwitchboardCoreTests.FooTests/bar(), from
# the last build.
list_tests() {
  swift test list --skip-build | grep /
}
