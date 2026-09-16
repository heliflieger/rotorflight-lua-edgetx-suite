@echo off
setlocal
cd /d %~dp0

if "%~1"=="-h" goto :usage
if "%~1"=="--help" goto :usage
if "%~1"=="/?" goto :usage

set LANG_ARG=%~1
if "%LANG_ARG%"=="" set LANG_ARG=en

set VER_ARG=%~2
if "%VER_ARG%"=="" set VER_ARG=local-test

shift
shift

set PYTHONUTF8=1
set PYTHONIOENCODING=utf-8

where py >nul 2>&1
if %errorlevel%==0 (
    set PYEXE=py -3
) else (
    set PYEXE=python
)

%PYEXE% build_package.py --lang %LANG_ARG% --artifact-version %VER_ARG% --output-dir "%cd%" %1 %2 %3 %4 %5 %6 %7 %8 %9
goto :eof

:usage
echo Usage: package.cmd [lang] [artifact-version] [extra build_package.py args...]
echo   lang              defaults to "en"
echo   artifact-version  defaults to "local-test"
echo Example: package.cmd de 0.1.0-20260816
goto :eof
