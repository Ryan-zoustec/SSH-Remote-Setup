@echo off
chcp 65001 >nul
rem pcx 文字互動精靈 (備援)：雙擊執行，在命令列視窗一步步問答。視窗版請用 WIZARD.cmd
where pwsh >nul 2>&1
if errorlevel 1 (
  echo 需要 PowerShell 7 ^(pwsh^)。請先安裝: winget install Microsoft.PowerShell
  pause
  exit /b 1
)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0pcx.ps1" wizard
pause
