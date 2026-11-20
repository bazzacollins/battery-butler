@echo off
title Battery Health Check
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0BatteryHealthCheck.ps1"
if errorlevel 1 (
  echo.
  pause
) else (
  timeout /t 5 >nul
)
