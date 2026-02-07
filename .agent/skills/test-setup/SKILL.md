---
name: test-setup
description: Test OpenClaw setup.sh locally. Use when testing installation on current machine.
---

# Test Setup (Local)

Automated test of `setup.sh` on the local machine.

## When to use this skill

- Testing setup.sh changes before committing
- Verifying installation works end-to-end
- Debugging permission or config issues

## Prerequisites

- Run as root or with sudo
- `OPENROUTER_API_KEY` in environment (optional)

## How to use it

Run these steps in order. All commands are safe to auto-run.

### 1. Check for existing installation

```bash
docker ps -a --filter "name=openclaw" --format "{{.Names}}" 2>/dev/null || echo "No containers"
```

### 2. Uninstall existing (if any)

```bash
cd /home/felix/projects/openclaw
sudo ./setup.sh --uninstall --user openclaw -y 2>&1 || echo "Nothing to uninstall"
```

### 3. Run setup

```bash
cd /home/felix/projects/openclaw
sudo OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}" ./setup.sh --user openclaw -y --skip-onboard
```

### 4. Wait for containers to start

```bash
sleep 30
```

### 5. Check container status

```bash
docker ps --filter "name=openclaw" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

### 6. Run post-install tests as target user

```bash
sudo -u openclaw bash -c 'cd ~ && ./test.sh'
```

## Success Criteria

- openclaw-gateway container running
- openclaw-ollama container running
- All test.sh tests pass
- No permission errors

## Cleanup (optional)

To remove after testing:

```bash
sudo ./setup.sh --uninstall --user openclaw -y
```
