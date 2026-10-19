@echo off
rem Monitor de Hardware - remocao (pede administrador uma vez)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0instalar.ps1" -Remover
