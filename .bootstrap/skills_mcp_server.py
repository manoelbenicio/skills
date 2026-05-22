#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Consolidated Skills MCP Server v2.0.0
======================================
A zero-dependency Python MCP server (JSON-RPC over stdio) that:
  1. Scans a Git-synced skills repository for all available skills
  2. Consolidates them in-memory with fast search/retrieval
  3. Provides Git sync tools (pull/push) for multi-machine workflows
  4. Auto-pulls from GitHub on startup to stay current

The IDE registers this as an MCP server and calls tools on-demand,
so skills never consume context window space.

Protocol: MCP (Model Context Protocol) over stdio
Transport: JSON-RPC 2.0 via stdin/stdout
Dependencies: Python 3.10+ standard library only (+ git CLI for sync)
Repository: https://github.com/manoelbenicio/skills.git
"""

import sys
import json
import os
import re
import subprocess
import threading
import shutil

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# The Git-synced skills repository (source of truth)
SKILLS_REPO_WIN = r"C:\Users\mbenicios\.gemini\config\consolidated-skills"
SKILLS_REPO_URL = "https://github.com/manoelbenicio/skills.git"

# Additional directories to scan (IDE-installed skills, plugins)
EXTRA_DIRS_WIN = [
    r"C:\Users\mbenicios\.gemini\config\skills",
    r"C:\Users\mbenicios\.gemini\config\plugins",
]

# Whether we are running inside WSL
IS_WSL = False
try:
    IS_WSL = os.path.exists("/proc/version") and "microsoft" in open("/proc/version").read().lower()
except Exception:
    pass


def to_wsl_path(win_path):
    """Convert a Windows path to a WSL /mnt/ path."""
    if not win_path:
        return ""
    win_path = win_path.replace("\\", "/")
    match = re.match(r"^([a-zA-Z]):", win_path)
    if match:
        drive = match.group(1).lower()
        return f"/mnt/{drive}{win_path[2:]}"
    return win_path


def resolve_path(win_path):
    """Return the correct path depending on whether we are in WSL or Windows."""
    if IS_WSL:
        return to_wsl_path(win_path)
    return win_path


# ---------------------------------------------------------------------------
# Logging (stderr only, to keep stdout clean for JSON-RPC)
# ---------------------------------------------------------------------------

def log(msg):
    """Log to stderr so it doesn't interfere with JSON-RPC on stdout."""
    print(f"[skills-mcp] {msg}", file=sys.stderr, flush=True)


# ---------------------------------------------------------------------------
# Git Operations
# ---------------------------------------------------------------------------

def run_git(args, cwd):
    """Run a git command and return (success, output)."""
    try:
        result = subprocess.run(
            ["git"] + args,
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=60,
        )
        output = result.stdout.strip()
        if result.returncode != 0:
            error = result.stderr.strip()
            return False, error or output
        return True, output
    except subprocess.TimeoutExpired:
        return False, "Git command timed out (60s)"
    except FileNotFoundError:
        return False, "git is not installed or not in PATH"
    except Exception as e:
        return False, str(e)


def git_auto_pull(repo_path):
    """Background auto-pull on startup (non-blocking)."""
    if not os.path.isdir(os.path.join(repo_path, ".git")):
        log(f"Auto-pull skipped: {repo_path} is not a git repo")
        return

    log(f"Auto-pull: pulling latest from origin...")
    success, output = run_git(["pull", "--ff-only", "--no-rebase"], repo_path)
    if success:
        log(f"Auto-pull: {output or 'Already up to date.'}")
    else:
        log(f"Auto-pull: failed (non-fatal): {output}")


# ---------------------------------------------------------------------------
# Skill Registry
# ---------------------------------------------------------------------------

