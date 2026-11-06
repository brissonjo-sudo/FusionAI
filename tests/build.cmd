@echo off
setlocal
cd /d "%~dp0"
where dcc32 >nul 2>&1
if errorlevel 1 (
  echo Run from the RAD Studio 10.2 command prompt, or call its rsvars.bat first.
  exit /b 1
)
if not exist bin mkdir bin
dcc32 -B -Q -Ebin -N0bin TokyoRegression.dpr
if errorlevel 1 exit /b 1
bin\TokyoRegression.exe
exit /b %errorlevel%
