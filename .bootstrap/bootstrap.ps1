#Requires -Version 5.1
<#
.SYNOPSIS
    Antigravity IDE Bootstrap - Ephemeral Machine Provisioner
.DESCRIPTION
    One-script provisioning of the complete Antigravity IDE development environment.
    Designed for machines rebuilt from scratch daily.

    What it does:
      1. Validates prerequisites (git, node/npx, WSL + Python3)
      2. Clones or pulls the skills Git repository
      3. Deploys the skills-consolidator MCP server (Python)
      4. Deploys IDE configuration files (mcp_config.json, config.json)
      5. Creates symlinks for locally-active skills
      6. Runs verification checks

    Invocation (fresh machine):
      irm https://raw.githubusercontent.com/manoelbenicio/skills/main/.bootstrap/bootstrap.ps1 | iex

    Or with a GitHub PAT for private repos:
      $env:GITHUB_PAT = "ghp_xxxxx"; irm "https://raw.githubusercontent.com/manoelbenicio/skills/main/.bootstrap/bootstrap.ps1" | iex

.NOTES
    Author: Manoel Benicio (bootstrapped by Antigravity AI)
    Version: 1.0.0
    Repo: https://github.com/manoelbenicio/skills
#>

[CmdletBinding()]
param(
    # GitHub Personal Access Token (overrides $env:GITHUB_PAT)
    [string]$GitHubPAT = $env:GITHUB_PAT,

    # StitchMCP API Key (overrides $env:STITCH_API_KEY)
    [string]$StitchApiKey = $env:STITCH_API_KEY,

    # Skip interactive prompts (for CI/automation)
    [switch]$NonInteractive,

    # Only check prerequisites, don't install anything
    [switch]$CheckOnly,

    # Force re-deploy even if files already exist
    [switch]$Force
)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$ErrorActionPreference = "Stop"
$script:REPO_URL_SSH   = "git@github.com:manoelbenicio/skills.git"
$script:REPO_URL_HTTPS = "https://github.com/manoelbenicio/skills.git"
$script:GEMINI_CONFIG  = Join-Path $env:USERPROFILE ".gemini\config"
$script:REPO_DIR       = Join-Path $script:GEMINI_CONFIG "consolidated-skills"
$script:SKILLS_DIR     = Join-Path $script:GEMINI_CONFIG "skills"
$script:BOOTSTRAP_DIR  = Join-Path $script:REPO_DIR ".bootstrap"
$script:SCRATCH_DIR    = Join-Path $env:USERPROFILE ".gemini\antigravity-ide\scratch"
$script:MCP_SERVER_PY  = Join-Path $script:SCRATCH_DIR "skills_mcp_server.py"

# Counters for summary
$script:StepsTotal   = 0
$script:StepsPassed  = 0
$script:StepsFailed  = 0
$script:StepsSkipped = 0
$script:Warnings     = @()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Banner {
    $banner = @"

    ╔══════════════════════════════════════════════════════════════╗
    ║                                                              ║
    ║       █████╗ ███╗   ██╗████████╗██╗ ██████╗                  ║
    ║      ██╔══██╗████╗  ██║╚══██╔══╝██║██╔════╝                  ║
    ║      ███████║██╔██╗ ██║   ██║   ██║██║  ███╗                 ║
    ║      ██╔══██║██║╚██╗██║   ██║   ██║██║   ██║                 ║
    ║      ██║  ██║██║ ╚████║   ██║   ██║╚██████╔╝                 ║
    ║      ╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝   ╚═╝ ╚═════╝                ║
    ║                                                              ║
    ║      Antigravity IDE · Ephemeral Bootstrap v1.0.0            ║
    ║      github.com/manoelbenicio/skills                         ║
    ║                                                              ║
    ╠══════════════════════════════════════════════════════════════╣
    ║  Target: $($env:COMPUTERNAME.PadRight(50))║
    ║  User:   $($env:USERNAME.PadRight(50))║
    ║  Time:   $((Get-Date -Format 'yyyy-MM-dd HH:mm:ss').PadRight(50))║
    ╚══════════════════════════════════════════════════════════════╝

"@
    Write-Host $banner -ForegroundColor Cyan
}

