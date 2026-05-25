@echo off
REM ============================================================
REM  Skills MCP Server - One-Click Installer for Windows/WSL
REM  Run this on any new machine to get the full skills setup
REM ============================================================

echo ============================================================
echo  Skills MCP Server Installer v1.0
echo  Repository: github.com/manoelbenicio/skills.git
echo ============================================================
echo.

REM --- Configuration ---
set SKILLS_DIR=%USERPROFILE%\.gemini\config\consolidated-skills
set MCP_DIR=%USERPROFILE%\.gemini\antigravity-ide\scratch
set MCP_SERVER=%MCP_DIR%\skills_mcp_server.py
set SKILLS_TXT=%USERPROFILE%\.gemini\antigravity\skills.txt
set REPO_URL=https://github.com/manoelbenicio/skills.git

REM --- Step 1: Check Python ---
echo [1/6] Checking Python...
python --version >nul 2>&1
if %errorlevel% neq 0 (
    echo ERROR: Python not found. Install Python 3.10+ from https://www.python.org/downloads/
    pause
    exit /b 1
)
for /f "tokens=*" %%v in ('python --version') do echo   %%v
echo.

REM --- Step 2: Check Git ---
echo [2/6] Checking Git...
git --version >nul 2>&1
if %errorlevel% neq 0 (
    echo ERROR: Git not found. Install Git from https://git-scm.com/downloads
    pause
    exit /b 1
)
for /f "tokens=*" %%v in ('git --version') do echo   %%v
echo.

REM --- Step 3: Clone or update skills repo ---
echo [3/6] Setting up skills repository...
if exist "%SKILLS_DIR%\.git" (
    echo   Repository exists. Pulling latest...
    git -C "%SKILLS_DIR%" pull --ff-only
) else (
    echo   Cloning repository (this may take a few minutes)...
    git clone "%REPO_URL%" "%SKILLS_DIR%"
)
echo   Done.
echo.

REM --- Step 4: Install MCP server ---
echo [4/6] Installing MCP server...
if not exist "%MCP_DIR%" mkdir "%MCP_DIR%"
copy /Y "%~dp0skills_mcp_server.py" "%MCP_SERVER%" >nul
echo   Installed at: %MCP_SERVER%
echo.

REM --- Step 5: Create skills.txt ---
echo [5/6] Creating skills.txt...
if not exist "%USERPROFILE%\.gemini\antigravity" mkdir "%USERPROFILE%\.gemini\antigravity"
echo %SKILLS_DIR%\> "%SKILLS_TXT%"
echo   Created at: %SKILLS_TXT%
echo.

REM --- Step 6: Update MCP config ---
echo [6/6] MCP config info...
echo.
echo   Add the following to your mcp_config.json:
echo.
echo     "skills-consolidator": {
echo       "command": "python",
echo       "args": ["%MCP_SERVER:\=\\%"]
echo     }
echo.

REM --- Test ---
echo ============================================================
echo  Running verification test...
echo ============================================================
echo.
echo {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","clientInfo":{"name":"test","version":"1.0"},"capabilities":{}}}| python "%MCP_SERVER%" 2>nul
echo.
echo.
echo ============================================================
echo  INSTALLATION COMPLETE
echo ============================================================
echo.
echo  Skills:     %SKILLS_DIR% (git-synced)
echo  MCP Server: %MCP_SERVER%
echo  Config:     %SKILLS_TXT%
echo.
echo  Next steps:
echo    1. Add the skills-consolidator entry to your mcp_config.json
echo    2. Restart your IDE to pick up the new MCP server
echo    3. Use "search_skills" or "list_skills" to verify
echo.
pause
