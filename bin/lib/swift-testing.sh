# Sets `args` to the flags that swift needs to find Swift Testing in the
# active developer directory. bin/test and bin/test-gui source it.
#
# The Command Line Tools' build system can leave out the folder that holds
# Swift Testing's macro plugin. SwiftPM's native build system, the default
# before Swift 6.4, looks for Testing.framework only in
# <dev>/Developer/Library/Frameworks. The Command Line Tools keep it in
# <dev>/Library/Developer/Frameworks. Testing.framework loads
# lib_TestingInterop.dylib, which the Command Line Tools keep in
# <dev>/Library/Developer/usr/lib. The rpaths in Testing.framework do not
# reach that folder.

dev="${DEVELOPER_DIR:-$(xcode-select -p)}"
plugins="$dev/usr/lib/swift/host/plugins/testing"
clt_frameworks="$dev/Library/Developer/Frameworks"
clt_framework="$clt_frameworks/Testing.framework"
clt_lib="$dev/Library/Developer/usr/lib"
args=()
if [ -d "$plugins" ]; then args+=(-Xswiftc -plugin-path -Xswiftc "$plugins"); fi
if [ -e "$clt_framework" ]; then
  args+=(-Xswiftc -F -Xswiftc "$clt_frameworks" -Xlinker -rpath -Xlinker "$clt_frameworks")
fi
if [ -e "$clt_lib/lib_TestingInterop.dylib" ]; then args+=(-Xlinker -rpath -Xlinker "$clt_lib"); fi

require_swift_testing() {
  if [ -e "$clt_framework" ] ||
    [ -e "$dev/Platforms/MacOSX.platform/Developer/Library/Frameworks/Testing.framework" ]; then
    return 0
  fi
  echo "The tests need Swift Testing, which comes with Xcode 16 or later and with its Command Line Tools." >&2
  echo "The developer directory $dev has no Testing.framework." >&2
  echo "Install one of them, then select it with xcode-select -s or DEVELOPER_DIR." >&2
  exit 1
}