function Write-Step {
    param([string]$Message, [string]$Status = "RUN")
    $script:StepsTotal++
    $icon = switch ($Status) {
        "RUN"   { "⏳" }
        "OK"    { "✅" }
        "FAIL"  { "❌" }
        "SKIP"  { "⏭️" }
        "WARN"  { "⚠️" }
        default { "  " }
    }
    $color = switch ($Status) {
        "RUN"   { "Yellow" }
        "OK"    { "Green" }
        "FAIL"  { "Red" }
        "SKIP"  { "DarkGray" }
        "WARN"  { "DarkYellow" }
        default { "White" }
    }
    Write-Host "  $icon  " -NoNewline
    Write-Host $Message -ForegroundColor $color
}

function Write-SubStep {
    param([string]$Message)
    Write-Host "       └─ $Message" -ForegroundColor DarkGray
}

function Step-Ok   { param([string]$Msg) $script:StepsPassed++;  Write-Step $Msg "OK" }
function Step-Fail { param([string]$Msg) $script:StepsFailed++;  Write-Step $Msg "FAIL"; $script:Warnings += $Msg }
function Step-Skip { param([string]$Msg) $script:StepsSkipped++; Write-Step $Msg "SKIP" }
function Step-Warn { param([string]$Msg) Write-Step $Msg "WARN"; $script:Warnings += $Msg }

