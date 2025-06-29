@echo off
CHCP 65001 > NUL
REM Ce script lance l'assistant de configuration, puis l'installeur avec élévation de privilèges.

cls
echo #############################################################
echo #    Assistant d'Installation - WindowsAutoConfig         #
echo #############################################################
echo.
echo --- Etape 1 sur 2 : Configuration ---
echo.
echo Lancement de l'assistant graphique. Veuillez renseigner les
echo parametres requis puis cliquez sur "Enregistrer".
echo Si vous souhaitez ignorer cette etape et utiliser le config.ini existant,
echo vous pourrez fermer l'assistant lorsqu'il apparaitra.
echo.
pause

REM Lancement de firstconfig.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0management\firstconfig.ps1"


echo.
echo Configuration terminee via l'assistant (ou ignoree).
echo.
echo --- Etape 2 sur 2 : Installation des taches systeme ---
echo.
echo Lancement de l'installation des taches systeme...
echo.
echo ATTENTION : Une fenetre de securite Windows (UAC) va
echo apparaitre pour demander les droits d'administrateur.
echo Veuillez cliquer sur "Oui" pour continuer.
echo.
pause

REM Lance le script d'installation PowerShell en demandant les droits admin.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& {Start-Process PowerShell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0management\install.ps1\"' -Verb RunAs}"

echo.
echo Le processus d'installation des taches est termine.
echo Verifiez la fenetre du script d'installation PowerShell pour les details et les erreurs eventuelles.
pause
