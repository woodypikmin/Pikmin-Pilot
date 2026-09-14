@echo off
setlocal EnableExtensions
chcp 65001 >nul 2>nul
set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"
cd /d "%~dp0"

echo ============================================================
echo Pikmin Pilot Stage 7.8.5.1 - Windows UTF-8 Signing Fix
echo This is ONE-TIME INSTALL/RESIGN work. It does NOT stay running.
echo ============================================================
echo.

set "PYEXE="
where py >nul 2>nul && set "PYEXE=py -3"
if not defined PYEXE (
  where python >nul 2>nul && set "PYEXE=python"
)
if not defined PYEXE (
  echo ERROR: Python 3 was not found.
  echo Install Python 3 for Windows, then run this BAT again.
  pause
  exit /b 2
)

where ios >nul 2>nul
if errorlevel 1 (
  where npm >nul 2>nul
  if errorlevel 1 (
    echo ERROR: go-ios is not installed and npm was not found.
    echo Install Node.js once, then rerun this BAT. It will install go-ios automatically.
    pause
    exit /b 3
  )
  echo Installing go-ios once via npm...
  call npm install -g go-ios
  if errorlevel 1 (
    echo ERROR: npm could not install go-ios.
    pause
    exit /b 4
  )
)

%PYEXE% -c "import pymobiledevice3" >nul 2>nul
if errorlevel 1 (
  echo Installing pymobiledevice3 once via pip...
  %PYEXE% -m pip install --upgrade pymobiledevice3
  if errorlevel 1 (
    echo ERROR: pip could not install pymobiledevice3.
    pause
    exit /b 5
  )
)

if "%~1"=="" (
  echo.
  echo Drag the GitHub Actions Runner unsigned IPA onto this BAT file.
  echo Example artifact filename:
  echo   PikminPilotRunner-Stage7.8.5-Activate-No-Relaunch-Tap-Proof-unsigned.ipa
  echo.
  pause
  exit /b 6
)

%PYEXE% "%~dp0fix_runner_signing.py" "%~1"
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" (
  echo SUCCESS: Runner was recursively re-signed and installed.
  echo You can close this window. Windows does NOT need to stay running.
) else (
  echo FAILED with code %RC%.
  echo Copy the full text from this window if you need the next fix.
)
pause
exit /b %RC%
