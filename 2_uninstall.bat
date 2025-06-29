@echo off
CHCP 65001 > NUL
REM Ce script lance le script de desinstallation PowerShell en demandant les droits d'administrateur.
echo Lancement de la desinstallation de AllSysConfig...
echo Une demande d'elevation de privileges (UAC) va apparaitre. Veuillez l'accepter.

REM Commande pour re-lancer le script PowerShell avec les droits admin
powershell -NoProfile -ExecutionPolicy Bypass -Command "& {Start-Process PowerShell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \""%~dp0management\uninstall.ps1\""' -Verb RunAs}"

echo.
echo Le script de desinstallation est termine.
pause
