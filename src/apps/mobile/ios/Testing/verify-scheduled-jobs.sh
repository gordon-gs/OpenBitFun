#!/usr/bin/env bash
# Verify the iOS "scheduled jobs" panel end to end.
#
# Run on macOS with Xcode installed (this repository has no iOS CI job; the
# Mobile Package workflow only builds Android). From the repository root:
#
#   bash src/apps/mobile/ios/Testing/verify-scheduled-jobs.sh
#   bash src/apps/mobile/ios/Testing/verify-scheduled-jobs.sh --with-jvm-tests
#
# Stages:
#   1. locate Xcode and a JDK (override with DEVELOPER_DIR / JAVA_HOME)
#   2. rebuild the shared Kotlin core into OpenBitFunMobileCore.xcframework
#      (Xcode links the checked-in framework; Kotlin changes are NOT picked up
#      by an Xcode build alone)
#   3. build the iOS app for the simulator without code signing
#   4. optional: run the JVM tests of the shared core (needs an Android SDK,
#      because the module configures the Android target)
set -euo pipefail

WITH_JVM_TESTS=0
for arg in "$@"; do
  case "$arg" in
    --with-jvm-tests) WITH_JVM_TESTS=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SHARED_DIR="$(cd "$IOS_DIR/../shared" && pwd)"
REPO_ROOT="$(cd "$IOS_DIR/../../../.." && pwd)"

stage() { printf '\n=== %s ===\n' "$1"; }
fail() { printf '\nFAILED: %s\n' "$1" >&2; exit 1; }

stage "1/4 toolchain"
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  for candidate in "$HOME/Downloads/Xcode.app/Contents/Developer" "/Applications/Xcode.app/Contents/Developer"; do
    if [[ -x "$candidate/usr/bin/xcodebuild" ]]; then
      export DEVELOPER_DIR="$candidate"
      break
    fi
  done
fi
[[ -n "${DEVELOPER_DIR:-}" && -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]] \
  || fail "no Xcode found; set DEVELOPER_DIR to .../Xcode.app/Contents/Developer"
echo "DEVELOPER_DIR=$DEVELOPER_DIR"
"$DEVELOPER_DIR/usr/bin/xcodebuild" -version

if [[ -z "${JAVA_HOME:-}" || ! -x "${JAVA_HOME}/bin/java" ]]; then
  for candidate in \
    "/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home" \
    "/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
    "$(/usr/libexec/java_home -v 17 2>/dev/null || true)"; do
    if [[ -n "$candidate" && -x "$candidate/bin/java" ]]; then
      export JAVA_HOME="$candidate"
      break
    fi
  done
fi
[[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]] \
  || fail "no JDK found; set JAVA_HOME (the Kotlin build needs 17+)"
export PATH="$JAVA_HOME/bin:$PATH"
java -version

stage "2/4 shared Kotlin core -> XCFramework"
cd "$SHARED_DIR"
./gradlew --console=plain :core-feature:assembleOpenBitFunMobileCoreDebugXCFramework \
  || fail "Kotlin/XCFramework build (compile errors in core-feature land here)"

stage "3/4 iOS app build (simulator, no signing)"
cd "$IOS_DIR"
"$DEVELOPER_DIR/usr/bin/xcodebuild" \
  -project OpenBitFun.xcodeproj \
  -scheme OpenBitFun \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/OpenBitFun-iOS-Derived \
  CODE_SIGNING_ALLOWED=NO \
  build \
  || fail "Swift/Xcode build (added files or Swift errors land here)"

if [[ "$WITH_JVM_TESTS" == "1" ]]; then
  stage "4/4 shared core JVM tests"
  cd "$SHARED_DIR"
  ./gradlew --console=plain :core-feature:jvmTest \
    || fail "JVM tests (needs ANDROID_HOME or local.properties sdk.dir)"
else
  stage "4/4 skipped shared core JVM tests (pass --with-jvm-tests to run)"
fi

cat <<'DONE'

=== result ===
Build chain is green. Manual check on a device or simulator:
  1. sign in and connect a desktop host that has scheduled jobs
  2. Settings -> 自动化 -> 定时任务
  3. expect the host's jobs, with schedule, target and next-run text
  4. toggle one off, then confirm the desktop UI shows it disabled
  5. delete one, then confirm the row disappears here and on the host
DONE
