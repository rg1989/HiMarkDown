#!/usr/bin/env bash
# Headless smoke test for HiMarkDown.
# Builds, launches the app with a fixture markdown, captures unified-log output
# from the app + WebKit helpers for a few seconds, takes a screenshot of the
# main window, quits the app, and greps the captured log for known bad patterns.
#
# Exit status:
#   0  no bad patterns found
#   1  at least one bad pattern found (details printed)
#   2  build / launch infrastructure failure
#
# Outputs:
#   tools/smoke.log       full captured unified log
#   tools/smoke.png       screenshot of the running app (if a window was found)
set -u
set -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DD="$ROOT/.build/xcode-dd"
APP_NAME="HiMarkDown"
SCHEME="HiMarkDown"
PROJECT="HiMarkDown.xcodeproj"
FIXTURE="${SMOKE_FIXTURE:-$ROOT/fixtures/sample.md}"
LOG="$ROOT/tools/smoke.log"
START_MODE="${SMOKE_MODE:-html}"
SHOT="$ROOT/tools/smoke-${START_MODE}.png"

mkdir -p "$DD"
rm -f "$LOG" "$SHOT"

echo "==> Building $SCHEME (Debug, macOS)"
if ! xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DD" \
    build >/tmp/smoke-build.log 2>&1; then
    echo "BUILD FAILED — last 60 lines:"
    tail -60 /tmp/smoke-build.log
    exit 2
fi

APP_BUNDLE="$DD/Build/Products/Debug/$APP_NAME.app"
if [ ! -d "$APP_BUNDLE" ]; then
    echo "Could not find built app at $APP_BUNDLE"
    exit 2
fi
echo "    built: $APP_BUNDLE"

# Asset shape sanity: WebEditorView loads Bundle.main.url(forResource:"index",
# withExtension:"html", subdirectory:"Web"). If those files were copied flat
# into Resources/ instead of Resources/Web/, the WebView shows blank without
# any Swift error.
echo "==> Checking bundled Web assets"
WEB_INDEX="$APP_BUNDLE/Contents/Resources/Web/index.html"
WEB_JS="$APP_BUNDLE/Contents/Resources/Web/editor.js"
ASSET_FAIL=0
for f in "$WEB_INDEX" "$WEB_JS"; do
    if [ -f "$f" ]; then
        echo "  ok:   $f"
    else
        echo "  FAIL: missing $f"
        ASSET_FAIL=1
    fi
done
if [ "$ASSET_FAIL" -ne 0 ]; then
    echo "Bundled Web/ folder is broken. WebView would render blank."
    exit 1
fi

# Make sure no stale instance is running.
killall "$APP_NAME" 2>/dev/null || true
sleep 0.3

echo "==> Starting unified-log stream"
LOGFILTER='(process == "'"$APP_NAME"'") OR (process == "com.apple.WebKit.WebContent") OR (process == "com.apple.WebKit.GPU") OR (process == "com.apple.WebKit.Networking") OR (subsystem == "dev.himarkdown.HiMarkDown")'
log stream --style compact --level debug --predicate "$LOGFILTER" >"$LOG" 2>&1 &
LOG_PID=$!
sleep 0.5

DEFAULT_MODE_KEY="defaultEditModeIsMarkdown"
DEFAULTS_DOMAIN="dev.himarkdown.HiMarkDown"

case "$START_MODE" in
    markdown) defaults write "$DEFAULTS_DOMAIN" "$DEFAULT_MODE_KEY" -bool true ;;
    html|*)   defaults write "$DEFAULTS_DOMAIN" "$DEFAULT_MODE_KEY" -bool false ;;
esac

SMOKE_DELAY="${SMOKE_DELAY:-6}"
SCENARIO_ARGS=""
for s in ${SMOKE_SCENARIOS:-}; do
    SCENARIO_ARGS="$SCENARIO_ARGS --himd-smoke-scenario=$s"
done
echo "==> Launching $APP_NAME with fixture: $FIXTURE  (mode=$START_MODE, self-quit=${SMOKE_DELAY}s, scenarios='${SMOKE_SCENARIOS:-none}')"
open -n -a "$APP_BUNDLE" --args "--himd-smoke=$SMOKE_DELAY" "--himd-smoke-file=$FIXTURE" $SCENARIO_ARGS

# Capture screenshot just before the app self-terminates, then wait it out.
sleep $((SMOKE_DELAY - 1))

echo "==> Inspecting window title (must reflect open file)"
TITLE="$(/usr/bin/swift - <<'SWIFT'
import CoreGraphics
import Foundation
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { exit(0) }
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    let bounds = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    let h = bounds["Height"] ?? 0
    if owner == "HiMarkDown", layer == 0, h > 100 {
        print((w[kCGWindowName as String] as? String) ?? "")
        exit(0)
    }
}
SWIFT
)"
echo "    title: \"$TITLE\""
TITLE_FAIL=0
case "$TITLE" in
    *sample.md*) echo "  ok:   title contains fixture file name" ;;
    *) echo "  FAIL: title does not contain fixture file name"; TITLE_FAIL=1 ;;
