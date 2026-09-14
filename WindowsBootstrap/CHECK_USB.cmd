@echo off
setlocal
cd /d "%~dp0"
echo Pikmin Pilot USB diagnostics
echo ============================
echo.
echo [1] Bundled idevice_id -l (it should return quickly)
start "" /b cmd /c "tools\\idevice_id.exe -l > usb-idevice-id.txt 2>&1"
timeout /t 10 /nobreak >nul
taskkill /im idevice_id.exe /f >nul 2>&1
type usb-idevice-id.txt 2>nul
echo.
echo [2] Optional pymobiledevice3 fallback
python -m pymobiledevice3 usbmux list 2> usb-pymobiledevice3-error.txt
if errorlevel 1 (
  py -3 -m pymobiledevice3 usbmux list 2>> usb-pymobiledevice3-error.txt
)
echo.
echo Errors, if any:
type usb-pymobiledevice3-error.txt 2>nul
echo.
pause
