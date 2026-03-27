#!/bin/bash

# AudioProfiles Build Script
# Builds the AudioServerPlugin driver, embeds it in the app bundle, then
# optionally deploys to /Applications.
#
# Works from the main repo or any git worktree.
#
# Usage: ./build.sh [--release] [--deploy] [--kill-only] [--driver-only] [--no-driver]

set -euo pipefail

export SWIFT_DISABLE_MACRO_PLUGIN_EXECUTION=1

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Resolve repo roots ───────────────────────────────────────────────────────
# SCRIPT_DIR is where this script lives (always the main repo).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# WORK_DIR is where xcodebuild runs from — either CWD (if it contains the
# .xcodeproj) or the main repo.  This lets worktrees work: the app project
# lives in the worktree, but the driver project only exists in the main repo.
if [[ -d "${PWD}/${APP_PROJECT_NAME:-AudioProfiles}.xcodeproj" ]]; then
    WORK_DIR="$PWD"
elif [[ -d "${SCRIPT_DIR}/AudioProfiles.xcodeproj" ]]; then
    WORK_DIR="$SCRIPT_DIR"
else
    # Last resort: git toplevel
    WORK_DIR="$(git rev-parse --show-toplevel 2>/dev/null || echo "$SCRIPT_DIR")"
fi

# Driver always lives in the main repo (worktrees don't copy it)
MAIN_REPO="$SCRIPT_DIR"

# ── Configuration ─────────────────────────────────────────────────────────────
APP_PROJECT_NAME="AudioProfiles"
APP_SCHEME="AudioProfiles"

DRIVER_PROJECT_DIR="${MAIN_REPO}/AudioProfilesDriver"
DRIVER_PROJECT_NAME="AudioProfilesDriver"
DRIVER_SCHEME="AudioProfilesDriver"
DRIVER_BUNDLE_NAME="AudioProfilesDriver.driver"

BUILD_CONFIG="Debug"
DEPLOY_TO_APPLICATIONS=false
KILL_EXISTING=false
EXIT_AFTER_KILL=false
DRIVER_ONLY=false
SKIP_DRIVER=false
NOTARIZE=false

DERIVED_DATA_PATH="${WORK_DIR}/build/DerivedData"

# Resolve the best available signing identity from the local keychain.
# Prefer "Developer ID Application" (passes Gatekeeper for HAL plugins),
# fall back to "Apple Development" (development only), then ad-hoc (-).
SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"Developer ID Application[^"]*"' | head -n 1 | tr -d '"' || true)
if [ -z "${SIGN_IDENTITY}" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -o '"Apple Development[^"]*"' | head -n 1 | tr -d '"' || true)
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

if [[ "${SIGN_IDENTITY}" == *"Developer ID Application"* ]]; then
    echo "[INFO] Signing with Developer ID (Gatekeeper-compatible)"
elif [[ "${SIGN_IDENTITY}" == *"Apple Development"* ]]; then
    echo "[WARNING] Signing with Apple Development cert — install will add spctl rule to allow HAL loading"
else
    echo "[WARNING] No signing cert found — using ad-hoc signing (driver won't load in coreaudiod)"
fi

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
AudioProfiles Build Script

Builds the AudioServerPlugin driver first, embeds it into the app bundle,
then optionally deploys to /Applications.

Works from the main repo or any git worktree.

Usage: $0 [OPTIONS]

Options:
  --release       Build with Release configuration (default: Debug)
  --deploy        Build Release, copy to /Applications, relaunch (implies --release)
  --no-driver     Skip driver build; reuse the last-built driver from the main repo
  --driver-only   Build only the AudioServerPlugin driver bundle
  --kill-only     Stop running AudioProfiles instances only
  -h, --help      Show this help

Examples:
  $0                   # Debug build of driver + app
  $0 --release         # Release build of driver + app
  $0 --deploy          # Release build, deploy to /Applications, relaunch
  $0 --deploy --no-driver  # Deploy app only, skip driver rebuild
  $0 --driver-only     # Just (re)build the driver .driver bundle
  $0 --kill-only       # Stop running app
