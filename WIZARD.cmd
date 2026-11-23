@echo off
chcp 65001 >nul
rem pcx 互動精靈：雙擊執行，一步步引導 PC1 設定並連線到 PC2
where pwsh >nul 2>&1
if errorlevel 1 (
  echo 需要 PowerShell 7 ^(pwsh^)。請先安裝: winget install Microsoft.PowerShell
  pause
  exit /b 1
)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0pcx.ps1" wizard
pause