class SkillRegistry:
    """In-memory registry of all discovered skills."""

    def __init__(self):
        self.skills = {}       # name -> skill_info dict
        self.repo_path = ""    # resolved repo path
        self._scan()

    def _parse_frontmatter(self, skill_md_path):
        """Parse YAML frontmatter from a SKILL.md file."""
        name = None
        description = ""
        risk = "unknown"
        source_type = "unknown"

        try:
            with open(skill_md_path, "r", encoding="utf-8", errors="ignore") as f:
                content = f.read(8192)  # Read only first 8KB for metadata

            match = re.match(r"^---\s*\n(.*?)\n---\s*\n", content, re.DOTALL)
            if match:
                yaml_block = match.group(1)
                for line in yaml_block.split("\n"):
                    if ":" in line:
                        key, val = line.split(":", 1)
                        key = key.strip().lower()
                        val = val.strip().strip('"').strip("'")
                        if key == "name":
                            name = val
                        elif key == "description":
                            description = val
                        elif key == "risk":
                            risk = val
                        elif key == "source":
                            source_type = val

            if not name:
                name = os.path.basename(os.path.dirname(skill_md_path))

            if not description:
                body = content[match.end():] if match else content
                for line in body.split("\n"):
                    stripped = line.strip()
                    if stripped and not stripped.startswith("---"):
                        description = stripped.lstrip("#").strip()[:200]
                        break

            return {
                "name": name,
                "description": description,
                "risk": risk,
                "source_type": source_type,
                "skill_md_path": skill_md_path,
            }
        except Exception as e:
            log(f"Error parsing {skill_md_path}: {e}")
            return None

    def _scan_directory(self, base_dir, source_label, priority=0):
        """Scan a directory for skill folders containing SKILL.md."""
        if not os.path.isdir(base_dir):
            log(f"  Directory not found, skipping: {base_dir}")
            return 0

        count = 0
        try:
            entries = os.listdir(base_dir)
        except PermissionError:
            log(f"  Permission denied: {base_dir}")
            return 0

        for entry in entries:
            if entry.startswith("."):
                continue

            entry_path = os.path.join(base_dir, entry)
            if not os.path.isdir(entry_path):
                continue

            # Direct SKILL.md
            skill_md = os.path.join(entry_path, "SKILL.md")
            if os.path.isfile(skill_md):
                info = self._parse_frontmatter(skill_md)
                if info:
                    skill_name = info["name"]
                    if skill_name not in self.skills or priority > self.skills[skill_name].get("_priority", 0):
                        info["source_dir"] = source_label
                        info["folder_name"] = entry
                        info["_priority"] = priority
                        self.skills[skill_name] = info
                        count += 1
                continue

            # Nested plugin structure: entry/skills/*/SKILL.md
            skills_subdir = os.path.join(entry_path, "skills")
            if os.path.isdir(skills_subdir):
                try:
                    for sub_entry in os.listdir(skills_subdir):
                        sub_path = os.path.join(skills_subdir, sub_entry)
                        if os.path.isdir(sub_path):
                            nested_md = os.path.join(sub_path, "SKILL.md")
                            if os.path.isfile(nested_md):
                                info = self._parse_frontmatter(nested_md)
                                if info:
                                    skill_name = info["name"]
                                    if skill_name not in self.skills or priority > self.skills[skill_name].get("_priority", 0):
                                        info["source_dir"] = f"{source_label}/{entry}"
                                        info["folder_name"] = sub_entry
                                        info["_priority"] = priority
                                        self.skills[skill_name] = info
                                        count += 1
                except PermissionError:
                    log(f"  Permission denied: {skills_subdir}")

        return count

    def _scan(self):
        """Scan all configured directories."""
        self.repo_path = resolve_path(SKILLS_REPO_WIN)

        # Scan the Git repo (highest priority = 10)
        log(f"Scanning repo: {self.repo_path}")
        repo_count = self._scan_directory(self.repo_path, "repo:consolidated-skills", priority=10)
        log(f"  -> {repo_count} skills from repo")

        # Scan extra dirs (lower priority = 1)
        for win_dir in EXTRA_DIRS_WIN:
            d = resolve_path(win_dir)
            label = os.path.basename(d)
            log(f"Scanning: {d}")
            extra_count = self._scan_directory(d, f"local:{label}", priority=1)
            log(f"  -> {extra_count} skills from {label}")

        log(f"Registry loaded: {len(self.skills)} total unique skills")

    def refresh(self):
        """Re-scan all directories."""
        self.skills.clear()
        self._scan()

    def list_all(self, source_filter=None):
        """Return a summary list of all skills."""
        result = []
        for name, info in sorted(self.skills.items()):
            if source_filter and source_filter not in info["source_dir"]:
                continue
            result.append({
                "name": name,
                "description": info["description"],
                "source_dir": info["source_dir"],
            })
        return result

    def search(self, query):
        """Search skills by name or description (case-insensitive)."""
        query_lower = query.lower()
        tokens = query_lower.split()
        results = []

        for name, info in self.skills.items():
            name_lower = name.lower()
            desc_lower = info["description"].lower()
            combined = f"{name_lower} {desc_lower}"

            # All tokens must match somewhere
            if all(t in combined for t in tokens):
                # Score: name match is worth more
                score = sum(2 if t in name_lower else 1 for t in tokens)
                results.append({
                    "name": name,
                    "description": info["description"],
                    "source_dir": info["source_dir"],
                    "score": score,
                })

        results.sort(key=lambda x: (-x["score"], x["name"]))
        return results[:50]  # Cap at 50 results

    def get_instructions(self, skill_name):
        """Read and return the full SKILL.md content for a given skill."""
        info = self.skills.get(skill_name)
        if not info:
            # Fuzzy match: case-insensitive
            for name in self.skills:
                if skill_name.lower() == name.lower():
                    info = self.skills[name]
                    break
        if not info:
            # Fuzzy match: partial
            for name in self.skills:
                if skill_name.lower() in name.lower():
                    info = self.skills[name]
                    break
        if not info:
            return None

        try:
            with open(info["skill_md_path"], "r", encoding="utf-8", errors="ignore") as f:
                return {
                    "name": info["name"],
                    "description": info["description"],
                    "source_dir": info["source_dir"],
                    "content": f.read(),
                }
        except Exception as e:
            return {"error": f"Failed to read skill: {e}"}

    def get_stats(self):
        """Return statistics about the registry."""
        sources = {}
        for info in self.skills.values():
            src = info["source_dir"]
            sources[src] = sources.get(src, 0) + 1
        return {
            "total_skills": len(self.skills),
            "by_source": dict(sorted(sources.items(), key=lambda x: -x[1])),
        }

    def consolidate(self, extra_scan_dirs=None):
        """
        Scan scattered directories for skills and MOVE unique ones
        into the centralized repo. Deduplicates by skill folder name.
        Returns a report of what was moved/skipped.
        """
        # Directories to scan for orphaned skills to consolidate
        scan_dirs = [resolve_path(d) for d in EXTRA_DIRS_WIN]
        if extra_scan_dirs:
            scan_dirs.extend(extra_scan_dirs)

        repo_path = self.repo_path
        if not os.path.isdir(repo_path):
            return {"error": f"Repo path does not exist: {repo_path}"}

        # Get existing folder names in the repo
        existing_folders = set()
        try:
            for entry in os.listdir(repo_path):
                if not entry.startswith(".") and os.path.isdir(os.path.join(repo_path, entry)):
                    existing_folders.add(entry.lower())
        except PermissionError:
            return {"error": f"Permission denied reading repo: {repo_path}"}

        moved = []
        skipped_duplicate = []
        skipped_error = []

        for scan_dir in scan_dirs:
            if not os.path.isdir(scan_dir):
                continue

            try:
                entries = os.listdir(scan_dir)
            except PermissionError:
                skipped_error.append(f"Permission denied: {scan_dir}")
                continue

            for entry in entries:
                if entry.startswith("."):
                    continue

                src_path = os.path.join(scan_dir, entry)
                if not os.path.isdir(src_path):
                    continue

                # Check if it has a SKILL.md
                skill_md = os.path.join(src_path, "SKILL.md")
                if not os.path.isfile(skill_md):
                    # Check plugin nested structure
                    skills_subdir = os.path.join(src_path, "skills")
                    if os.path.isdir(skills_subdir):
                        try:
                            for sub in os.listdir(skills_subdir):
                                sub_path = os.path.join(skills_subdir, sub)
                                if os.path.isdir(sub_path) and os.path.isfile(os.path.join(sub_path, "SKILL.md")):
                                    if sub.lower() in existing_folders:
                                        skipped_duplicate.append(sub)
                                    else:
                                        dest = os.path.join(repo_path, sub)
                                        try:
                                            shutil.copytree(sub_path, dest)
                                            existing_folders.add(sub.lower())
                                            moved.append({"name": sub, "from": scan_dir})
                                            log(f"  Consolidated: {sub} -> repo")
                                        except Exception as e:
                                            skipped_error.append(f"{sub}: {e}")
                        except PermissionError:
                            pass
                    continue

                # It has a SKILL.md directly
                if entry.lower() in existing_folders:
                    skipped_duplicate.append(entry)
                else:
                    dest = os.path.join(repo_path, entry)
                    try:
                        shutil.copytree(src_path, dest)
                        existing_folders.add(entry.lower())
                        moved.append({"name": entry, "from": scan_dir})
                        log(f"  Consolidated: {entry} -> repo")
                    except Exception as e:
                        skipped_error.append(f"{entry}: {e}")

        # Refresh registry after consolidation
        if moved:
            self.refresh()

        return {
            "moved_count": len(moved),
            "moved": moved,
            "skipped_duplicate_count": len(skipped_duplicate),
            "skipped_duplicates": skipped_duplicate[:20],  # Cap output
            "errors": skipped_error,
            "total_skills_after": len(self.skills),
        }


