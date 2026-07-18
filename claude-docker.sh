#!/bin/bash
set -e

# ── Persistent worker container ──────────────────────────────────────
# Load optional user-wide config; sets CLAUDE_* env vars used below.
# Generate a template with `make docker-config`.
if [ -f "$HOME/.claude/docker.env" ]; then
  # shellcheck disable=SC1091
  . "$HOME/.claude/docker.env"
fi

CLAUDE_CONTAINER_NAME="${CLAUDE_CONTAINER_NAME:-claude-worker}"
CLAUDE_PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/claude-projects}"
CLAUDE_DISPATCH_DIR="${CLAUDE_DISPATCH_DIR:-/tmp/claude-dispatch}"

# Handle worker lifecycle subcommands before any setup or image build.
case "$1" in
  --stop)
    if docker stop "$CLAUDE_CONTAINER_NAME" >/dev/null 2>&1; then
      echo "Claude worker stopped."
    else
      echo "No running worker."
    fi
    exit 0
    ;;
  --status)
    if docker ps --filter "name=^${CLAUDE_CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "^${CLAUDE_CONTAINER_NAME}$"; then
      docker ps --filter "name=^${CLAUDE_CONTAINER_NAME}$" \
        --format $'Name: {{.Names}}\nStatus: {{.Status}}\nUptime: {{.RunningFor}}'
      exit 0
    else
      echo "No running worker."
      exit 1
    fi
    ;;
esac

# Parse flags
UPDATE_ENV=false
DAEMON_MODE=false
ENV_MODE=""
for arg in "$@"; do
  case "$arg" in
    --update_environment) UPDATE_ENV=true ;;
    --copy_environment)   ENV_MODE="copy" ;;
    --link_environment)   ENV_MODE="link" ;;
    --daemon)             DAEMON_MODE=true ;;
    --help|-h)
      cat <<'HELP'
Usage: claude-docker.sh [OPTIONS]

Run Claude Code in a Docker container with Python environment support.

Environment modes:
  --link_environment    (default) Mount host Python site-packages into the
                        container read-only. Zero install time, no duplication.
                        All projects share the same packages.
  --copy_environment    Create an isolated venv inside the container, install
                        packages from requirements.txt. Persistent across runs
                        but duplicated per project. Use when you need isolation
                        or the host has no Python.

Other options:
  --update_environment  Snapshot the current host Python environment into
                        requirements.txt before starting. Combine with either
                        mode, e.g.: --update_environment --copy_environment
  --help, -h            Show this help message and exit.

Persistent worker mode (for MCP dispatch):
  --daemon              Start a persistent worker container in the background.
                        The dispatcher drives it via `docker exec`. Mounts
                        $CLAUDE_PROJECTS_DIR (default ~/claude-projects) at
                        /workspace/projects and $CLAUDE_DISPATCH_DIR (default
                        /tmp/claude-dispatch) at /workspace/dispatch. Mounts
                        $HOME/.ssh read-only so the container inherits your
                        host's key-alias mapping. Container is named
                        $CLAUDE_CONTAINER_NAME (default claude-worker).
                        Settings can also be placed in ~/.claude/docker.env
                        — generate a template with `make docker-config`.
  --stop                Stop the persistent worker.
  --status              Show worker status. Exit 1 if not running.

API keys and secrets:
  Create set-environment-vars.conf in the project directory listing files
  to mount, one per line (relative or absolute paths):
    setOpenAIKey.sh
    setOpenRouterKey.sh
    /etc/mycompany/env.sh
  .sh files are sourced at startup; all other files are mounted read-only
  at /home/node/api-keys/<basename> but not sourced.
  Never commit secret files to git.

Read-only mounts (configs, data dirs, etc.):
  Create readonly-mounts.conf listing host paths (files or directories) to
  mount read-only at the SAME path inside the container, one per line.
  Looked up in the project directory first, then in the script directory
  (global default). Both files are read and merged. Supports ~, # comments.

