@echo off
setlocal
set "SCRIPT=%~dp0C_Disk_Slim_Helper_v1.2.ps1"
if not exist "%SCRIPT%" (
  echo Missing helper script: %SCRIPT%
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
if errorlevel 1 pause
endlocal
