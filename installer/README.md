# Skills MCP Server - Installation Guide

> **One-click installer to set up 1,500+ AI coding skills on any Windows/WSL/Linux machine**

## What This Installs

| Component | Description |
|-----------|-------------|
| **Skills Repository** | Git clone of `github.com/manoelbenicio/skills.git` (1,500+ skills) |
| **MCP Server** | Python-based JSON-RPC server (`skills_mcp_server.py`) |
| **skills.txt** | Config pointer so IDEs can find the skills |

## Prerequisites

- **Python 3.10+** — [Download](https://www.python.org/downloads/)
- **Git** — [Download](https://git-scm.com/downloads)
- No other dependencies needed (zero-dependency Python script)

---

## Quick Install

### Windows (PowerShell / CMD)

```cmd
cd C:\Users\mbenicios\Documents\local\skills-installer
install.bat
```

### WSL / Linux

```bash
cd /mnt/c/Users/mbenicios/Documents/local/skills-installer
bash install.sh
```

### Remote Machine via Tailscale SSH

```bash
# 1. Copy the installer folder to the remote machine
scp -r /mnt/c/Users/mbenicios/Documents/local/skills-installer dataops-lab@<hostname>:~/skills-installer

# 2. SSH into the remote machine and run
ssh dataops-lab@<hostname>
cd ~/skills-installer
bash install.sh
```

---

## What the Installer Does

1. **Checks** Python and Git are installed
2. **Clones** the skills repository to `~/.gemini/config/consolidated-skills/`
3. **Copies** `skills_mcp_server.py` to `~/.gemini/antigravity-ide/scratch/`
4. **Auto-detects** the environment (Windows / WSL-under-Windows / Native Linux)
5. **Patches paths** if running on standalone Linux (not under `/mnt/c/`)
6. **Creates** `~/.gemini/antigravity/skills.txt` pointing to the skills folder
7. **Tests** the MCP server responds correctly

---

## Post-Install: MCP Config

After installation, add the skills-consolidator to your IDE's `mcp_config.json`:

### Windows (native Python)

```json
{
  "mcpServers": {
    "skills-consolidator": {
      "command": "python",
      "args": [
        "C:\\Users\\<USERNAME>\\.gemini\\antigravity-ide\\scratch\\skills_mcp_server.py"
      ]
    }
  }
}
```

### WSL (via wsl command)

```json
{
  "mcpServers": {
    "skills-consolidator": {
      "command": "wsl",
      "args": [
        "-d", "Ubuntu", "--",
        "python3",
        "/mnt/c/Users/<USERNAME>/.gemini/antigravity-ide/scratch/skills_mcp_server.py"
      ]
    }
  }
}
```

### Native Linux

```json
{
  "mcpServers": {
    "skills-consolidator": {
      "command": "python3",
      "args": [
        "/home/<USERNAME>/.gemini/antigravity-ide/scratch/skills_mcp_server.py"
      ]
    }
  }
}
```

---

## File Locations After Install

| File | Windows Path | WSL/Linux Path |
|------|-------------|----------------|
| Skills repo | `%USERPROFILE%\.gemini\config\consolidated-skills\` | `~/.gemini/config/consolidated-skills/` |
| MCP server | `%USERPROFILE%\.gemini\antigravity-ide\scratch\skills_mcp_server.py` | `~/.gemini/antigravity-ide/scratch/skills_mcp_server.py` |
| skills.txt | `%USERPROFILE%\.gemini\antigravity\skills.txt` | `~/.gemini/antigravity/skills.txt` |

---

## Available MCP Tools

Once installed, these tools are available via the MCP server:

| Tool | Description |
|------|-------------|
| `list_skills` | List all skills (optional `source_filter`) |
| `search_skills` | Search by keyword (multi-word, ranked results) |
| `get_skill_instructions` | Get full SKILL.md content (fuzzy match) |
| `get_registry_stats` | Total count + breakdown by source |
| `sync_skills` | Pull latest from GitHub |
| `push_skills` | Commit & push local changes to GitHub |
| `git_status` | Show pending changes in the repo |
| `refresh_registry` | Re-scan directories and reload |
| `consolidate_skills` | Copy scattered skills into the central repo |

---

## Updating Skills

To update to the latest skills from GitHub:

```bash
# Option 1: Use the MCP tool
# Call "sync_skills" via your IDE

# Option 2: Manual git pull
cd ~/.gemini/config/consolidated-skills
git pull
```

---

## Installer Package Contents

```
skills-installer/
├── install.bat              # Windows installer
├── install.sh               # WSL/Linux installer
├── skills_mcp_server.py     # MCP server (copied during install)
└── README.md                # This file
```

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `0 skills loaded` | Server can't find the skills directory. Run `install.sh` to fix paths |
| `Permission denied` on git clone | Set up GitHub credentials: `git config --global credential.helper store` |
| Skills count differs between machines | Run `sync_skills` or `git pull` on both machines |
| UTF-8 BOM error | Already handled in v3.0.0 — update your `skills_mcp_server.py` |
| WSL path not found | The installer auto-patches for native Linux. Re-run `install.sh` |

---

## Architecture

```
┌─────────────────────────────────────────────────┐
│                GitHub Repository                 │
│    github.com/manoelbenicio/skills.git           │
│              (source of truth)                   │
└─────────────────┬───────────────────┬────────────┘
                  │ git clone/pull    │ git clone/pull
                  ▼                   ▼
    ┌──────────────────┐   ┌──────────────────┐
    │   HP Laptop       │   │   MSI Laptop      │
    │   wsl-dataops-labs│   │   msi-laptop       │
    │                   │   │                    │
    │ consolidated-     │   │ consolidated-      │
    │ skills/ (1,539)   │   │ skills/ (1,448)    │
    │        │          │   │        │           │
    │ skills_mcp_server │   │ skills_mcp_server  │
    │   (Python 3.14)   │   │   (Python 3.12)    │
    │   Windows + WSL   │   │   WSL native       │
    └──────────────────┘   └──────────────────┘
              ▲                       ▲
              │    Tailscale VPN      │
              └───────────────────────┘
                        ▲
                        │
               ┌────────────────┐
               │   iPad (Blink)  │
               │   SSH access    │
               └────────────────┘
```
