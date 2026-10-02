@echo off
REM SPDX-FileCopyrightText: 2026 GaoZheng
REM SPDX-License-Identifier: MIT
REM Full license: LICENSES/MIT.txt (repository root)

setlocal

set "SCRIPT_DIR=%~dp0"
set "REPO_ROOT=%SCRIPT_DIR%.."
for %%I in ("%REPO_ROOT%") do set "REPO_ROOT=%%~fI"
set "OUT_DIR=%REPO_ROOT%\out"
set "SOURCE_SCRIPT=%SCRIPT_DIR%staged_pull.ps1"
set "OUT_SCRIPT=%OUT_DIR%\staged_pull.ps1"

if not exist "%SOURCE_SCRIPT%" (
  echo staged_pull.ps1 not found: %SOURCE_SCRIPT%
  exit /b 1
)

if not exist "%OUT_DIR%" (
  mkdir "%OUT_DIR%"
  if errorlevel 1 exit /b 1
)

copy /Y "%SOURCE_SCRIPT%" "%OUT_SCRIPT%" >nul
if errorlevel 1 (
  echo failed to copy staged_pull.ps1 to out.
  exit /b 1
)

where pwsh >nul 2>nul
if errorlevel 1 (
  set "POWERSHELL_EXE=powershell"
) else (
  set "POWERSHELL_EXE=pwsh"
)

pushd "%REPO_ROOT%" >nul
"%POWERSHELL_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%OUT_SCRIPT%" %*
set "EXIT_CODE=%ERRORLEVEL%"
popd >nul

exit /b %EXIT_CODE%