function Test-CommandExists {
    param([string]$Command)
    $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

function Resolve-WSLPath {
    param([string]$WinPath)
    $p = $WinPath.Replace("\", "/")
    if ($p -match '^([a-zA-Z]):') {
        $drive = $Matches[1].ToLower()
        return "/mnt/$drive$($p.Substring(2))"
    }
    return $p
}

# ---------------------------------------------------------------------------
# Phase 1: Preflight Checks
# ---------------------------------------------------------------------------

function Invoke-PreflightChecks {
    Write-Host ""
    Write-Host "  ── Phase 1: Preflight Checks ──────────────────────────────" -ForegroundColor Magenta
    Write-Host ""

    # Git
    Write-Step "Checking git..." "RUN"
    if (Test-CommandExists "git") {
        $gitVer = (git --version 2>$null) -replace "git version ", ""
        Step-Ok "git $gitVer"
    } else {
        Step-Fail "git not found. Install: https://git-scm.com/download/win"
        return $false
    }

    # Node.js
    Write-Step "Checking node..." "RUN"
    if (Test-CommandExists "node") {
        $nodeVer = (node --version 2>$null)
        Step-Ok "node $nodeVer"
    } else {
        Step-Fail "node not found. Install: https://nodejs.org/"
        return $false
    }

    # npx
    Write-Step "Checking npx..." "RUN"
    if (Test-CommandExists "npx") {
        Step-Ok "npx available"
    } else {
        Step-Fail "npx not found. Usually comes with Node.js."
        return $false
    }

    # WSL
    Write-Step "Checking WSL..." "RUN"
    if (Test-CommandExists "wsl") {
        try {
            $wslRaw = wsl --list --quiet 2>$null
            # WSL outputs UTF-16LE with null bytes - clean them
            $wslClean = ($wslRaw | ForEach-Object { $_ -replace "`0", "" }) -join " "
            if ($wslClean -match "Ubuntu") {
                Step-Ok "WSL with Ubuntu detected"
            } else {
                Step-Warn "WSL found but Ubuntu distro not detected. Available: $wslClean"
            }
        } catch {
            Step-Warn "WSL found but could not list distros"
        }
    } else {
        Step-Fail "WSL not found. Install: wsl --install"
        return $false
    }

    # Python3 in WSL
    Write-Step "Checking Python3 in WSL..." "RUN"
    try {
        $oldEAP = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $pyOutput = wsl -d Ubuntu -- python3 --version 2>&1
        $ErrorActionPreference = $oldEAP
        $pyVer = ($pyOutput | Out-String) -replace "`r|`n", " "
        if ($pyVer -match 'Python 3\.(\d+)') {
            $minor = [int]$Matches[1]
            if ($minor -ge 10) {
                Step-Ok "WSL Python 3.$minor detected"
            } else {
                Step-Warn "WSL Python 3.$minor - version 3.10 or higher recommended"
            }
        } else {
            Step-Fail "Could not determine Python version in WSL"
            return $false
        }
    } catch {
        Step-Fail "Python3 not available in WSL Ubuntu"
        return $false
    }

    # Git authentication check
    Write-Step "Checking Git authentication..." "RUN"
    $hasSSH = (Test-Path (Join-Path $env:USERPROFILE ".ssh\id_ed25519")) -or (Test-Path (Join-Path $env:USERPROFILE ".ssh\id_rsa"))

    if ($hasSSH) {
        Step-Ok "SSH keys found -- will use SSH for Git"
        $script:GitCloneUrl = $script:REPO_URL_SSH
    } elseif ($GitHubPAT) {
        Step-Ok "GitHub PAT provided -- will use HTTPS for Git"
        $script:GitCloneUrl = $script:REPO_URL_HTTPS -replace "https://", "https://${GitHubPAT}@"
    } else {
        # Try HTTPS without auth (works for public repos)
        Step-Warn "No SSH keys or PAT found - trying HTTPS, public repo only"
        $script:GitCloneUrl = $script:REPO_URL_HTTPS
    }

    return $true
}

# ---------------------------------------------------------------------------
# Phase 2: Clone/Pull Skills Repository
# ---------------------------------------------------------------------------

function Invoke-RepoSync {
    Write-Host ""
    Write-Host "  ── Phase 2: Skills Repository ─────────────────────────────" -ForegroundColor Magenta
    Write-Host ""

    # Ensure parent directory exists
    if (-not (Test-Path $script:GEMINI_CONFIG)) {
        New-Item -ItemType Directory -Path $script:GEMINI_CONFIG -Force | Out-Null
        Write-SubStep "Created $($script:GEMINI_CONFIG)"
    }

    if (Test-Path (Join-Path $script:REPO_DIR ".git")) {
        # Repo already exists -- pull
        Write-Step "Repository exists. Pulling latest..." "RUN"
        try {
            Push-Location $script:REPO_DIR
            $output = git pull --ff-only --no-rebase 2>&1
            Pop-Location
            Step-Ok "Git pull: $($output -join ' ')"
        } catch {
            Pop-Location
            Step-Warn "Git pull failed, non-fatal: $_"
        }
    } else {
        # Fresh clone
        Write-Step "Cloning skills repository..." "RUN"
        try {
            git clone $script:GitCloneUrl $script:REPO_DIR 2>&1 | Out-Null
            Step-Ok "Cloned to $($script:REPO_DIR)"
        } catch {
            Step-Fail "Git clone failed: $_"
            return $false
        }
    }

    # Verify bootstrap dir exists in the repo
    if (-not (Test-Path $script:BOOTSTRAP_DIR)) {
        Step-Fail ".bootstrap/ directory not found in repo. Is the repo up to date?"
        return $false
    }

    $skillCount = (Get-ChildItem $script:REPO_DIR -Directory | Where-Object { $_.Name -notlike '.*' }).Count
    Write-SubStep "$skillCount skill folders in repository"
    return $true
}

# ---------------------------------------------------------------------------
# Phase 3: Deploy MCP Server
# ---------------------------------------------------------------------------

function Invoke-DeployMCPServer {
    Write-Host ""
    Write-Host "  ── Phase 3: MCP Server Deployment ─────────────────────────" -ForegroundColor Magenta
    Write-Host ""

    $sourceScript = Join-Path $script:BOOTSTRAP_DIR "skills_mcp_server.py"
    $targetScript = $script:MCP_SERVER_PY

    # Ensure scratch dir exists
    if (-not (Test-Path $script:SCRATCH_DIR)) {
        New-Item -ItemType Directory -Path $script:SCRATCH_DIR -Force | Out-Null
        Write-SubStep "Created $($script:SCRATCH_DIR)"
    }

    # Deploy the Python MCP server script
    if ((Test-Path $targetScript) -and -not $Force) {
        # Check if it's the same version
        $sourceHash = (Get-FileHash $sourceScript -Algorithm SHA256).Hash
        $targetHash = (Get-FileHash $targetScript -Algorithm SHA256).Hash
        if ($sourceHash -eq $targetHash) {
            Step-Skip "skills_mcp_server.py already deployed - identical"
        } else {
            Copy-Item $sourceScript $targetScript -Force
            Step-Ok "skills_mcp_server.py updated - hash changed"
        }
    } else {
        Copy-Item $sourceScript $targetScript -Force
        Step-Ok "skills_mcp_server.py deployed to scratch/"
    }

    # Verify it can be loaded by Python in WSL
    Write-Step "Verifying MCP server loads in WSL..." "RUN"
    $wslPath = Resolve-WSLPath $targetScript
    try {
        $result = wsl -d Ubuntu -- python3 -c "import importlib.util; spec = importlib.util.spec_from_file_location('mcp', '$wslPath'); mod = importlib.util.module_from_spec(spec); print('LOAD_OK')" 2>$null
        if ($result -match "LOAD_OK") {
            Step-Ok "MCP server script loads successfully in WSL"
        } else {
            Step-Warn "MCP server script load returned unexpected output: $result"
        }
    } catch {
        Step-Warn "Could not verify MCP server in WSL: $_"
    }

    return $true
}

# ---------------------------------------------------------------------------
# Phase 4: Deploy Configuration Files
# ---------------------------------------------------------------------------

function Invoke-DeployConfigs {
    Write-Host ""
    Write-Host "  ── Phase 4: IDE Configuration ─────────────────────────────" -ForegroundColor Magenta
    Write-Host ""

    # --- mcp_config.json ---
    $mcpConfigTarget = Join-Path $script:GEMINI_CONFIG "mcp_config.json"
    $mcpConfigSource = Join-Path $script:BOOTSTRAP_DIR "mcp_config.template.json"

    Write-Step "Deploying mcp_config.json..." "RUN"

    if ((Test-Path $mcpConfigTarget) -and -not $Force) {
        # Check if it already has the skills-consolidator entry
        $existing = Get-Content $mcpConfigTarget -Raw | ConvertFrom-Json
        if ($existing.mcpServers.'skills-consolidator') {
            Step-Skip "mcp_config.json already has skills-consolidator entry"
        } else {
            # Merge: add our entries to existing config
            $template = Get-Content $mcpConfigSource -Raw
            $template = $template -replace '__SKILLS_MCP_PATH__', (Resolve-WSLPath $script:MCP_SERVER_PY)

            if ($StitchApiKey) {
                $template = $template -replace '__STITCH_API_KEY__', $StitchApiKey
            } else {
                # Keep existing StitchMCP if present, or use placeholder
                if ($existing.mcpServers.StitchMCP) {
                    $template = $template -replace '__STITCH_API_KEY__', ($existing.mcpServers.StitchMCP.args | Where-Object { $_ -match "^X-Goog-Api-Key:" } | ForEach-Object { ($_ -split ": ", 2)[1] })
                } else {
                    $template = $template -replace '__STITCH_API_KEY__', 'REPLACE_WITH_YOUR_API_KEY'
                    Step-Warn "StitchMCP API key not set. Set `$env:STITCH_API_KEY or edit mcp_config.json"
                }
            }

            Set-Content $mcpConfigTarget $template -Encoding UTF8
            Step-Ok "mcp_config.json deployed - merged with existing"
        }
    } else {
        $template = Get-Content $mcpConfigSource -Raw
        $template = $template -replace '__SKILLS_MCP_PATH__', (Resolve-WSLPath $script:MCP_SERVER_PY)

        if ($StitchApiKey) {
            $template = $template -replace '__STITCH_API_KEY__', $StitchApiKey
        } else {
            $template = $template -replace '__STITCH_API_KEY__', 'REPLACE_WITH_YOUR_API_KEY'
            Step-Warn "StitchMCP API key not set. Set `$env:STITCH_API_KEY or edit mcp_config.json"
        }

        Set-Content $mcpConfigTarget $template -Encoding UTF8
        Step-Ok "mcp_config.json deployed - fresh install"
    }

    # --- config.json ---
    $configTarget = Join-Path $script:GEMINI_CONFIG "config.json"
    $configSource = Join-Path $script:BOOTSTRAP_DIR "config.template.json"

    Write-Step "Deploying config.json..." "RUN"

    if ((Test-Path $configTarget) -and -not $Force) {
        Step-Skip "config.json already exists - preserving user settings"
    } else {
        Copy-Item $configSource $configTarget -Force
        Step-Ok "config.json deployed - base settings"
    }

    return $true
}

# ---------------------------------------------------------------------------
# Phase 5: Symlink Local Skills
# ---------------------------------------------------------------------------

function Invoke-SymlinkSkills {
    Write-Host ""
    Write-Host "  -- Phase 5: Symlink ALL Skills for @autocomplete -----------" -ForegroundColor Magenta
    Write-Host ""

    # Ensure skills dir exists
    if (-not (Test-Path $script:SKILLS_DIR)) {
        New-Item -ItemType Directory -Path $script:SKILLS_DIR -Force | Out-Null
        Write-SubStep "Created $($script:SKILLS_DIR)"
    }

    # Get ALL skill folders from repo (excluding hidden dirs like .git, .bootstrap)
    $repoSkills = Get-ChildItem $script:REPO_DIR -Directory | Where-Object { $_.Name -notlike '.*' }

    $linked  = 0
    $skipped = 0
    $failed  = 0

    foreach ($skill in $repoSkills) {
        $source = $skill.FullName
        $target = Join-Path $script:SKILLS_DIR $skill.Name

        # Check if target already exists
        if (Test-Path $target) {
            $skipped++
            continue
        }

        # Create junction (no elevation required, instant, zero disk usage)
        try {
            cmd /c mklink /J "$target" "$source" 2>$null | Out-Null
            $linked++
        } catch {
            $failed++
        }
    }

    $totalCount = (Get-ChildItem $script:SKILLS_DIR -Directory).Count
    if ($failed -eq 0) {
        Step-Ok "Skills linked: $linked new, $skipped existing, $totalCount total in @autocomplete"
    } else {
        Step-Warn "Skills linked: $linked new, $skipped existing, $failed FAILED"
    }

    return ($failed -eq 0)
}

# ---------------------------------------------------------------------------
# Phase 6: Verification
# ---------------------------------------------------------------------------

function Invoke-Verification {
    Write-Host ""
    Write-Host "  ── Phase 6: Verification ──────────────────────────────────" -ForegroundColor Magenta
    Write-Host ""

    # Check repo
    Write-Step "Verifying skills repo..." "RUN"
    if (Test-Path (Join-Path $script:REPO_DIR ".git")) {
        $skillCount = (Get-ChildItem $script:REPO_DIR -Directory | Where-Object { $_.Name -notlike '.*' }).Count
        Step-Ok "Skills repo OK - $skillCount skill folders"
    } else {
        Step-Fail "Skills repo missing or invalid"
    }

    # Check MCP server script
    Write-Step "Verifying MCP server script..." "RUN"
    if (Test-Path $script:MCP_SERVER_PY) {
        $size = (Get-Item $script:MCP_SERVER_PY).Length
        $sizeKB = [math]::Round($size/1024, 1)
        Step-Ok "MCP server script present - ${sizeKB} KB"
    } else {
        Step-Fail "MCP server script missing at $($script:MCP_SERVER_PY)"
    }

    # Check mcp_config.json
    Write-Step "Verifying mcp_config.json..." "RUN"
    $mcpConfigPath = Join-Path $script:GEMINI_CONFIG "mcp_config.json"
    if (Test-Path $mcpConfigPath) {
        try {
            $mcpConfig = Get-Content $mcpConfigPath -Raw | ConvertFrom-Json
            $serverCount = ($mcpConfig.mcpServers.PSObject.Properties).Count
            $hasSkillsConsolidator = [bool]$mcpConfig.mcpServers.'skills-consolidator'
            if ($hasSkillsConsolidator) {
                Step-Ok "mcp_config.json valid - $serverCount MCP servers, skills-consolidator present"
            } else {
                Step-Fail "mcp_config.json missing skills-consolidator entry"
            }
        } catch {
            Step-Fail "mcp_config.json is invalid JSON: $_"
        }
    } else {
        Step-Fail "mcp_config.json not found"
    }

    # Check symlinked skills
    Write-Step "Verifying local skills..." "RUN"
    if (Test-Path $script:SKILLS_DIR) {
        $localSkills = Get-ChildItem $script:SKILLS_DIR -Directory
        $withSkillMD = $localSkills | Where-Object { Test-Path (Join-Path $_.FullName "SKILL.md") }
        $folderCount = $localSkills.Count
        $mdCount = $withSkillMD.Count
        Step-Ok "Local skills: $folderCount folders, $mdCount with SKILL.md"
    } else {
        Step-Fail "Skills directory does not exist"
    }

    # Test MCP server JSON-RPC
    Write-Step "Testing MCP server JSON-RPC..." "RUN"
    $wslPath = Resolve-WSLPath $script:MCP_SERVER_PY
    try {
        $testPayload = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"bootstrap-test","version":"1.0"}}}'
        $result = echo $testPayload | wsl -d Ubuntu -- python3 "$wslPath" 2>$null | Select-Object -First 1
        if ($result -match '"protocolVersion"') {
            Step-Ok "MCP server responds to JSON-RPC - protocol OK"
        } else {
            $snippet = $result.Substring(0, [Math]::Min(100, $result.Length))
            Step-Warn "MCP server responded but output unexpected: $snippet"
        }
    } catch {
        Step-Warn "MCP server JSON-RPC test failed, non-fatal: $_"
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

function Write-Summary {
    Write-Host ""
    Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""

    if ($script:StepsFailed -eq 0) {
        Write-Host "  🎉 BOOTSTRAP COMPLETE" -ForegroundColor Green
    } else {
        Write-Host "  ⚠️  BOOTSTRAP COMPLETED WITH WARNINGS" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "  Passed:  $($script:StepsPassed)" -ForegroundColor Green
    Write-Host "  Skipped: $($script:StepsSkipped)" -ForegroundColor DarkGray
    $failColor = if ($script:StepsFailed -gt 0) { "Red" } else { "Green" }
    Write-Host "  Failed:  $($script:StepsFailed)" -ForegroundColor $failColor
    Write-Host ""

    if ($script:Warnings.Count -gt 0) {
        Write-Host "  Warnings:" -ForegroundColor Yellow
        foreach ($w in $script:Warnings) {
            Write-Host "    · $w" -ForegroundColor Yellow
        }
        Write-Host ""
    }

    Write-Host "  Next steps:" -ForegroundColor White
    Write-Host "    1. Restart Antigravity IDE" -ForegroundColor DarkGray
    Write-Host "    2. Go to Manage MCPs -> verify skills-consolidator shows 9 tools" -ForegroundColor DarkGray
    Write-Host "    3. Test: ask the agent to search skills for python" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Re-run anytime:  irm https://raw.githubusercontent.com/manoelbenicio/skills/main/.bootstrap/bootstrap.ps1 | iex" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function Main {
    Write-Banner

    # Phase 1: Preflight
    $preflightOk = Invoke-PreflightChecks
    if (-not $preflightOk) {
        Write-Host ""
        Write-Host "  ❌ Preflight checks FAILED. Fix the issues above and re-run." -ForegroundColor Red
        Write-Host ""
        return
    }

    if ($CheckOnly) {
        Write-Host ""
        Write-Host "  ✅ All preflight checks passed. Run without -CheckOnly to proceed." -ForegroundColor Green
        Write-Host ""
        return
    }

    # Phase 2: Clone/Pull
    $repoOk = Invoke-RepoSync
    if (-not $repoOk) {
        Write-Host ""
        Write-Host "  ❌ Repository setup FAILED. Check git access and re-run." -ForegroundColor Red
        Write-Host ""
        return
    }

    # Phase 3: Deploy MCP Server
    Invoke-DeployMCPServer

    # Phase 4: Deploy Configs
    Invoke-DeployConfigs

    # Phase 5: Symlink Skills
    Invoke-SymlinkSkills

    # Phase 6: Verify
    Invoke-Verification

    # Summary
    Write-Summary
}

# Run
Main
