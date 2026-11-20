@echo off
title Battery Butler
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0BatteryButler.ps1"
if errorlevel 1 (
  echo.
  pause
) else (
  timeout /t 5 >nul
)