# ---------------------------------------------------------------------------
# MCP Tool Definitions
# ---------------------------------------------------------------------------

TOOL_DEFINITIONS = [
    {
        "name": "list_skills",
        "description": "List all consolidated skills with names, descriptions, and source. Supports optional source_filter to show only repo or local skills.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "source_filter": {
                    "type": "string",
                    "description": "Optional filter: 'repo' for GitHub-synced skills, 'local' for IDE-installed skills. Omit to list all.",
                }
            },
            "required": [],
        },
    },
    {
        "name": "search_skills",
        "description": "Search for skills by keyword(s). Matches against names and descriptions. Multi-word queries require all words to match. Returns top 50 ranked results.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Search query (supports multiple space-separated keywords).",
                }
            },
            "required": ["query"],
        },
    },
    {
        "name": "get_skill_instructions",
        "description": "Retrieve the full SKILL.md content for a specific skill. Supports fuzzy name matching. Use after finding the skill via list_skills or search_skills.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "skill_name": {
                    "type": "string",
                    "description": "Name of the skill to retrieve (case-insensitive, partial match supported).",
                }
            },
            "required": ["skill_name"],
        },
    },
    {
        "name": "get_registry_stats",
        "description": "Get statistics: total skill count, breakdown by source directory.",
        "inputSchema": {
            "type": "object",
            "properties": {},
            "required": [],
        },
    },
    {
        "name": "sync_skills",
        "description": "Pull the latest skills from the GitHub repository (git pull). Use to update the local skills to the latest version from the source of truth.",
        "inputSchema": {
            "type": "object",
            "properties": {},
            "required": [],
        },
    },
    {
        "name": "push_skills",
        "description": "Stage, commit, and push local skill changes to the GitHub repository. Use after creating or modifying skills locally to share them across machines.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "message": {
                    "type": "string",
                    "description": "Commit message describing the changes.",
                }
            },
            "required": ["message"],
        },
    },
    {
        "name": "git_status",
        "description": "Show the current git status of the skills repository (modified, new, deleted files).",
        "inputSchema": {
            "type": "object",
            "properties": {},
            "required": [],
        },
    },
    {
        "name": "refresh_registry",
        "description": "Re-scan all skill directories and refresh the in-memory registry. Use after adding, modifying, or syncing skills.",
        "inputSchema": {
            "type": "object",
            "properties": {},
            "required": [],
        },
    },
    {
        "name": "consolidate_skills",
        "description": "Scan scattered skill directories (IDE-installed, plugins) for unique skills and COPY them into the centralized Git repository. Deduplicates by folder name. Use to organize all skills into a single source of truth.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "extra_dirs": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Optional list of additional Windows paths to scan for skills (e.g. 'C:\\\\path\\\\to\\\\skills').",
                }
            },
            "required": [],
        },
    },
]

