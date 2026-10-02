@echo off

REM SPDX-FileCopyrightText: 2025 GaoZheng
REM SPDX-License-Identifier: MIT
REM Full license: LICENSES/MIT.txt (repository root)
@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem Ensure working directory is the repo root (parent of this script)
set "REPO_ROOT=%~dp0.."
cd /d "%REPO_ROOT%"

rem -------------------------------------------------
rem Minimal and clean Python venv setup (no hooks, no extras)
rem Flags:
rem   --envdir <dir>           Target virtualenv directory (default .venv)
rem   --requirements <path>    Install from requirements.txt (optional)
rem   --trace                  Print commands before running
rem -------------------------------------------------

set "ENVDIR=.venv"
set "REQUIREMENTS="
set "TRACE=0"

set "PIP_DISABLE_PIP_VERSION_CHECK=1"

:parse_args
if "%~1"=="" goto args_done
if /I "%~1"=="--envdir" (
  set "ENVDIR=%~2"
  shift & shift & goto parse_args
)
if /I "%~1"=="--requirements" (
  set "REQUIREMENTS=%~2"
  shift & shift & goto parse_args
)
if /I "%~1"=="--trace" (
  set "TRACE=1"
  shift & goto parse_args
)
echo Unknown argument: %~1
exit /b 1

:args_done

if "%TRACE%"=="1" echo [debug] trace enabled

rem Resolve Python (prefer py -3, then python)
set "PY_CMD="
py -3 -c "import sys" >NUL 2>&1 && set "PY_CMD=py -3"
if not defined PY_CMD python -c "import sys" >NUL 2>&1 && set "PY_CMD=python"
if not defined PY_CMD (
  echo [error] Python 3.8+ not found. Please install Python or the Windows Python Launcher.
  exit /b 1
)

if "%TRACE%"=="1" echo [exec] %PY_CMD% -m venv "%ENVDIR%"
%PY_CMD% -m venv "%ENVDIR%"
if errorlevel 1 goto error

set "VENVPY=%ENVDIR%\Scripts\python.exe"
if not exist "%VENVPY%" (
  echo [error] virtualenv python not found: "%VENVPY%"
  goto error
)

call :run "%VENVPY%" -m pip install --no-cache-dir --upgrade pip setuptools wheel || goto error

if defined REQUIREMENTS (
  if "%TRACE%"=="1" echo [info] installing from requirements: "%REQUIREMENTS%"
  call :run "%VENVPY%" -m pip install --no-cache-dir -r "%REQUIREMENTS%" || goto error
)

set "PWSH_CMD=pwsh"
where pwsh >NUL 2>&1
if errorlevel 1 set "PWSH_CMD=powershell"
set "PYCACHE_INSTALLER=%REPO_ROOT%\scripts\pycache_customize\install_venv_pycache_hook.ps1"
if not exist "%PYCACHE_INSTALLER%" (
  echo [error] pycache governance installer not found: "%PYCACHE_INSTALLER%"
  goto error
)
call :run %PWSH_CMD% -NoProfile -ExecutionPolicy Bypass -File "%PYCACHE_INSTALLER%" -PythonExecutable "%VENVPY%" || goto error

echo [ok] Python environment ready.
call :run "%VENVPY%" -c "import sys; print('Python:', sys.version)" || goto error

echo.
echo [done] Activate your environment:
echo    .\activate_venv.ps1
echo.
exit /b 0

:run
if "%TRACE%"=="1" echo [exec] %*
%*
exit /b %ERRORLEVEL%

:error
echo [fail] setup failed (errorlevel=%ERRORLEVEL%)
exit /b 1
