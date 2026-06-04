# claude-in-docker
Run Claude Code in a Docker container so it can't touch your system. Per-project memory is preserved between sessions.

## Prerequisites
- Docker ([install instructions](https://docs.docker.com/get-docker/))
- Run `claude` once anywhere to log in (this creates `~/.claude.json`)

## Install (linux/mac)
```sh
git clone https://github.com/erasta/claude-in-docker.git
chmod +x claude-in-docker/claude-docker.sh
echo 'export PATH="$PATH:'"$PWD/claude-in-docker"'"' >> ~/.bashrc
source ~/.bashrc
```

## Usage
From any project directory:
```sh
claude-docker.sh
```

Run `claude-docker.sh --help` for the full flag list.

## Python environment

Two modes, chosen at startup:

| Mode | When to use | How |
|---|---|---|
| `--link_environment` (default) | Host has Python installed; you want zero install time | Mounts host site-packages read-only at `/opt/host-site-packages`. All projects share the same packages. |
| `--copy_environment` | You need isolation, or the host has no Python | Builds a persistent venv at `~/.claude-venv`, installs from `requirements.txt`. Only reinstalls when the file changes. |

Snapshot the current host environment into `requirements.txt` before launching:
```sh
claude-docker.sh --update_environment                       # snapshot, then link
claude-docker.sh --update_environment --copy_environment    # snapshot, then copy
```

If neither flag is passed, the script picks `link` when the host has Python, else `copy` when a `requirements.txt` exists, else no env setup.

### Editable installs and `PYTHONPATH`

If your host shell exports `PYTHONPATH` (e.g. dev packages activated via `export PYTHONPATH=/path/to/pkg:$PYTHONPATH`), each existing directory is mounted into the container read-only at the same path, and `PYTHONPATH` is forwarded so `import` resolves there. Directories already covered by other mounts (project, main repo, host venv) stay in `PYTHONPATH` but aren't re-mounted.

No-op when `PYTHONPATH` is unset.

## API keys and secrets

Create `set-environment-vars.conf` in your project directory listing files to mount into the container. One path per line — absolute, relative, or `~`-prefixed:

```
setOpenAIKey.sh
setOpenRouterKey.sh
/etc/evolvix/env.sh
~/.claude-docker-keys/github_ed25519
```

How it works:
- `.sh` files are **sourced** at startup, so any `export KEY=value` lines become env vars inside the container.
- Non-`.sh` files (PEM keys, certs, plain configs) are **mounted read-only** at `/home/node/api-keys/<basename>` but not sourced.
- The `.conf` file itself is safe to commit. **The listed files are not** — keep them outside your repo.

Example `setOpenAIKey.sh`:
```sh
export OPENAI_API_KEY=sk-...
```

### GitHub SSH push from inside the container

Without exposing all of `~/.ssh`, give the container its own SSH key for GitHub:

```sh
mkdir -p ~/.claude-docker-keys
ssh-keygen -t ed25519 -f ~/.claude-docker-keys/github_ed25519 -N "" -C "claude-docker"
```

Add `~/.claude-docker-keys/github_ed25519.pub` to your GitHub SSH keys.

Create `~/.claude-docker-keys/setup-github-ssh.sh`:
```sh
export GIT_SSH_COMMAND="ssh -i /home/node/api-keys/github_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
```

Add both to your project's `set-environment-vars.conf`:
```
~/.claude-docker-keys/github_ed25519
~/.claude-docker-keys/setup-github-ssh.sh
```

The key is mounted (not sourced) and the helper script is sourced to point `git` at it. The rest of your `~/.ssh` is never visible to the container.

## GPU support

The script auto-detects what's available and passes it through:

- **NVIDIA via container runtime** — used when `nvidia-container-toolkit` is registered with Docker. Best path.
- **NVIDIA via device passthrough** — fallback when devices exist but the toolkit isn't installed. The script prints a hint to run `./setup-gpu.sh` (Debian/Ubuntu installer for `nvidia-container-toolkit`).
- **AMD ROCm** — passes through `/dev/dri/renderD*` and `/dev/kfd`.
- **Intel** — passes through `/dev/dri/renderD*`.

No flags needed. The detected path is printed at startup.

## Git worktrees

If you run from a `git worktree`, the script detects it via `git rev-parse --git-common-dir` and also mounts the main repo at the same absolute path. This lets `git` inside the container read shared object data — commits, pushes, log, and blame all work normally.

No-op when not in a worktree.

## Host tools

`gh` is mounted from the host into the container (resolved via `command -v`), so the container picks up whichever install you already have. `git` is installed in the image.

## Is this safe?
The [script](claude-docker.sh) is short. If you're unsure, paste it into Claude and ask _"Is this script safe to run?"_