SERVER_INFO = {
    "name": "skills-consolidator",
    "version": "2.0.0",
}

CAPABILITIES = {
    "tools": {},
}


# ---------------------------------------------------------------------------
# Request Handler
# ---------------------------------------------------------------------------

def handle_request(method, params, registry):
    """Handle an incoming JSON-RPC request and return the result."""

    # --- MCP Lifecycle ---
    if method == "initialize":
        return {
            "protocolVersion": "2024-11-05",
            "serverInfo": SERVER_INFO,
            "capabilities": CAPABILITIES,
        }

    if method == "notifications/initialized":
        return None

    if method == "ping":
        return {}

    # --- Tool Discovery ---
    if method == "tools/list":
        return {"tools": TOOL_DEFINITIONS}

    # --- Tool Execution ---
    if method == "tools/call":
        tool_name = params.get("name", "")
        arguments = params.get("arguments", {})

        if tool_name == "list_skills":
            source_filter = arguments.get("source_filter", None)
            skills_list = registry.list_all(source_filter)
            text = json.dumps(skills_list, indent=2, ensure_ascii=False)
            return {
                "content": [{"type": "text", "text": f"{len(skills_list)} skills found:\n{text}"}],
                "isError": False,
            }

        elif tool_name == "search_skills":
            query = arguments.get("query", "")
            if not query:
                return _error_result("'query' parameter is required.")
            results = registry.search(query)
            text = json.dumps(results, indent=2, ensure_ascii=False)
            return {
                "content": [{"type": "text", "text": f"{len(results)} matching skills:\n{text}"}],
                "isError": False,
            }

        elif tool_name == "get_skill_instructions":
            skill_name = arguments.get("skill_name", "")
            if not skill_name:
                return _error_result("'skill_name' parameter is required.")
            result = registry.get_instructions(skill_name)
            if result is None:
                # Suggest close matches
                suggestions = registry.search(skill_name)[:5]
                suggestion_names = [s["name"] for s in suggestions]
                return _error_result(
                    f"Skill '{skill_name}' not found. Did you mean: {', '.join(suggestion_names)}"
                )
            text = json.dumps(result, indent=2, ensure_ascii=False)
            return {
                "content": [{"type": "text", "text": text}],
                "isError": False,
            }

        elif tool_name == "get_registry_stats":
            stats = registry.get_stats()
            text = json.dumps(stats, indent=2, ensure_ascii=False)
            return {
                "content": [{"type": "text", "text": text}],
                "isError": False,
            }

        elif tool_name == "sync_skills":
            repo_path = registry.repo_path
            if not os.path.isdir(os.path.join(repo_path, ".git")):
                return _error_result(f"Not a git repo: {repo_path}")
            success, output = run_git(["pull", "--ff-only", "--no-rebase"], repo_path)
            if success:
                registry.refresh()
                stats = registry.get_stats()
                text = f"Git pull successful: {output}\n\nRegistry refreshed:\n{json.dumps(stats, indent=2)}"
                return {"content": [{"type": "text", "text": text}], "isError": False}
            else:
                return _error_result(f"Git pull failed: {output}")

        elif tool_name == "push_skills":
            message = arguments.get("message", "")
            if not message:
                return _error_result("'message' parameter is required.")
            repo_path = registry.repo_path
            if not os.path.isdir(os.path.join(repo_path, ".git")):
                return _error_result(f"Not a git repo: {repo_path}")

            # Stage all changes
            success, output = run_git(["add", "-A"], repo_path)
            if not success:
                return _error_result(f"Git add failed: {output}")

            # Check if there's anything to commit
            success, status = run_git(["status", "--porcelain"], repo_path)
            if success and not status.strip():
                return {"content": [{"type": "text", "text": "Nothing to commit. Working tree clean."}], "isError": False}

            # Commit
            success, output = run_git(["commit", "-m", message], repo_path)
            if not success:
                return _error_result(f"Git commit failed: {output}")

            # Push
            success, output = run_git(["push"], repo_path)
            if success:
                return {"content": [{"type": "text", "text": f"Pushed successfully:\n{output}"}], "isError": False}
            else:
                return _error_result(f"Git push failed: {output}")

        elif tool_name == "git_status":
            repo_path = registry.repo_path
            if not os.path.isdir(os.path.join(repo_path, ".git")):
                return _error_result(f"Not a git repo: {repo_path}")
            success, status = run_git(["status", "--short"], repo_path)
            if success:
                if not status.strip():
                    status = "Working tree clean. No pending changes."
                # Also get branch info
                _, branch = run_git(["branch", "--show-current"], repo_path)
                _, remote = run_git(["remote", "-v"], repo_path)
                text = f"Branch: {branch}\nRemote:\n{remote}\n\nStatus:\n{status}"
                return {"content": [{"type": "text", "text": text}], "isError": False}
            else:
                return _error_result(f"Git status failed: {status}")

        elif tool_name == "refresh_registry":
            registry.refresh()
            stats = registry.get_stats()
            text = f"Registry refreshed.\n{json.dumps(stats, indent=2, ensure_ascii=False)}"
            return {"content": [{"type": "text", "text": text}], "isError": False}

        elif tool_name == "consolidate_skills":
            extra_dirs_win = arguments.get("extra_dirs", [])
            extra_dirs = [resolve_path(d) for d in extra_dirs_win] if extra_dirs_win else []
            report = registry.consolidate(extra_dirs)
            text = json.dumps(report, indent=2, ensure_ascii=False)
            return {
                "content": [{"type": "text", "text": f"Consolidation complete:\n{text}"}],
                "isError": False,
            }

        else:
            return _error_result(f"Unknown tool: {tool_name}")

    # Unknown method
    return {"error": {"code": -32601, "message": f"Method not found: {method}"}}