EOF
}

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)    BUILD_CONFIG="Release"; shift ;;
        --deploy)     BUILD_CONFIG="Release"; DEPLOY_TO_APPLICATIONS=true; KILL_EXISTING=true; shift ;;
        --notarize)   BUILD_CONFIG="Release"; NOTARIZE=true; shift ;;
        --no-driver)  SKIP_DRIVER=true; shift ;;
        --driver-only) DRIVER_ONLY=true; shift ;;
        --kill-only)  KILL_EXISTING=true; EXIT_AFTER_KILL=true; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) echo -e "${RED}Unknown option: $1${NC}"; usage; exit 1 ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
print_status()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
print_step()    { echo -e "${CYAN}[STEP]${NC} $1"; }

# ── Kill existing instances ───────────────────────────────────────────────────
kill_app_processes() {
    print_status "Checking for running ${APP_PROJECT_NAME} processes..."
    local pids
    pids=$(pgrep -if "${APP_PROJECT_NAME}" || true)

    if [[ -n "$pids" ]]; then
        print_warning "Found running processes: $pids"
        pkill -if "${APP_PROJECT_NAME}" || true
        sleep 1
        local remaining
        remaining=$(pgrep -if "${APP_PROJECT_NAME}" || true)
        if [[ -n "$remaining" ]]; then
            pkill -9 -if "${APP_PROJECT_NAME}" || true
            sleep 1
        fi
        print_success "Existing processes terminated."
    else
        print_status "No running instances detected."
    fi
}

# ── Driver build ──────────────────────────────────────────────────────────────
build_driver() {
    print_step "Building AudioServerPlugin driver (${BUILD_CONFIG})..."

    set +o pipefail
    xcodebuild \
        -project "${DRIVER_PROJECT_DIR}/${DRIVER_PROJECT_NAME}.xcodeproj" \
        -scheme  "${DRIVER_SCHEME}" \
        -configuration "${BUILD_CONFIG}" \
        -derivedDataPath "${DERIVED_DATA_PATH}" \
        ONLY_ACTIVE_ARCH=YES \
        CODE_SIGN_IDENTITY="${SIGN_IDENTITY}" \
        build 2>&1 | grep -E '(error:|warning:|BUILD SUCCEEDED|BUILD FAILED)'
    local xcode_exit=${PIPESTATUS[0]}
    set -o pipefail
    if [[ $xcode_exit -ne 0 ]]; then
        print_error "Driver build failed (xcodebuild exit $xcode_exit)"
        exit 1
    fi

    local driver_path
    driver_path=$(find_driver_bundle)
    if [[ ! -d "$driver_path" ]]; then
        print_error "Driver build produced no output at expected path: $driver_path"
        exit 1
    fi

    print_success "Driver built: $driver_path"
}

find_driver_bundle() {
    local products="${DERIVED_DATA_PATH}/Build/Products"
    local expected="${products}/${BUILD_CONFIG}/${DRIVER_BUNDLE_NAME}"

    if [[ -d "$expected" ]]; then
        echo "$expected"
        return 0
    fi

    # Also check the main repo's DerivedData (for --no-driver reuse)
    local main_expected="${MAIN_REPO}/build/DerivedData/Build/Products/${BUILD_CONFIG}/${DRIVER_BUNDLE_NAME}"
    if [[ -d "$main_expected" ]]; then
        echo "$main_expected"
        return 0
    fi

    # Fallback: search recursively (handles multi-arch build paths)
    local found
    found=$(find "$products" -type d -name "${DRIVER_BUNDLE_NAME}" 2>/dev/null | head -n 1)
    echo "$found"
}

# ── Main app build ────────────────────────────────────────────────────────────
build_app() {
    print_step "Building ${APP_PROJECT_NAME} (${BUILD_CONFIG}) from ${WORK_DIR}..."

    # Extract DEVELOPMENT_TEAM from the main repo's project if not set in the worktree
    local dev_team=""
    dev_team=$(grep -m1 'DEVELOPMENT_TEAM' "${MAIN_REPO}/${APP_PROJECT_NAME}.xcodeproj/project.pbxproj" \
        | sed 's/.*= *\(.*\);/\1/' | tr -d ' ' || true)

    set +o pipefail
    xcodebuild \
        -project "${WORK_DIR}/${APP_PROJECT_NAME}.xcodeproj" \
        -scheme  "${APP_SCHEME}" \
        -configuration "${BUILD_CONFIG}" \
        -derivedDataPath "${DERIVED_DATA_PATH}" \
        ONLY_ACTIVE_ARCH=YES \
        CODE_SIGN_IDENTITY="${SIGN_IDENTITY}" \
        CODE_SIGN_STYLE=Manual \
        ${dev_team:+DEVELOPMENT_TEAM="${dev_team}"} \
        build 2>&1 | grep -E '(error:|warning:|BUILD SUCCEEDED|BUILD FAILED)'
    local xcode_exit=${PIPESTATUS[0]}
    set -o pipefail
    if [[ $xcode_exit -ne 0 ]]; then
        print_error "App build failed (xcodebuild exit $xcode_exit)"
        exit 1
    fi
    print_success "App build completed."
}

