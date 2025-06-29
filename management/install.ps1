<#
.SYNOPSIS
    Installe et configure les tâches planifiées pour les scripts de configuration système et utilisateur.
.DESCRIPTION
    Ce script s'assure d'être exécuté en tant qu'administrateur (demande si besoin).
    Il crée deux tâches planifiées :
    1. "AllSysConfig-SystemStartup" qui exécute config_systeme.ps1 au démarrage.
    2. "AllSysConfig-UserLogon" qui exécute config_utilisateur.ps1 à l'ouverture de session.
    À la fin de l'installation, il tente de lancer une première fois les scripts config_systeme.ps1 et config_utilisateur.ps1.
.NOTES
    Auteur: Ronan Davalan & Gemini 2.5-pro
    Version: Voir la configuration globale du projet (config.ini ou documentation)
#>

# --- Bloc d'auto-élévation des privilèges ---
$currentUserPrincipal = New-Object Security.Principal.WindowsPrincipal $([Security.Principal.WindowsIdentity]::GetCurrent())
if (-Not $currentUserPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $scriptPath = $MyInvocation.MyCommand.Path
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments -ErrorAction Stop
    } catch {
        Write-Warning "Échec de l'élévation des privilèges. Veuillez exécuter ce script en tant qu'administrateur."
        Read-Host "Appuyez sur Entrée pour quitter."
    }
    exit
}

# --- Configuration et Vérifications Préliminaires ---
function Write-StyledHost {
    param([string]$Message, [string]$Type = "INFO")
    $color = switch ($Type.ToUpper()) {
        "INFO"{"Cyan"}; "SUCCESS"{"Green"}; "WARNING"{"Yellow"}; "ERROR"{"Red"}; default{"White"}
    }
    Write-Host "[$Type] " -ForegroundColor $color -NoNewline; Write-Host $Message
}

$OriginalErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Stop"
$errorOccurredInScript = $false