def _error_result(message):
    """Create an MCP error result."""
    return {
        "content": [{"type": "text", "text": f"Error: {message}"}],
        "isError": True,
    }


# ---------------------------------------------------------------------------
# JSON-RPC Transport
# ---------------------------------------------------------------------------

def send_response(response_id, result):
    """Send a JSON-RPC response to stdout."""
    response = {"jsonrpc": "2.0", "id": response_id, "result": result}
    msg = json.dumps(response, ensure_ascii=False)
    sys.stdout.write(msg + "\n")
    sys.stdout.flush()


def send_error(response_id, code, message):
    """Send a JSON-RPC error response to stdout."""
    response = {"jsonrpc": "2.0", "id": response_id, "error": {"code": code, "message": message}}
    msg = json.dumps(response, ensure_ascii=False)
    sys.stdout.write(msg + "\n")
    sys.stdout.flush()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    """Main event loop: read JSON-RPC messages from stdin, process, respond."""
    log("=" * 60)
    log("Consolidated Skills MCP Server v2.0.0")
    log(f"Running in WSL: {IS_WSL}")
    log(f"Repo: {SKILLS_REPO_URL}")
    log("=" * 60)

    # Resolve the repo path
    repo_path = resolve_path(SKILLS_REPO_WIN)

    # Auto-pull in background thread (non-blocking)
    if os.path.isdir(os.path.join(repo_path, ".git")):
        pull_thread = threading.Thread(target=git_auto_pull, args=(repo_path,), daemon=True)
        pull_thread.start()

    # Initialize the skill registry (scans disk)
    registry = SkillRegistry()
    log(f"Ready. {len(registry.skills)} skills loaded.")
    log("Listening for JSON-RPC requests on stdin...")

    # Read JSON-RPC messages line by line from stdin
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            request = json.loads(line)
        except json.JSONDecodeError as e:
            log(f"Invalid JSON: {e}")
            send_error(None, -32700, f"Parse error: {e}")
            continue

        request_id = request.get("id")
        method = request.get("method", "")
        params = request.get("params", {})

        log(f"<-- {method} (id={request_id})")

        try:
            result = handle_request(method, params, registry)

            if request_id is None:
                continue

            if result is None:
                send_response(request_id, {})
            elif isinstance(result, dict) and "error" in result and isinstance(result["error"], dict):
                send_error(request_id, result["error"]["code"], result["error"]["message"])
            else:
                send_response(request_id, result)

        except Exception as e:
            log(f"Error handling {method}: {e}")
            if request_id is not None:
                send_error(request_id, -32603, f"Internal error: {e}")


if __name__ == "__main__":
    main()
