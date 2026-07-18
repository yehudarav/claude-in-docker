SHELL := /bin/bash

CLAUDE_DIR    := $(HOME)/.claude
CONFIG_FILE   := $(CLAUDE_DIR)/docker.env

define CONFIG_TEMPLATE
# Claude Docker Configuration
# Source this before running claude-docker.sh, or add to your set_environment.
# Note: CLAUDE_* vars are consumed by claude-docker.sh on the host.
# To make API keys reach the container, add this file to set-environment-vars.conf
# (same directory as the project) so the entrypoint sources it inside the container.

# API keys
ANTHROPIC_API_KEY=sk-ant-REPLACE_ME
OPENAI_API_KEY=sk-REPLACE_ME

# Docker settings
CLAUDE_PROJECTS_DIR=$$HOME/claude-projects
CLAUDE_DISPATCH_DIR=/tmp/claude-dispatch
CLAUDE_CONTAINER_NAME=claude-worker

# MCP server (for dispatch connection from inside container)
CLAUDE_MCP_HOST=host.docker.internal
CLAUDE_MCP_PORT=8765
endef
export CONFIG_TEMPLATE

.PHONY: docker-config
docker-config:
	@mkdir -p "$(CLAUDE_DIR)"
	@if [ ! -f "$(CONFIG_FILE)" ]; then \
	  printf '%s\n' "$$CONFIG_TEMPLATE" > "$(CONFIG_FILE)"; \
	  chmod 600 "$(CONFIG_FILE)"; \
	  echo "Wrote $(CONFIG_FILE)"; \
	  echo "Edit it to fill in your API keys and adjust paths."; \
	else \
	  echo "$(CONFIG_FILE) already exists."; \
	  missing=$$(printf '%s\n' "$$CONFIG_TEMPLATE" \
	    | awk -F= '/^[A-Z]/{print $$1}' \
	    | while read k; do \
	        grep -q "^[[:space:]]*$$k=" "$(CONFIG_FILE)" || echo "$$k"; \
	      done); \
	  if [ -z "$$missing" ]; then \
	    echo "All expected keys present."; \
	  else \
	    echo "Missing keys (add these to $(CONFIG_FILE)):"; \
	    for k in $$missing; do \
	      printf '%s\n' "$$CONFIG_TEMPLATE" | grep -E "^[[:space:]]*$$k=" | sed 's/^/+ /'; \
	    done; \
	  fi; \
	fi
