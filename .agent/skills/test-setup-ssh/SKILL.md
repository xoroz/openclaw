---
name: test-setup-ssh
description: Test OpenClaw setup.sh on remote host via SSH. Use for remote server testing.
---

# Test Setup via SSH (Remote)

Automated test of `setup.sh` on a remote machine via SSH.

## When to use this skill

- Testing setup on a remote server
- Deploying to staging/production
- Verifying installation on different OS/hardware

## Prerequisites

- SSH access to remote host
- Remote host is Ubuntu/Debian
- SSH key authentication configured (recommended)

## Parameters

Set these environment variables before running:

```bash
export SSH_HOST="user@hostname"     # Required: remote host
export SSH_KEY=""                   # Optional: path to SSH key
export OPENROUTER_API_KEY=""        # Optional: API key
```

## How to use it

### 1. Set SSH command variables

```bash
SSH_CMD="ssh ${SSH_KEY:+-i $SSH_KEY} $SSH_HOST"
SCP_CMD="scp ${SSH_KEY:+-i $SSH_KEY}"
echo "SSH target: $SSH_HOST"
```

### 2. Copy setup.sh to remote

```bash
$SCP_CMD /home/felix/projects/openclaw/setup.sh $SSH_HOST:/tmp/setup.sh
```

### 3. Uninstall existing on remote

```bash
$SSH_CMD "sudo /tmp/setup.sh --uninstall --user openclaw -y 2>&1 || echo 'Nothing to uninstall'"
```

### 4. Run setup on remote

```bash
$SSH_CMD "sudo OPENROUTER_API_KEY='${OPENROUTER_API_KEY:-}' /tmp/setup.sh --user openclaw -y --skip-onboard"
```

### 5. Wait for containers

```bash
sleep 30
```

### 6. Check container status

```bash
$SSH_CMD "docker ps --filter 'name=openclaw' --format 'table {{.Names}}\t{{.Status}}'"
```

### 7. Check for errors in logs

```bash
$SSH_CMD "docker logs openclaw-gateway 2>&1 | tail -50"
```

### 8. Verify permissions

```bash
$SSH_CMD "ls -la /home/openclaw/.openclaw/"
$SSH_CMD "sudo -u openclaw bash -c 'cd ~/containers/openclaw && docker compose ps'"
```

### 9. Test gateway health

```bash
$SSH_CMD "curl -sf http://localhost:18789/health && echo 'Gateway healthy'"
```

## Success Criteria

- SSH connection works
- setup.sh completes without errors
- openclaw-gateway container running
- openclaw-ollama container running
- No permission errors
- Target user can run docker compose

## Cleanup

```bash
$SSH_CMD "sudo /tmp/setup.sh --uninstall --user openclaw -y"
```
