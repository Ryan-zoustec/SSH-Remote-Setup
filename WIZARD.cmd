@echo off
chcp 65001 >nul
rem pcx 視窗精靈：雙擊執行，用按鈕一步步引導 PC1 設定並連線到 PC2
rem 視窗開不起來時，可改用文字版 WIZARD-TEXT.cmd
where pwsh >nul 2>&1
if errorlevel 1 (
  echo 需要 PowerShell 7 ^(pwsh^)。請先安裝: winget install Microsoft.PowerShell
  pause
  exit /b 1
)
start "pcx" pwsh -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0pcx.ps1" gui
