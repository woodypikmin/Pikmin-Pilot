@echo off
setlocal
cd /d "%~dp0"

echo Pikmin Pilot OTA Packager
set /p IPA=Signed IPA full path: 
set /p BASE=Public HTTPS base URL (example https://example.com/pikminpilot/): 

py -3 make_ota_package.py --ipa "%IPA%" --base-url "%BASE%" --output ota-site
if errorlevel 1 (
  echo.
  echo FAILED.
  pause
  exit /b 1
)

echo.
echo DONE. Upload the entire OTA\ota-site folder to the exact HTTPS base URL above.
pause