try {
    # Détermine le répertoire du script actuel (.../management) et remonte au répertoire racine du projet
    $InstallerScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
    $ProjectRootDir = Split-Path -Parent $InstallerScriptDir

    # Valider que $ProjectRootDir est plausible (contient par exemple config.ini)
    if (-not (Test-Path (Join-Path $ProjectRootDir "config.ini"))) {
        Write-StyledHost "config.ini non trouvé dans le répertoire parent présumé ($ProjectRootDir)." "WARNING"
        $ProjectRootDirFromUser = Read-Host "Veuillez entrer le chemin complet du répertoire racine des scripts AllSysConfig (ex: C:\AllSysConfig)"
        if ([string]::IsNullOrWhiteSpace($ProjectRootDirFromUser) -or -not (Test-Path $ProjectRootDirFromUser -PathType Container) -or -not (Test-Path (Join-Path $ProjectRootDirFromUser "config.ini"))) {
            throw "Répertoire racine du projet invalide ou config.ini introuvable : '$ProjectRootDirFromUser'"
        }
        $ProjectRootDir = $ProjectRootDirFromUser.TrimEnd('\')
    }
    # S'assurer qu'il n'y a pas de slash final pour la cohérence
    $ProjectRootDir = $ProjectRootDir.TrimEnd('\')

    $SystemScriptPath = Join-Path $ProjectRootDir "config_systeme.ps1"
    $UserScriptPath   = Join-Path $ProjectRootDir "config_utilisateur.ps1"
    # Déjà vérifié implicitement ci-dessus
    $ConfigIniPath    = Join-Path $ProjectRootDir "config.ini"

    # Noms de tâches FIXES
    $TaskNameSystem = "AllSysConfig-SystemStartup"
    $TaskNameUser   = "AllSysConfig-UserLogon"

    Write-StyledHost "Répertoire racine du projet utilisé : $ProjectRootDir" "INFO"
}
catch {
    Write-StyledHost "Erreur lors de la détermination des chemins initiaux : $($_.Exception.Message)" "ERROR"
    # $ErrorActionPreference est "Stop", donc le script s'arrête ici.
    # On remet la préférence d'erreur pour Read-Host si on arrive au finally.
    $ErrorActionPreference = "Continue"
    Read-Host "Appuyez sur Entrée pour quitter."
    exit 1
}

$filesMissing = $false
if (-not (Test-Path $SystemScriptPath)) { Write-StyledHost "Fichier système requis manquant : $SystemScriptPath" "ERROR"; $filesMissing = $true }
if (-not (Test-Path $UserScriptPath))   { Write-StyledHost "Fichier utilisateur requis manquant : $UserScriptPath" "ERROR"; $filesMissing = $true }
# config.ini a déjà été vérifié

if ($filesMissing) {
    Read-Host "Des fichiers de script principaux sont manquants dans '$ProjectRootDir'. Installation annulée. Appuyez sur Entrée pour quitter."
    exit 1
}

# Utilisateur cible pour la tâche utilisateur (l'utilisateur qui exécute ce script d'installation)
# et qui a fourni les droits admin.
$TargetUserForUserTask = "$($env:USERDOMAIN)\$($env:USERNAME)"
Write-StyledHost "La tâche utilisateur sera installée pour : $TargetUserForUserTask" "INFO"

# --- Début de l'Installation ---
Write-StyledHost "Début de la configuration des tâches planifiées..." "INFO"
try {
    # Tâche 1: Script Système
    Write-StyledHost "Création/Mise à jour de la tâche système '$TaskNameSystem'..." "INFO"
    $ActionSystem = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$SystemScriptPath`"" -WorkingDirectory $ProjectRootDir
    $TriggerSystem = New-ScheduledTaskTrigger -AtStartup
    $PrincipalSystem = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -RunLevel Highest
    $SettingsSystem = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    Register-ScheduledTask -TaskName $TaskNameSystem -Action $ActionSystem -Trigger $TriggerSystem -Principal $PrincipalSystem -Settings $SettingsSystem -Description "AllSysConfig: Exécute le script de configuration système au démarrage." -Force
    Write-StyledHost "Tâche '$TaskNameSystem' configurée avec succès." "SUCCESS"

    # Tâche 2: Script Utilisateur
    Write-StyledHost "Création/Mise à jour de la tâche utilisateur '$TaskNameUser' pour '$TargetUserForUserTask'..." "INFO"
    $ActionUser = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$UserScriptPath`"" -WorkingDirectory $ProjectRootDir
    $TriggerUser = New-ScheduledTaskTrigger -AtLogOn -User $TargetUserForUserTask
    $PrincipalUser = New-ScheduledTaskPrincipal -UserId $TargetUserForUserTask -LogonType Interactive
    $SettingsUser = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    Register-ScheduledTask -TaskName $TaskNameUser -Action $ActionUser -Trigger $TriggerUser -Principal $PrincipalUser -Settings $SettingsUser -Description "AllSysConfig: Exécute le script de configuration utilisateur à l'ouverture de session." -Force
    Write-StyledHost "Tâche '$TaskNameUser' configurée avec succès." "SUCCESS"

    Write-Host "`n"
    Write-StyledHost "Tâches planifiées principales configurées." "INFO"
    Write-StyledHost "Les tâches pour le redémarrage quotidien ('AllSys_SystemScheduledReboot') et l'action pré-redémarrage ('AllSys_SystemPreRebootAction') seront créées/gérées par '$SystemScriptPath' lors de son exécution." "INFO"

    # --- Lancement initial des scripts de configuration ---
    Write-Host "`n"
    Write-StyledHost "Tentative de lancement initial des scripts de configuration..." "INFO"

    # Lancer config_systeme.ps1
    try {
        Write-StyledHost "Exécution de config_systeme.ps1 pour appliquer les configurations système initiales..." "INFO"
        $processSystem = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$SystemScriptPath`"" -WorkingDirectory $ProjectRootDir -Wait -PassThru -ErrorAction Stop
        if ($processSystem.ExitCode -eq 0) {
            Write-StyledHost "config_systeme.ps1 exécuté avec succès (code de sortie 0)." "SUCCESS"
        } else {
            Write-StyledHost "config_systeme.ps1 s'est terminé avec un code de sortie : $($processSystem.ExitCode). Vérifiez les logs dans '$ProjectRootDir\Logs'." "WARNING"
        }
    } catch {
        Write-StyledHost "Erreur lors de l'exécution initiale de config_systeme.ps1 : $($_.Exception.Message)" "ERROR"
        Write-StyledHost "Trace : $($_.ScriptStackTrace)" "ERROR"
        $errorOccurredInScript = $true
    }

    # Lancer config_utilisateur.ps1
    # S'exécute dans le contexte de l'utilisateur qui a lancé install.ps1 (et qui a élevé les droits)
    # Cet utilisateur est $TargetUserForUserTask
    # Ne pas tenter si une erreur s'est déjà produite
    if (-not $errorOccurredInScript) {
        try {
            Write-StyledHost "Exécution de config_utilisateur.ps1 pour '$TargetUserForUserTask' pour appliquer les configurations utilisateur initiales..." "INFO"
            $processUser = Start-Process powershell.exe -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$UserScriptPath`"" -WorkingDirectory $ProjectRootDir -Wait -PassThru -ErrorAction Stop
            if ($processUser.ExitCode -eq 0) {
                Write-StyledHost "config_utilisateur.ps1 exécuté avec succès pour '$TargetUserForUserTask' (code de sortie 0)." "SUCCESS"
            } else {
                Write-StyledHost "config_utilisateur.ps1 pour '$TargetUserForUserTask' s'est terminé avec un code de sortie : $($processUser.ExitCode). Vérifiez les logs dans '$ProjectRootDir\Logs'." "WARNING"
            }
        } catch {
            Write-StyledHost "Erreur lors de l'exécution initiale de config_utilisateur.ps1 pour '$TargetUserForUserTask': $($_.Exception.Message)" "ERROR"
            Write-StyledHost "Trace : $($_.ScriptStackTrace)" "ERROR"
            $errorOccurredInScript = $true
        }
    }

    Write-Host "`n"
    if (-not $errorOccurredInScript) {
        Write-StyledHost "Installation et lancement initial terminés !" "SUCCESS"
    } else {
        Write-StyledHost "Installation terminée avec des erreurs lors du lancement initial des scripts. Vérifiez les messages ci-dessus." "WARNING"
    }

}
catch {
    Write-StyledHost "Une erreur critique est survenue durant l'installation : $($_.Exception.Message)" "ERROR"
    Write-StyledHost "Trace : $($_.ScriptStackTrace)" "ERROR"
}
finally {
    $ErrorActionPreference = $OriginalErrorActionPreference
    Write-Host "`n"; Read-Host "Appuyez sur Entrée pour fermer cette fenêtre."
}
