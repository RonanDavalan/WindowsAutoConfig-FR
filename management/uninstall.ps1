<#
.SYNOPSIS
    Désinstalle les tâches planifiées pour les scripts de configuration système et utilisateur.
.DESCRIPTION
    Ce script s'assure d'être exécuté en tant qu'administrateur (demande si besoin).
    Il supprime les tâches planifiées :
    - "AllSysConfig-SystemStartup" (créée par install.ps1)
    - "AllSysConfig-UserLogon" (créée par install.ps1)
    - "AllSys_SystemScheduledReboot" (créée par config_systeme.ps1)
    - "AllSys_SystemPreRebootAction" (créée par config_systeme.ps1)
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

# --- Configuration ---
function Write-StyledHost {
    param([string]$Message, [string]$Type = "INFO")
    $color = switch ($Type.ToUpper()) {
        "INFO"{"Cyan"}; "SUCCESS"{"Green"}; "WARNING"{"Yellow"}; "ERROR"{"Red"}; default{"White"}
    }
    Write-Host "[$Type] " -ForegroundColor $color -NoNewline; Write-Host $Message
}

$OriginalErrorActionPreference = $ErrorActionPreference
# Mettre SilentlyContinue pour Get-ScheduledTask pour ne pas échouer si une tâche n'existe pas.
# Pour Unregister-ScheduledTask, on utilisera -ErrorAction Stop dans un try/catch.
$ErrorActionPreference = "SilentlyContinue"

# Noms de tâches à supprimer
# Ceux créés par install.ps1
$TaskNameSystemFromInstaller = "AllSysConfig-SystemStartup"
$TaskNameUserFromInstaller   = "AllSysConfig-UserLogon"
# Ceux créés par config_systeme.ps1
$TaskNameSystemReboot = "AllSys_SystemScheduledReboot"
$TaskNameSystemPreReboot = "AllSys_SystemPreRebootAction"

$TasksToRemove = @(
    $TaskNameSystemFromInstaller,
    $TaskNameUserFromInstaller,
    $TaskNameSystemReboot,
    $TaskNameSystemPreReboot
)

Write-StyledHost "Début de la suppression des tâches planifiées AllSysConfig..." "INFO"
$anyTaskActionAttempted = $false
$tasksSuccessfullyRemoved = [System.Collections.Generic.List[string]]::new()
$tasksFoundButNotRemoved = [System.Collections.Generic.List[string]]::new()

foreach ($taskName in $TasksToRemove) {
    Write-StyledHost "Traitement de la tâche '$taskName'..." -NoNewline
    $task = Get-ScheduledTask -TaskName $taskName # ErrorAction est SilentlyContinue globalement

    if ($task) {
        $anyTaskActionAttempted = $true
        Write-Host " Trouvée. Tentative de suppression..." -ForegroundColor Cyan -NoNewline
        try {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
            # Re-vérifier si elle a bien été supprimée
            if (-not (Get-ScheduledTask -TaskName $taskName)) { # ErrorAction est SilentlyContinue globalement
                Write-Host " Supprimée avec succès." -ForegroundColor Green
                $tasksSuccessfullyRemoved.Add($taskName)
            } else {
                Write-Host " ÉCHEC de la suppression (la tâche '$taskName' existe toujours après tentative)." -ForegroundColor Red
                $tasksFoundButNotRemoved.Add($taskName)
            }
        } catch {
            Write-Host " ERREUR lors de la tentative de suppression de '$taskName'." -ForegroundColor Red
            Write-StyledHost "   Détail de l'erreur: $($_.Exception.Message)" "ERROR"
            $tasksFoundButNotRemoved.Add($taskName)
        }
    } else {
        Write-Host " Non trouvée." -ForegroundColor Yellow
    }
}

Write-Host "`n"
if ($tasksSuccessfullyRemoved.Count -gt 0) {
    Write-StyledHost "Désinstallation terminée. Tâches supprimées avec succès : $($tasksSuccessfullyRemoved -join ', ')" "SUCCESS"
}

if ($tasksFoundButNotRemoved.Count -gt 0) {
    Write-StyledHost "Certaines tâches ont été trouvées mais n'ont PAS pu être supprimées : $($tasksFoundButNotRemoved -join ', ')." "ERROR"
    Write-StyledHost "Veuillez vérifier le Planificateur de Tâches et les messages d'erreur ci-dessus." "ERROR"
}

if (-not $anyTaskActionAttempted -and $tasksSuccessfullyRemoved.Count -eq 0) { # Si aucune tâche n'a été trouvée à traiter
    Write-StyledHost "Aucune des tâches AllSysConfig spécifiées n'a été trouvée." "INFO"
}

Write-StyledHost "Note : Les scripts et fichiers de configuration ne sont pas supprimés par ce script." "INFO"

$ErrorActionPreference = $OriginalErrorActionPreference
Write-Host "`n"; Read-Host "Appuyez sur Entrée pour fermer cette fenêtre."
