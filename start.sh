#!/bin/bash
# ==============================================================
# KanhaMusic - Startup Script for VPS & Servers
# ==============================================================
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

echo -e "\033[1;34m🎵 [KanhaMusic] Initializing Environment...\033[0m"

# .env is optional. PaaS platforms inject env vars directly, and the Go app
# reads .env itself without overriding variables already set.
if [[ ! -f ".env" && -f "sample.env" ]]; then
    cp sample.env .env
    echo -e "\033[1;33m⚠ Created .env from sample.env (injected env vars take priority)\033[0m"
fi

# 1. Go toolchain - bootstrap locally when the platform has no Go buildpack.
if ! command -v go >/dev/null 2>&1; then
    if [[ -x "$HOME/.local/go/bin/go" ]]; then
        export PATH="$HOME/.local/go/bin:$PATH"
    else
        GO_VER="$(grep -m1 '^go ' go.mod | awk '{print $2}')"
        GO_ARCH="$(uname -m)"
        case "$GO_ARCH" in
            x86_64)  GO_ARCH=amd64 ;;
            aarch64) GO_ARCH=arm64 ;;
        esac
        echo -e "\033[1;33m⚠ Go not found. Installing go${GO_VER} to \$HOME/.local/go...\033[0m"
        curl -fsSL "https://go.dev/dl/go${GO_VER}.linux-${GO_ARCH}.tar.gz" -o /tmp/kanha-go.tgz || exit 1
        mkdir -p "$HOME/.local"
        tar -C "$HOME/.local" -xzf /tmp/kanha-go.tgz || exit 1
        rm -f /tmp/kanha-go.tgz
        export PATH="$HOME/.local/go/bin:$PATH"
    fi
fi
echo -e "\033[1;32m✓ Go: $(go version | awk '{print $3}')\033[0m"

# 2. C compiler for CGO (ntgcalls). Some buildpack engines omit it.
if ! command -v gcc >/dev/null 2>&1; then
    echo -e "\033[1;33m⚠ gcc not found. Trying build-tools installer...\033[0m"
    bash "$DIR/install.sh" -b --quiet --skip-summary || true
fi
if ! command -v gcc >/dev/null 2>&1; then
    echo -e "\033[1;31m✗ gcc is required for CGO. Install build-essential and retry.\033[0m"
    exit 1
fi

# 3. Native libraries: ntgcalls static lib + TDLib shared lib.
if [[ ! -f "./libntgcalls.a" || ! -f "./ntgcalls/ntgcalls.h" || ! -f "./libtdjson.so.1.8.66" ]]; then
    echo -e "\033[1;33m⚠ Installing native libraries (ntgcalls, tdjson)...\033[0m"
    bash "$DIR/install.sh" -n -t --quiet --skip-summary || exit 1
fi

# 4. Build if the binary is missing.
if [[ ! -x "./app" ]]; then
    echo -e "\033[1;33m⚠ Compiled binary ./app not found, building...\033[0m"
    CGO_ENABLED=1 go build -trimpath -ldflags="-w -s" -o app ./cmd/app/ || exit 1
fi

# 5. Runtime tools provided by the platform buildpacks: ffmpeg, ffprobe, yt-dlp.
if ! command -v yt-dlp >/dev/null 2>&1 && [[ -x "$HOME/.local/bin/yt-dlp" ]]; then
    export PATH="$HOME/.local/bin:$PATH"
fi

# 6. Library paths for TDLib and NTGCalls.
export LD_LIBRARY_PATH="$DIR:/usr/local/lib:${LD_LIBRARY_PATH:-}"
if [[ -f "$DIR/libtdjson.so.1.8.66" ]]; then
    export TDJSON_PATH="$DIR/libtdjson.so.1.8.66"
elif [[ -f "$DIR/libtdjson.so" ]]; then
    export TDJSON_PATH="$DIR/libtdjson.so"
elif [[ -f "/usr/local/lib/libtdjson.so" ]]; then
    export TDJSON_PATH="/usr/local/lib/libtdjson.so"
fi

# 7. Run.
if [[ "${1:-}" == "--no-restart" ]]; then
    shift
    echo -e "\033[1;32m🚀 Starting KanhaMusic in direct mode...\033[0m"
    exec ./app "$@"
else
    echo -e "\033[1;32m🚀 Starting KanhaMusic (Auto-Restart Guard ON)...\033[0m"
    echo -e "Tip: To run in background, use \033[1;33mscreen -dmS kanha bash start.sh\033[0m or systemd"
    while true; do
        ./app "$@"
        EXIT_CODE=$?
        if [[ $EXIT_CODE -eq 127 ]]; then
            echo -e "\033[1;31m✗ ./app not found. Aborting restart loop.\033[0m"
            exit 127
        fi
        echo -e "\033[1;33m[KanhaMusic] Process stopped with exit code $EXIT_CODE. Restarting in 3 seconds... (Press Ctrl+C to abort)\033[0m"
        sleep 3
    done
fi