find_app_bundle() {
    local products="${DERIVED_DATA_PATH}/Build/Products"
    local expected="${products}/${BUILD_CONFIG}/${APP_PROJECT_NAME}.app"

    if [[ -d "$expected" ]]; then
        echo "$expected"
        return 0
    fi

    local found
    found=$(find "$products" -type d -name "${APP_PROJECT_NAME}.app" 2>/dev/null | head -n 1)
    echo "$found"
}

# ── Embed driver into app bundle ──────────────────────────────────────────────
# The driver lives at:  AudioProfiles.app/Contents/Resources/AudioProfilesDriver.driver
# EQInstallationService finds it with:
#   Bundle.main.url(forResource:"AudioProfilesDriver", withExtension:"driver")
#
# After copying we re-sign the bundle so codesign stays valid.
embed_driver_in_app() {
    local driver_path
    driver_path=$(find_driver_bundle)
    if [[ ! -d "$driver_path" ]]; then
        print_error "Cannot embed driver — bundle not found. Did the driver build succeed?"
        exit 1
    fi

    local app_path
    app_path=$(find_app_bundle)
    if [[ ! -d "$app_path" ]]; then
        print_error "Cannot embed driver — app bundle not found."
        exit 1
    fi

    local resources_dir="${app_path}/Contents/Resources"
    local dest="${resources_dir}/${DRIVER_BUNDLE_NAME}"

    print_step "Embedding driver into app bundle..."
    print_status "  driver: $driver_path"
    print_status "  dest:   $dest"

    mkdir -p "$resources_dir"
    rm -rf "$dest"
    ditto "$driver_path" "$dest"
    print_success "Driver embedded."

    # Re-sign the app bundle after modification.
    # Debug → ad-hoc ("-"); Release → use signing identity from Xcode settings.
    resign_app "$app_path"
}

resign_app() {
    local app_path="$1"
    print_step "Re-signing app bundle..."

    if [[ "$BUILD_CONFIG" == "Release" ]]; then
        print_status "  Signing identity: ${SIGN_IDENTITY}"
        codesign --force --deep --sign "${SIGN_IDENTITY}" --timestamp "$app_path"
    else
        # Debug → ad-hoc signing is fine for local development
        codesign --force --deep --sign "-" "$app_path"
    fi

    print_success "App bundle re-signed."
}

# ── Notarize driver bundle ────────────────────────────────────────────────────
# Requires:
#   - Developer ID Application cert (already in keychain)
#   - An app-specific password stored in keychain under the label "notarytool-password"
#     Create one at: https://appleid.apple.com/account/manage → App-Specific Passwords
#     Store it once with: xcrun notarytool store-credentials "notarytool-password"
#       --apple-id "your@apple.com" --team-id "332PZ42P4P" --password "<app-specific-password>"
notarize_driver() {
    local driver_path="$1"

    print_step "Notarizing driver bundle…"

    if [[ "${SIGN_IDENTITY}" != *"Developer ID Application"* ]]; then
        print_error "Notarization requires a 'Developer ID Application' certificate."
        print_status "Current identity: ${SIGN_IDENTITY}"
        exit 1
    fi

    local zip_path="/tmp/AudioProfilesDriver-notarize.zip"
    rm -f "$zip_path"

    print_status "Creating ZIP for notarization submission…"
    ditto -c -k --keepParent "$driver_path" "$zip_path"

    print_status "Submitting to Apple Notary Service (this may take 1-5 minutes)…"
    xcrun notarytool submit "$zip_path" \
        --keychain-profile "notarytool-password" \
        --wait \
        --timeout 600

    print_status "Stapling notarization ticket to driver…"
    xcrun stapler staple "$driver_path"

    rm -f "$zip_path"
    print_success "Driver notarized and stapled."

    # Verify
    if spctl --assess --verbose=2 "$driver_path" 2>&1 | grep -q "accepted"; then
        print_success "Gatekeeper assessment: ACCEPTED"
    else
        print_warning "Gatekeeper assessment still shows rejected — notarization may be propagating."
        spctl --assess --verbose=2 "$driver_path" 2>&1 || true
    fi
}

