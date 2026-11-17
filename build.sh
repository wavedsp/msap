#!/bin/bash
# Build script for MSap - macOS Speech Analysis Program
# Requires: macOS 12.0+, Xcode command line tools, CMake

set -e

usage()
{
    cat <<'USAGE'
Usage: ./build.sh [options]

  --arm         Apple silicon only, arm64
  --intel       Intel only, x86_64
  --universal   Both, one fat binary that runs on either Mac
  --xcode       Generate msap.xcodeproj for building and debugging in Xcode
  --clean       Delete the build directory first
  -h, --help    This message

Environment overrides: ARCH, BUILD_DIR, CONFIG, CMAKE_COMMAND, CTEST_COMMAND.

The default is this machine's own architecture, because it halves the build
time, but a one architecture build cannot catch the places where the two
differ - BOOL is 'bool' on arm64 and 'signed char' on x86_64, for one. Run
--universal before handing the code to an Intel Mac.
USAGE
}

# Default to the host architecture so this script does the right thing on an
# Intel Mac as well as on Apple silicon.
ARCH="${ARCH:-$(uname -m)}"
BUILD_DIR="${BUILD_DIR:-}"
CONFIG="${CONFIG:-Release}"
GENERATOR="Unix Makefiles"
XCODE=0
CLEAN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --arm)       ARCH="arm64" ;;
        --intel)     ARCH="x86_64" ;;
        --universal) ARCH="arm64;x86_64" ;;
        --xcode)     XCODE=1; GENERATOR="Xcode"; ARCH="arm64;x86_64" ;;
        --clean)     CLEAN=1 ;;
        -h|--help)   usage; exit 0 ;;
        *)           echo "Unknown option: $1"; usage; exit 1 ;;
    esac
    shift
done

if [ -z "$BUILD_DIR" ]; then
    if [ "$XCODE" -eq 1 ]; then BUILD_DIR="build-xcode"; else BUILD_DIR="build"; fi
fi

resolve_symlinks()
{
    local path="$1"
    local link
    local directory

    while [ -L "$path" ]; do
        directory="$(cd -P "$(dirname "$path")" && pwd)"
        link="$(readlink "$path")"
        case "$link" in
            /*) path="$link" ;;
            *)  path="$directory/$link" ;;
        esac
    done

    directory="$(cd -P "$(dirname "$path")" && pwd)"
    printf '%s/%s\n' "$directory" "$(basename "$path")"
}

if [ -z "${CMAKE_COMMAND:-}" ]; then
    CMAKE_COMMAND="$(type -P cmake || true)"
fi
if [ -z "$CMAKE_COMMAND" ]; then
    echo "CMake was not found. Install CMake or set CMAKE_COMMAND." >&2
    exit 1
fi

if [ "$CLEAN" -eq 1 ]; then
    rm -rf "$BUILD_DIR"
fi

echo "=== Building MSap ==="
echo "Architecture: $ARCH"
echo "Generator: $GENERATOR"
echo "Build directory: $BUILD_DIR"
echo "Configuration: $CONFIG"

# Configure
echo ""
echo "=== Configuring CMake ==="
"$CMAKE_COMMAND" -S . -B "$BUILD_DIR" \
  -G "$GENERATOR" \
  -DCMAKE_BUILD_TYPE="$CONFIG" \
  -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="12.0"

if [ "$XCODE" -eq 1 ]; then
    cat <<EOF

=== Xcode Project Ready ===
Project: $BUILD_DIR/msap.xcodeproj

To open:  open $BUILD_DIR/msap.xcodeproj
Then pick the msap scheme and Run. Breakpoints, the view debugger and
Instruments all work; the scheme is generated, so it is there on first open.

The project builds arm64 and x86_64. To debug one architecture, set it in
Product > Destination or edit the scheme.

The project is generated from CMakeLists.txt. Edit the CMake file, not the
project, or the next configure discards the change.
EOF
    exit 0
fi

# Build
echo ""
echo "=== Building ==="
"$CMAKE_COMMAND" --build "$BUILD_DIR" --config "$CONFIG" --parallel

# Test
echo ""
echo "=== Running Tests ==="
if [ -z "${CTEST_COMMAND:-}" ]; then
    CMAKE_REAL_PATH="$(resolve_symlinks "$CMAKE_COMMAND")"
    CTEST_COMMAND="$(dirname "$CMAKE_REAL_PATH")/ctest"
    if [ ! -x "$CTEST_COMMAND" ]; then
        CTEST_COMMAND="$(type -P ctest || true)"
    fi
fi
if [ -z "$CTEST_COMMAND" ] || [ ! -x "$CTEST_COMMAND" ]; then
    echo "CTest was not found beside CMake or on PATH. Set CTEST_COMMAND." >&2
    exit 1
fi
"$CTEST_COMMAND" --test-dir "$BUILD_DIR" -C "$CONFIG" --output-on-failure

# App location
APP_PATH="$BUILD_DIR/msap.app"
if [ -d "$APP_PATH" ]; then
    echo ""
    echo "=== Build Complete ==="
    echo "App: $APP_PATH"
    lipo -info "$APP_PATH/Contents/MacOS/msap" 2>/dev/null || true
    echo ""
    echo "To launch: open $APP_PATH"
    echo "To attach debugger: lldb $APP_PATH/Contents/MacOS/msap"
fi
