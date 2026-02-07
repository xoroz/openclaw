---
name: git-manager
description: Commit and push changes using GITHUB_API_KEY environment variable. Use for git operations.
---

# Git Manager Skill

Commit and push changes to GitHub using the `GITHUB_API_KEY` environment variable for authentication.

## Prerequisites

- `GITHUB_API_KEY` environment variable set with a GitHub Personal Access Token
- Token needs `repo` scope (and `workflow` scope if modifying GitHub Actions)

## Common Operations

### 1. Check status and stage files

```bash
git status --short
git add <files>
```

### 2. Commit changes

```bash
git commit -m "feat: Your commit message"
```

### 3. Push using API key

```bash
git push https://xoroz:${GITHUB_API_KEY}@github.com/xoroz/openclaw.git main
```

### 4. Force push (if needed)

```bash
git push https://xoroz:${GITHUB_API_KEY}@github.com/xoroz/openclaw.git main --force
```

## Pull from upstream (original repo)

```bash
# Fetch upstream changes
git fetch upstream

# Merge upstream into your branch
git merge upstream/main

# Push merged changes
git push https://xoroz:${GITHUB_API_KEY}@github.com/xoroz/openclaw.git main
```

## Quick commit and push

```bash
# Stage, commit, and push in one go
git add -A && \
git commit -m "Your message" && \
git push https://xoroz:${GITHUB_API_KEY}@github.com/xoroz/openclaw.git main
```

## Notes

- Never commit the API key to the repository
- The key is read from environment at runtime
- If you get "workflow scope" errors, either:
  - Add `workflow` scope to your token, OR
  - Remove `.github/workflows/` from the commit