GitHub SSH (push from container without exposing ~/.ssh):
  Generate a dedicated key outside ~/.ssh:
    mkdir -p ~/.claude-docker-keys
    ssh-keygen -t ed25519 -f ~/.claude-docker-keys/github_ed25519 -N "" -C "claude-docker"
  Add ~/.claude-docker-keys/github_ed25519.pub to GitHub SSH keys.
  Create ~/.claude-docker-keys/setup-github-ssh.sh:
    export GIT_SSH_COMMAND="ssh -i /home/node/api-keys/github_ed25519 \
      -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
  Add both to set-environment-vars.conf:
    ~/.claude-docker-keys/github_ed25519
    ~/.claude-docker-keys/setup-github-ssh.sh

Examples:
  ./claude-docker.sh                          # link mode (default)
  ./claude-docker.sh --copy_environment       # isolated venv per project
  ./claude-docker.sh --update_environment     # refresh requirements.txt, then link
  ./claude-docker.sh --update_environment --copy_environment
HELP
      exit 0
      ;;
  esac
done

# --daemon: if a worker is already running, report and exit before any setup.
if [ "$DAEMON_MODE" = true ]; then
  if docker ps --filter "name=^${CLAUDE_CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "^${CLAUDE_CONTAINER_NAME}$"; then
    echo "Claude worker already running (container: $CLAUDE_CONTAINER_NAME)"
    docker ps --filter "name=^${CLAUDE_CONTAINER_NAME}$" --format 'Status: {{.Status}}'
    exit 0
  fi
  # Clear any stopped container carrying the same name so `docker run` succeeds.
  docker rm -f "$CLAUDE_CONTAINER_NAME" >/dev/null 2>&1 || true
  mkdir -p "$CLAUDE_PROJECTS_DIR" "$CLAUDE_DISPATCH_DIR"
fi

PROJECT_DIR="$(pwd)"
PROJECT_SLUG="$(echo "$PROJECT_DIR" | sed 's/[^a-zA-Z0-9]/-/g')"

# Detect if PROJECT_DIR is a git worktree; if so, find the main repo root.
# A worktree's --git-dir points inside .git/worktrees/<name>, while
# --git-common-dir points to the shared .git — they differ only in worktrees.
MAIN_REPO_DIR=""
if git -C "$PROJECT_DIR" rev-parse --git-dir &>/dev/null 2>&1; then
  _GIT_DIR="$(git -C "$PROJECT_DIR" rev-parse --git-dir 2>/dev/null || true)"
  _GIT_COMMON="$(git -C "$PROJECT_DIR" rev-parse --git-common-dir 2>/dev/null || true)"
  # Make paths absolute (git may return relative paths for the main worktree)
  _GIT_DIR="$(cd "$PROJECT_DIR" && realpath -m "$_GIT_DIR" 2>/dev/null || echo "$_GIT_DIR")"
  _GIT_COMMON="$(cd "$PROJECT_DIR" && realpath -m "$_GIT_COMMON" 2>/dev/null || echo "$_GIT_COMMON")"
  if [ -n "$_GIT_COMMON" ] && [ "$_GIT_DIR" != "$_GIT_COMMON" ]; then
    MAIN_REPO_DIR="$(dirname "$_GIT_COMMON")"
    echo "==> Worktree detected: main repo at $MAIN_REPO_DIR"
  fi
fi

IMAGE_NAME="claude-code-env"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$HOME/.claude-venv"