esac

echo "==> Capturing screenshot"
# Use CoreGraphics window list (Screen Recording perm only, no Accessibility).
WINDOW_ID="$(/usr/bin/swift - <<'SWIFT'
import CoreGraphics
import Foundation
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { exit(0) }
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    let bounds = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    let h = bounds["Height"] ?? 0
    if owner == "HiMarkDown", layer == 0, h > 100 {
        if let id = w[kCGWindowNumber as String] as? Int {
            print(id)
            exit(0)
        }
    }
}
SWIFT
)"
if [ -n "$WINDOW_ID" ]; then
    echo "    window id: $WINDOW_ID"
    /usr/sbin/screencapture -o -l "$WINDOW_ID" "$SHOT" || true
fi
if [ ! -s "$SHOT" ]; then
    echo "    falling back to full-screen capture"
    /usr/sbin/screencapture -x "$SHOT" || true
fi

echo "==> Waiting for $APP_NAME self-quit"
QUIT_OK=0
# Wait up to 12s on top of the SMOKE_DELAY-1s already slept.
for i in $(seq 1 24); do
    sleep 0.5
    if ! pgrep -x "$APP_NAME" >/dev/null; then
        QUIT_OK=1
        break
    fi
done
if [ "$QUIT_OK" -ne 1 ]; then
    echo "  WARN: $APP_NAME never self-quit (smoke arm may not have fired; force-killing)"
    /usr/sbin/screencapture -x "$ROOT/tools/smoke-stuck.png" || true
    killall -9 "$APP_NAME" 2>/dev/null || true
fi
# Read the dirty result the app itself logged.
SMOKE_RESULT="$(grep 'HiMD-SMOKE-RESULT' "$LOG" | tail -1)"
echo "    $SMOKE_RESULT"
DIRTY_REGRESSION=0
case "$SMOKE_RESULT" in
    *isDirty=true*) DIRTY_REGRESSION=1 ;;
esac

SCENARIO_FAIL=0
if grep -q 'HiMD-SMOKE-SCENARIO' "$LOG"; then
    echo "==> Scenario summary"
    grep 'HiMD-SMOKE-SCENARIO' "$LOG" | sed 's/^/    /'
    if grep -q 'restoredOK=false\|redoOK=false' "$LOG"; then
        echo "  FAIL: undo/redo round-trip did not restore expected state"
        SCENARIO_FAIL=1
    fi
    if grep -q 'anchorOK=false' "$LOG"; then
        echo "  FAIL: outline scroll did not land on the requested heading"
        SCENARIO_FAIL=1
    fi
    if grep -q 'parityOK=false' "$LOG"; then
        echo "  FAIL: cross-mode scroll parity did not preserve heading anchor"
        SCENARIO_FAIL=1
    fi
fi

# Stop log stream.
kill "$LOG_PID" 2>/dev/null || true
wait "$LOG_PID" 2>/dev/null || true

echo "==> Grading log ($LOG)"

# Patterns that would indicate the bug we just fixed coming back, or any
# new-found launch / runtime failure. Add to this list as we discover more.
BAD_PATTERNS=(
    'does not have permission to communicate with network resources'
    'WebProcessProxy::didFinishLaunching: Invalid connection identifier'
    'processDidTerminate: \(pid 0\), reason=Crash'
    'GPUProcessProxy::gpuProcessExited: reason=Crash'
    'Publishing changes from within view updates'
    'Fatal error:'
    'Thread .* Crashed'
    'reached the maximum number of attempts'
    'HiMD-JS-ERROR'
)

FAIL=0
for pat in "${BAD_PATTERNS[@]}"; do
    if grep -E -q "$pat" "$LOG"; then
        FAIL=1
        echo "  FAIL: $pat"
        grep -E "$pat" "$LOG" | head -3 | sed 's/^/      > /'
    else
        echo "  ok:   $pat"
    fi
done

if [ "${DIRTY_REGRESSION:-0}" -eq 1 ]; then
    FAIL=1
    echo "  FAIL: doc was marked dirty by passive open (save prompt blocked quit)"
fi
if [ "${TITLE_FAIL:-0}" -eq 1 ]; then
    FAIL=1
fi
if [ "${SCENARIO_FAIL:-0}" -eq 1 ]; then
    FAIL=1
fi

echo
if [ "$FAIL" -eq 0 ]; then
    echo "SMOKE TEST PASSED"
    echo "  log:        $LOG"
    echo "  screenshot: $SHOT"
    exit 0
else
    echo "SMOKE TEST FAILED — see $LOG"
    echo "  screenshot: $SHOT"
    exit 1
fi
