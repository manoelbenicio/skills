#!/bin/bash
# ============================================================
#  Skills MCP Server - Installer for WSL / Linux
#  Run this on any new WSL instance or Linux machine
# ============================================================

set -e

echo "============================================================"
echo " Skills MCP Server Installer v1.0"
echo " Repository: github.com/manoelbenicio/skills.git"
echo "============================================================"
echo ""

# --- Configuration ---
SKILLS_DIR="$HOME/.gemini/config/consolidated-skills"
MCP_DIR="$HOME/.gemini/antigravity-ide/scratch"
MCP_SERVER="$MCP_DIR/skills_mcp_server.py"
SKILLS_TXT="$HOME/.gemini/antigravity/skills.txt"
REPO_URL="https://github.com/manoelbenicio/skills.git"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Step 1: Check Python ---
echo "[1/6] Checking Python..."
if command -v python3 &>/dev/null; then
    echo "  $(python3 --version)"
else
    echo "  ERROR: Python 3 not found. Install with: sudo apt install python3"
    exit 1
fi
echo ""

# --- Step 2: Check Git ---
echo "[2/6] Checking Git..."
if command -v git &>/dev/null; then
    echo "  $(git --version)"
else
    echo "  ERROR: Git not found. Install with: sudo apt install git"
    exit 1
fi
echo ""

# --- Step 3: Clone or update skills repo ---
echo "[3/6] Setting up skills repository..."
if [ -d "$SKILLS_DIR/.git" ]; then
    echo "  Repository exists. Pulling latest..."
    cd "$SKILLS_DIR"
    git pull --ff-only || echo "  Pull failed (non-fatal, using local copy)"
else
    echo "  Cloning repository (this may take a few minutes)..."
    mkdir -p "$(dirname "$SKILLS_DIR")"
    git clone "$REPO_URL" "$SKILLS_DIR"
fi
SKILL_COUNT=$(find "$SKILLS_DIR" -maxdepth 1 -mindepth 1 -type d ! -name '.*' | wc -l)
echo "  Done. $SKILL_COUNT skill folders."
echo ""

# --- Step 4: Install MCP server ---
echo "[4/6] Installing MCP server..."
mkdir -p "$MCP_DIR"
cp "$SCRIPT_DIR/skills_mcp_server.py" "$MCP_SERVER"
chmod +x "$MCP_SERVER"
echo "  Installed at: $MCP_SERVER"
echo ""

# --- Step 5: Detect environment and patch paths if needed ---
echo "[5/6] Configuring for this environment..."
IS_WSL=false
if [ -f /proc/version ] && grep -qi microsoft /proc/version; then
    IS_WSL=true
fi

# Check if the Windows /mnt/c path resolves (WSL under Windows host)
if [ "$IS_WSL" = true ] && [ -d "/mnt/c/Users" ]; then
    echo "  Detected: WSL under Windows host"
    echo "  Using /mnt/c/ path translation (built into server)"
else
    echo "  Detected: Native Linux / standalone WSL"
    echo "  Patching server for native Linux paths..."
    python3 -c "
import pathlib
server = pathlib.Path('$MCP_SERVER')
content = server.read_text()
old = '''SKILL_DIRS_WIN = [
    (r\"C:\\\\Users\\\\mbenicios\\\\.gemini\\\\config\\\\consolidated-skills\", \"consolidated-skills\", 10),
]'''
new = '''SKILL_DIRS_WIN = [
    (r\"C:\\\\Users\\\\mbenicios\\\\.gemini\\\\config\\\\consolidated-skills\", \"consolidated-skills\", 10),
]

# Override for native Linux (not WSL under /mnt/c)
import pathlib
_native_skills = str(pathlib.Path.home() / '.gemini/config/consolidated-skills')
if pathlib.Path(_native_skills).is_dir():
    SKILL_DIRS_WIN = [(_native_skills, 'consolidated-skills', 10)]
    SKILLS_REPO_WIN = _native_skills'''
content = content.replace(old, new)
server.write_text(content)
print('  Patched!')
"
fi
echo ""

# --- Step 6: Create skills.txt ---
echo "[6/6] Creating skills.txt..."
mkdir -p "$(dirname "$SKILLS_TXT")"
echo "$SKILLS_DIR/" > "$SKILLS_TXT"
echo "  Created at: $SKILLS_TXT"
echo ""

# --- Test ---
echo "============================================================"
echo " Running verification test..."
echo "============================================================"
echo ""
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","clientInfo":{"name":"test","version":"1.0"},"capabilities":{}}}'
STATS='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_registry_stats","arguments":{}}}'

echo "${INIT}
${STATS}" | python3 "$MCP_SERVER" 2>&1 | grep -E "(Ready|total_skills|Platform|skills from)"

echo ""
echo "============================================================"
echo " INSTALLATION COMPLETE"
echo "============================================================"
echo ""
echo " Skills:     $SKILLS_DIR (git-synced)"
echo " MCP Server: $MCP_SERVER"
echo " Config:     $SKILLS_TXT"
echo ""
echo " To run the MCP server:"
echo "   python3 $MCP_SERVER"
echo ""
echo " To add to your IDE MCP config:"
echo '   "skills-consolidator": {'
echo "     \"command\": \"python3\","
echo "     \"args\": [\"$MCP_SERVER\"]"
echo '   }'
echo ""