# ── Install driver to HAL ─────────────────────────────────────────────────────
# Copies the built driver to /Library/Audio/Plug-Ins/HAL/ and restarts coreaudiod
# so the new driver code is loaded. Requires admin privileges.
install_driver_to_hal() {
    local driver_path
    driver_path=$(find_driver_bundle)
    local hal_dir="/Library/Audio/Plug-Ins/HAL"
    local hal_dest="${hal_dir}/AudioProfilesDriver.driver"

    # Only install if the driver already exists in HAL (i.e., was previously installed)
    if [[ ! -d "$hal_dest" ]]; then
        print_status "Driver not installed in HAL — skipping (use app UI to install first time)"
        return 0
    fi

    print_step "Updating driver in ${hal_dir} and restarting coreaudiod..."
    osascript -e "do shell script \"rm -rf '${hal_dest}' && ditto '${driver_path}' '${hal_dest}' && killall coreaudiod\" with administrator privileges"
    # Give coreaudiod a moment to restart and load the new driver
    sleep 1
    print_success "Driver updated in HAL and coreaudiod restarted."
}

# ── Deploy ────────────────────────────────────────────────────────────────────
deploy_to_applications() {
    local app_path
    app_path=$(find_app_bundle)
    if [[ ! -d "$app_path" ]]; then
        print_error "No built app found to deploy."
        exit 1
    fi

    print_step "Deploying to /Applications/${APP_PROJECT_NAME}.app ..."
    osascript -e "do shell script \"rm -rf '/Applications/${APP_PROJECT_NAME}.app' && cp -R '$app_path' '/Applications/'\" with administrator privileges"
    print_success "Deployed to /Applications/${APP_PROJECT_NAME}.app"
}

launch_app() {
    print_status "Launching ${APP_PROJECT_NAME}..."
    open "/Applications/${APP_PROJECT_NAME}.app"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   AudioProfiles Build Script             ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    print_status "Configuration : ${BUILD_CONFIG}"
    print_status "Work dir      : ${WORK_DIR}"
    print_status "Main repo     : ${MAIN_REPO}"
    print_status "Skip driver   : ${SKIP_DRIVER}"
    print_status "Driver only   : ${DRIVER_ONLY}"
    print_status "Deploy        : ${DEPLOY_TO_APPLICATIONS}"
    echo ""

    if [[ "$KILL_EXISTING" == true ]]; then
        kill_app_processes
        [[ "$EXIT_AFTER_KILL" == true ]] && { print_success "Kill-only completed."; return 0; }
    fi

    mkdir -p "${DERIVED_DATA_PATH}"

    # Build driver (unless --no-driver)
    if [[ "$SKIP_DRIVER" != true ]]; then
        build_driver
    else
        print_status "Skipping driver build (--no-driver)"
    fi

    if [[ "$DRIVER_ONLY" == true ]]; then
        print_success "Driver-only build complete."
        local driver_path
        driver_path=$(find_driver_bundle)
        print_status "Driver bundle: $driver_path"
        return 0
    fi

    # Build the main app
    build_app

    # Optionally notarize the driver before embedding
    if [[ "$NOTARIZE" == true ]]; then
        local driver_path
        driver_path=$(find_driver_bundle)
        notarize_driver "$driver_path"
    fi

    # Embed the driver .driver bundle into the app's Resources
    embed_driver_in_app

    if [[ "$DEPLOY_TO_APPLICATIONS" == true ]]; then
        # If the driver was rebuilt, install it to HAL and restart coreaudiod
        if [[ "$SKIP_DRIVER" != true ]]; then
            install_driver_to_hal
        fi
        deploy_to_applications
        launch_app
    else
        local app_path
        app_path=$(find_app_bundle)
        echo ""
        print_success "Build complete."
        print_status "App bundle  : $app_path"
        print_status "Run with    : open \"$app_path\""
    fi

    echo ""
    print_success "All done."
}

main "$@"