# ── Environment variable file discovery ──────────────────────────────
# Read set-environment-vars.conf if present. Each non-comment line is
# a shell file to source. Relative paths resolved from the conf file's directory.
KEY_FILES=()
API_KEYS_CONF="$PWD/set-environment-vars.conf"
if [ -f "$API_KEYS_CONF" ]; then
  CONF_DIR="$(cd "$(dirname "$API_KEYS_CONF")" && pwd)"
  while IFS= read -r line; do
    # Skip blank lines and comments
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    # Expand leading ~ to $HOME
    line="${line/#\~/$HOME}"
    # Resolve relative paths
    if [[ "$line" != /* ]]; then
      line="$CONF_DIR/$line"
    fi
    KEY_FILES+=("$line")
  done < "$API_KEYS_CONF"
fi

# Build mount flags and container paths list for key files
KEY_MOUNTS=""
KEY_PATHS_IN_CONTAINER=""
for keyfile in "${KEY_FILES[@]}"; do
  if [ -f "$keyfile" ]; then
    basename_key="$(basename "$keyfile")"
    KEY_MOUNTS="$KEY_MOUNTS -v $keyfile:/home/node/api-keys/$basename_key:ro"
    KEY_PATHS_IN_CONTAINER="$KEY_PATHS_IN_CONTAINER /home/node/api-keys/$basename_key"
  else
    echo "==> Warning: key file not found: $keyfile"
  fi
done

# Pass the list of key paths into the container via env var
if [ -n "$KEY_PATHS_IN_CONTAINER" ]; then
  echo "==> API keys: $(echo $KEY_PATHS_IN_CONTAINER | tr ' ' '\n' | xargs -I{} basename {} | tr '\n' ' ')"
fi

# ── Read-only mount discovery ────────────────────────────────────────
# Read readonly-mounts.conf if present. Each non-comment line is a host
# path mounted read-only at the same path inside the container. Checks
# project dir first then script dir (global), merging both lists.
RO_PATHS=()
_RO_SEEN=""
for _ro_conf in "$PWD/readonly-mounts.conf" "$SCRIPT_DIR/readonly-mounts.conf"; do
  [ -f "$_ro_conf" ] || continue
  _RO_CONF_DIR="$(cd "$(dirname "$_ro_conf")" && pwd)"
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    line="${line/#\~/$HOME}"
    if [[ "$line" != /* ]]; then
      line="$_RO_CONF_DIR/$line"
    fi
    case ":$_RO_SEEN:" in *":$line:"*) continue;; esac
    _RO_SEEN="${_RO_SEEN:+$_RO_SEEN:}$line"
    RO_PATHS+=("$line")
  done < "$_ro_conf"
done

RO_MOUNTS=""
for _p in "${RO_PATHS[@]}"; do
  if [ -e "$_p" ]; then
    RO_MOUNTS="$RO_MOUNTS -v $_p:$_p:ro"
  else
    echo "==> Warning: readonly mount path not found: $_p"
  fi
done
if [ -n "$RO_MOUNTS" ]; then
  echo "==> Read-only mounts: ${#RO_PATHS[@]} path(s)"
  for _p in "${RO_PATHS[@]}"; do echo "    $_p"; done
fi

# Detect host Python site-packages for --link_environment
HOST_SITE_PACKAGES=""
if command -v python3 &>/dev/null; then
  HOST_SITE_PACKAGES="$(python3 -c 'import sysconfig; print(sysconfig.get_path("purelib"))' 2>/dev/null || true)"
fi

# Detect active host venv + its base interpreter/stdlib. Needed because the
# container's `python3` (trixie ships 3.13) cannot load wheels built for a
# different minor version (e.g. 3.11). Same-path bind-mounts let the venv's
# absolute shebangs and pyvenv.cfg resolve unchanged inside the container.
HOST_VENV=""
HOST_PY_INTERP=""
HOST_PY_STDLIB=""
if command -v python3 &>/dev/null; then
  HOST_VENV="$(python3 -c 'import sys; print(sys.prefix if sys.prefix != sys.base_prefix else "")' 2>/dev/null || true)"
  _HOST_PY_BASE="$(python3 -c 'import sys; print(sys.base_prefix)' 2>/dev/null || true)"
  _HOST_PY_VER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || true)"
  if [ -n "$_HOST_PY_BASE" ] && [ -n "$_HOST_PY_VER" ]; then
    HOST_PY_INTERP="$_HOST_PY_BASE/bin/python$_HOST_PY_VER"
    HOST_PY_STDLIB="$_HOST_PY_BASE/lib/python$_HOST_PY_VER"
  fi
fi

# Determine env mode: default to link (shared host env) if host Python exists
if [ -z "$ENV_MODE" ]; then
  if [ -n "$HOST_SITE_PACKAGES" ] && [ -d "$HOST_SITE_PACKAGES" ]; then
    ENV_MODE="link"
  elif [ -f "$SCRIPT_DIR/requirements.txt" ]; then
    ENV_MODE="copy"
  fi
fi

mkdir -p "$HOME/.claude/projects/$PROJECT_SLUG"
mkdir -p "$VENV_DIR"

# Create entrypoint.sh next to this script (always regenerate to pick up changes)
echo "==> Creating entrypoint.sh..."
cat > "$SCRIPT_DIR/entrypoint.sh" <<'ENTRY'
#!/bin/bash
set -e

# ── Environment vars ──────────────────────────────────────────────────
# Source any .sh files mounted into /home/node/api-keys/
if [ -d "/home/node/api-keys" ]; then
  for keyfile in /home/node/api-keys/*.sh; do
    [ -f "$keyfile" ] && source "$keyfile"
  done
fi

ENV_MODE="${ENV_MODE:-copy}"
VENV_PATH="/opt/venv"
REQ_FILE="/tmp/requirements.txt"

# ── Progress bar helper ──────────────────────────────────────────────
progress_pip_install() {
    local label="$1"
    local pip_cmd="$2"   # "pip" or "$VENV_PATH/bin/pip"
    local req_file="$3"
    shift 3
    local total
    total=$(grep -cvE '^\s*($|#)' "$req_file" 2>/dev/null || echo 0)
    if [ "$total" -eq 0 ]; then
        return 0
    fi

    local cols
    cols=$(tput cols 2>/dev/null || echo 80)
    local bar_width=$((cols - 30))
    [ "$bar_width" -lt 10 ] && bar_width=10

    local counter_file
    counter_file=$(mktemp)
    echo "0" > "$counter_file"

    local draw_bar
    draw_bar() {
        local n=$1
        [ "$n" -gt "$total" ] && n=$total
        local pct=$((n * 100 / total))
        local filled=$((pct * bar_width / 100))
        local empty=$((bar_width - filled))
        local bar_fill="" bar_empty=""
        [ "$filled" -gt 0 ] && bar_fill=$(printf '%*s' "$filled" '' | tr ' ' '█')
        [ "$empty" -gt 0 ]  && bar_empty=$(printf '%*s' "$empty" '' | tr ' ' '░')
        printf "\r  %s [%s%s] %3d%% (%d/%d)" "$label" "$bar_fill" "$bar_empty" "$pct" "$n" "$total"
    }

    draw_bar 0
    $pip_cmd install --progress-bar off -r "$req_file" "$@" 2>&1 | while IFS= read -r line; do
        case "$line" in
            *"Requirement already satisfied"*|*"Collecting "*|*"Successfully installed"*)
                local cnt
                cnt=$(cat "$counter_file")
                cnt=$((cnt + 1))
                echo "$cnt" > "$counter_file"
                draw_bar "$cnt"
                ;;
        esac
    done
    draw_bar "$total"
    echo ""
    rm -f "$counter_file"
}

# ── Link mode: host site-packages is mounted, just set PATH ──────────
if [ "$ENV_MODE" = "link" ]; then
    if [ -n "$HOST_VENV" ] && [ -f "$HOST_VENV/bin/activate" ]; then
        echo "==> Link mode: activating host venv at $HOST_VENV"
        # shellcheck disable=SC1091
        source "$HOST_VENV/bin/activate"
        # Add CUDA libs (system toolkit if mounted + pip nvidia-* wheels) so
        # HOOMD / Torch find libcudart.so etc. --gpus all only ships the driver.
        CUDA_LIB_DIRS=""
        for d in /usr/local/cuda/lib64 /usr/local/cuda/targets/x86_64-linux/lib; do
            [ -d "$d" ] && CUDA_LIB_DIRS="${CUDA_LIB_DIRS:+$CUDA_LIB_DIRS:}$d"
        done
        for d in "$HOST_VENV"/lib/python*/site-packages/nvidia/*/lib; do
            [ -d "$d" ] && CUDA_LIB_DIRS="${CUDA_LIB_DIRS:+$CUDA_LIB_DIRS:}$d"
        done
        [ -n "$CUDA_LIB_DIRS" ] && export LD_LIBRARY_PATH="$CUDA_LIB_DIRS${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    elif [ -d "/opt/host-site-packages" ]; then
        echo "==> Link mode: using host site-packages (no venv detected)"
        export PYTHONPATH="/opt/host-site-packages:${PYTHONPATH:-}"
        echo "    $(find /opt/host-site-packages -maxdepth 1 -name '*.dist-info' | wc -l) packages available"
    else
        echo "==> Link mode: no venv and no /opt/host-site-packages — Python imports may fail"
    fi

    if [ -f "$REQ_FILE" ]; then
        local_pkgs=$(grep '@ file://' "$REQ_FILE" | sed 's/.*@ file:\/\///' || true)
        if [ -n "$local_pkgs" ]; then
            for pkg in $local_pkgs; do
                if [ -d "$pkg" ]; then
                    echo "==> Installing local package: $pkg"
                    pip install --quiet --target /opt/local-pkgs "$pkg" 2>/dev/null || true
                fi
            done
            export PYTHONPATH="/opt/local-pkgs:${PYTHONPATH:-}"
        fi
    fi

    exec "$@"
fi

# ── Copy mode: isolated venv with persistent cache ───────────────────
if [ ! -f "$REQ_FILE" ]; then
    echo "==> No requirements.txt found, skipping venv setup."
    exec "$@"
fi

REQ_HASH=$(md5sum "$REQ_FILE" | cut -d' ' -f1)

if [ ! -f "$VENV_PATH/bin/python" ]; then
    echo "==> Creating venv..."
    python3 -m venv "$VENV_PATH"
fi

PKG_COUNT=$("$VENV_PATH/bin/pip" list --format=freeze 2>/dev/null | wc -l)

if [ "$PKG_COUNT" -le 3 ] || [ ! -f "$VENV_PATH/.req_hash" ] || [ "$REQ_HASH" != "$(cat "$VENV_PATH/.req_hash")" ]; then
    echo "==> Installing/updating packages ($PKG_COUNT found, expecting more)..."

    FILTERED_REQ=$(mktemp)
    grep -v '@ file://' "$REQ_FILE" > "$FILTERED_REQ" || true
    progress_pip_install "Packages" "$VENV_PATH/bin/pip" "$FILTERED_REQ"
    rm -f "$FILTERED_REQ"

    for pkg in $(grep '@ file://' "$REQ_FILE" | sed 's/.*@ file:\/\///'); do
        if [ -d "$pkg" ]; then
            echo "==> Installing local package: $pkg"
            "$VENV_PATH/bin/pip" install --quiet "$pkg" 2>/dev/null \
              || "$VENV_PATH/bin/pip" install --quiet --no-build-isolation "$pkg" \
              || echo "    ⚠ Failed to install $pkg (check write permissions)"
        fi
    done

    echo "$REQ_HASH" > "$VENV_PATH/.req_hash"
else
    echo "==> Python venv up to date ($PKG_COUNT packages)."
fi

exec "$@"
ENTRY
chmod +x "$SCRIPT_DIR/entrypoint.sh"

# Update requirements.txt from current environment if requested
if [ "$UPDATE_ENV" = true ]; then
  echo "==> Updating requirements.txt from current Python environment..."
  pip freeze > "$SCRIPT_DIR/requirements.txt"
  echo "    $(wc -l < "$SCRIPT_DIR/requirements.txt") packages captured."
fi

# Check if requirements.txt exists for the mount
REQ_MOUNT=""
if [ -f "$SCRIPT_DIR/requirements.txt" ]; then
  REQ_MOUNT="-v $SCRIPT_DIR/requirements.txt:/tmp/requirements.txt:ro"
fi

# Build mount flags for local development packages
LOCAL_MOUNTS=""
if [ -f "$SCRIPT_DIR/requirements.txt" ]; then
  while IFS= read -r pkg_path; do
    if [ -d "$pkg_path" ]; then
      LOCAL_MOUNTS="$LOCAL_MOUNTS -v $pkg_path:$pkg_path"
    fi
  done < <(grep '@ file://' "$SCRIPT_DIR/requirements.txt" | sed 's/.*@ file:\/\///')
fi

echo "==> Building Docker image..."
docker build -t "$IMAGE_NAME" -f - "$SCRIPT_DIR" <<'EOF'
# Stage 1: pull in a full TeX Live 2026 tree from the official CTAN image
FROM texlive/texlive:latest AS tex

FROM node:20-trixie
# Base image carries glibc 2.41 (vs bookworm's 2.36) so host-built .so files
# requiring GLIBC_2.38 (e.g. HOOMD 7) can load. The apt line installs git plus
# the .so deps the host Python 3.11 stdlib + most scientific wheels link
# against — see docs/claude-docker-gpu-setup.md (Step A) in glycocalyx-np.
# python3/pip/venv are intentionally NOT installed: the venv is bind-mounted
# from the host along with /usr/bin/python3.11 and its stdlib.
# perl + fontconfig are TeX Live runtime deps (latexmk, fontspec, xelatex).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git \
        libssl3 libffi8 libsqlite3-0 liblzma5 libbz2-1.0 libgomp1 \
        perl fontconfig \
    && rm -rf /var/lib/apt/lists/*

# Bring in the entire TeX Live tree from the official image
COPY --from=tex /usr/local/texlive /usr/local/texlive

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER node
ENV NPM_CONFIG_PREFIX=/home/node/.npm-global
ENV PATH=/home/node/.npm-global/bin:/opt/venv/bin:/usr/local/texlive/2026/bin/x86_64-linux:$PATH
RUN npm install -g @anthropic-ai/claude-code
ENTRYPOINT ["entrypoint.sh"]
CMD ["claude", "--dangerously-skip-permissions"]
EOF

GPU_FLAG=""
if docker info --format '{{.Runtimes}}' 2>/dev/null | grep -q nvidia; then
  GPU_FLAG="--gpus all"
  echo "==> GPU: NVIDIA (nvidia container runtime)"
else
  for dev in /dev/nvidia[0-9]* /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidia-modeset; do
    [ -c "$dev" ] && GPU_FLAG="$GPU_FLAG --device $dev"
  done
  if [ -n "$GPU_FLAG" ]; then
    echo "==> GPU: NVIDIA (device passthrough)"
    echo "    Tip: install nvidia-container-toolkit for full GPU support:"
    echo "         $(dirname "${BASH_SOURCE[0]}")/setup-gpu.sh"
  fi
fi

for dev in /dev/dri/renderD*; do
  [ -c "$dev" ] && GPU_FLAG="$GPU_FLAG --device $dev"
done
if [ -c /dev/kfd ]; then
  GPU_FLAG="$GPU_FLAG --device /dev/kfd"
fi
[ -n "$(echo "$GPU_FLAG" | grep -o '/dev/dri\|/dev/kfd')" ] && echo "==> GPU: AMD/Intel (DRI render nodes)"

# ── Build env-specific docker flags ──────────────────────────────────
ENV_MOUNTS=""
ENV_VARS="-e ENV_MODE=${ENV_MODE:-copy}"

if [ "$ENV_MODE" = "link" ]; then
  if [ -z "$HOST_SITE_PACKAGES" ] || [ ! -d "$HOST_SITE_PACKAGES" ]; then
    echo "ERROR: Cannot find host Python site-packages. Is python3 installed?"
    exit 1
  fi
  echo "==> Link mode: mounting $HOST_SITE_PACKAGES (read-only)"
  ENV_MOUNTS="-v $HOST_SITE_PACKAGES:/opt/host-site-packages:ro"
else
  ENV_MOUNTS="-v $VENV_DIR:/opt/venv"
fi

MAIN_REPO_MOUNT=""
if [ -n "$MAIN_REPO_DIR" ] && [ "$MAIN_REPO_DIR" != "$PROJECT_DIR" ]; then
  MAIN_REPO_MOUNT="-v $MAIN_REPO_DIR:$MAIN_REPO_DIR"
fi

# Mount host tools that are already installed into a guaranteed-in-PATH location
HOST_TOOL_MOUNTS=""
for tool in gh; do
  tool_path="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$tool_path" ] && HOST_TOOL_MOUNTS="$HOST_TOOL_MOUNTS -v $tool_path:/usr/local/bin/$tool:ro"
done

# Same-path bind mounts so a host venv (and its base interpreter + stdlib) is
# usable inside the container. Only built in link mode; non-link projects fall
# back to the existing /opt/venv flow. ENV_VARS gains HOST_VENV so the
# entrypoint can auto-activate.
PY_INTERP_MOUNTS=""
if [ "$ENV_MODE" = "link" ]; then
  [ -n "$HOST_VENV" ]      && [ -d "$HOST_VENV" ]      && PY_INTERP_MOUNTS="$PY_INTERP_MOUNTS -v $HOST_VENV:$HOST_VENV:ro"
  [ -n "$HOST_PY_INTERP" ] && [ -f "$HOST_PY_INTERP" ] && PY_INTERP_MOUNTS="$PY_INTERP_MOUNTS -v $HOST_PY_INTERP:$HOST_PY_INTERP:ro"
  [ -n "$HOST_PY_STDLIB" ] && [ -d "$HOST_PY_STDLIB" ] && PY_INTERP_MOUNTS="$PY_INTERP_MOUNTS -v $HOST_PY_STDLIB:$HOST_PY_STDLIB:ro"
  [ -n "$HOST_VENV" ]      && ENV_VARS="$ENV_VARS -e HOST_VENV=$HOST_VENV"
fi

# Mount host CUDA toolkit if present — host HOOMD may be linked against
# /usr/local/cuda/.../libcudart.so. --gpus all only injects the driver.
CUDA_MOUNT=""
[ -d /usr/local/cuda ] && CUDA_MOUNT="-v /usr/local/cuda:/usr/local/cuda:ro"

# Mount each host PYTHONPATH directory read-only at the same path so dev
# packages (e.g. editable installs activated via `export PYTHONPATH=...`)
# resolve inside the container. Dirs already covered by other mounts
# (project, main repo, host venv) are skipped to avoid double-mount.
PYTHONPATH_MOUNTS=""
PYTHONPATH_IN_CONTAINER=""
if [ -n "${PYTHONPATH:-}" ]; then
  _SEEN=""
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    [ -d "$entry" ] || continue
    abs="$(cd "$entry" 2>/dev/null && pwd)" || continue
    [ -z "$abs" ] && continue
    case ":$_SEEN:" in *":$abs:"*) continue;; esac
    _SEEN="${_SEEN:+$_SEEN:}$abs"
    PYTHONPATH_IN_CONTAINER="${PYTHONPATH_IN_CONTAINER:+$PYTHONPATH_IN_CONTAINER:}$abs"
    # Already mounted by other rules — keep in PYTHONPATH but don't re-mount.
    [ "$abs" = "$PROJECT_DIR" ] && continue
    case "$abs" in "$PROJECT_DIR"/*) continue;; esac
    if [ -n "$MAIN_REPO_DIR" ]; then
      [ "$abs" = "$MAIN_REPO_DIR" ] && continue
      case "$abs" in "$MAIN_REPO_DIR"/*) continue;; esac
    fi
    if [ -n "$HOST_VENV" ]; then
      case "$abs" in "$HOST_VENV"|"$HOST_VENV"/*) continue;; esac
    fi
    PYTHONPATH_MOUNTS="$PYTHONPATH_MOUNTS -v $abs:$abs:ro"
  done < <(printf '%s' "$PYTHONPATH" | tr ':' '\n')
  if [ -n "$PYTHONPATH_MOUNTS" ]; then
    echo "==> PYTHONPATH: mounting external dirs read-only"
    for d in $(printf '%s' "$PYTHONPATH_MOUNTS" | tr ' ' '\n' | grep '^/' | cut -d: -f1); do
      echo "    $d"
    done
  fi
  [ -n "$PYTHONPATH_IN_CONTAINER" ] && ENV_VARS="$ENV_VARS -e PYTHONPATH=$PYTHONPATH_IN_CONTAINER"
fi

# ── Daemon-only mounts ───────────────────────────────────────────────
# Mount the host's ~/.ssh read-only so the container inherits the host's
# key-alias mapping from ~/.ssh/config. No config generation happens inside
# the container.
SSH_MOUNTS=""
if [ "$DAEMON_MODE" = true ] && [ -d "$HOME/.ssh" ]; then
  SSH_MOUNTS="-v $HOME/.ssh:/home/node/.ssh:ro"
fi

# Persistent project clones + per-dispatch worktrees. Daemon-only so the
# interactive mode is unchanged.
DISPATCH_MOUNTS=""
if [ "$DAEMON_MODE" = true ]; then
  DISPATCH_MOUNTS="-v $CLAUDE_PROJECTS_DIR:/workspace/projects -v $CLAUDE_DISPATCH_DIR:/workspace/dispatch"
fi

if [ "$DAEMON_MODE" = true ]; then
  echo "==> Starting persistent Claude worker (container: $CLAUDE_CONTAINER_NAME)..."
  docker run -d \
    --name "$CLAUDE_CONTAINER_NAME" \
    --restart unless-stopped \
    --add-host=host.docker.internal:host-gateway \
    $GPU_FLAG \
    -v "$HOME/.claude":/home/node/.claude \
    -v "$HOME/.claude":"$HOME/.claude" \
    --tmpfs /home/node/.claude/projects:uid=1000,gid=1000 \
    -v "$HOME/.claude.json":/home/node/.claude.json \
    $ENV_MOUNTS \
    $PY_INTERP_MOUNTS \
    $PYTHONPATH_MOUNTS \
    $CUDA_MOUNT \
    $REQ_MOUNT \
    $LOCAL_MOUNTS \
    $KEY_MOUNTS \
    $RO_MOUNTS \
    $HOST_TOOL_MOUNTS \
    $SSH_MOUNTS \
    $DISPATCH_MOUNTS \
    $ENV_VARS \
    -e CLAUDE_DAEMON=1 \
    -e TERM=xterm-256color \
    -w /workspace \
    "$IMAGE_NAME" \
    tail -f /dev/null >/dev/null

  echo "Claude worker started (container: $CLAUDE_CONTAINER_NAME)"
  echo "  Projects:  /workspace/projects  (host: $CLAUDE_PROJECTS_DIR)"
  echo "  Dispatch:  /workspace/dispatch  (host: $CLAUDE_DISPATCH_DIR)"
  echo "  Stop with: $0 --stop"
  exit 0
fi

echo "==> Starting Claude (env: ${ENV_MODE:-none})..."
exec docker run -it --rm \
  --name "claude-$(basename "$PROJECT_DIR")" \
  --network host \
  $GPU_FLAG \
  -v "$PROJECT_DIR":"$PROJECT_DIR" \
  $MAIN_REPO_MOUNT \
  -v "$HOME/.claude":/home/node/.claude \
  -v "$HOME/.claude":"$HOME/.claude" \
  --tmpfs /home/node/.claude/projects:uid=1000,gid=1000 \
  -v "$HOME/.claude/projects/$PROJECT_SLUG":/home/node/.claude/projects/$PROJECT_SLUG \
  -v "$HOME/.claude.json":/home/node/.claude.json \
  $ENV_MOUNTS \
  $PY_INTERP_MOUNTS \
  $PYTHONPATH_MOUNTS \
  $CUDA_MOUNT \
  $REQ_MOUNT \
  $LOCAL_MOUNTS \
  $KEY_MOUNTS \
  $RO_MOUNTS \
  $HOST_TOOL_MOUNTS \
  $ENV_VARS \
  -e TERM=xterm-256color \
  -w "$PROJECT_DIR" \
  "$IMAGE_NAME"
