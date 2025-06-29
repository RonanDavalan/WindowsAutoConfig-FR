#Requires -Version 5.1
# Pas besoin de -RunAsAdministrator ici, s'execute dans le contexte de l'utilisateur logue.

<#
.SYNOPSIS
    Script de configuration UTILISATEUR automatisee.
.DESCRIPTION
    Lit les parametres depuis config.ini, applique les configurations spécifiques à l'utilisateur
    (principalement la gestion d'un processus applicatif défini), et envoie une notification Gotify.
    La rotation de ses logs est gérée par le script config_systeme.ps1.
.NOTES
    Auteur: Ronan Davalan & Gemini 2.5-pro
    Version: Voir la configuration globale du projet (config.ini ou documentation)
#>

# --- PAS DE FONCTION Rotate-LogFile ICI (gérée par config_systeme.ps1) ---

# --- Configuration Globale ---
$ScriptIdentifierUser = "AllSysConfig-Utilisateur"
$ScriptInternalBuildUser = "Build-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
if ($MyInvocation.MyCommand.CommandType -eq 'ExternalScript') {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
} else {
    try { $ScriptDir = Split-Path -Parent $script:MyInvocation.MyCommand.Path -ErrorAction Stop }
    catch { $ScriptDir = Get-Location }
}

$TargetLogDirUser = Join-Path -Path $ScriptDir -ChildPath "Logs"
$LogDirToUseUser = $ScriptDir # Fallback

if (Test-Path $TargetLogDirUser -PathType Container) {
    $LogDirToUseUser = $TargetLogDirUser
} else {
    try { New-Item -Path $TargetLogDirUser -ItemType Directory -Force -ErrorAction Stop | Out-Null; $LogDirToUseUser = $TargetLogDirUser } catch {}
}

$LogFileUserBaseName = "config_utilisateur_log"
$LogFileUser = Join-Path -Path $LogDirToUseUser -ChildPath "$($LogFileUserBaseName).txt"

$ConfigFile = Join-Path -Path $ScriptDir -ChildPath "config.ini"

$Global:UserActionsEffectuees = [System.Collections.Generic.List[string]]::new()
$Global:UserErreursRencontrees = [System.Collections.Generic.List[string]]::new()
# Sera peuplé par Get-IniContent
$Global:Config = $null

# --- Fonctions Utilitaires ---
# Get-IniContent doit être définie tôt
function Get-IniContent {
    [CmdletBinding()] param ([Parameter(Mandatory=$true)][string]$FilePath)
    $ini = @{}; $currentSection = ""
    if (-not (Test-Path -Path $FilePath -PathType Leaf)) { return $null }
    try {
        Get-Content $FilePath -ErrorAction Stop | ForEach-Object {
            $line = $_.Trim()
            if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#") -or $line.StartsWith(";")) { return }
            if ($line -match "^\[(.+)\]$") { $currentSection = $matches[1].Trim(); $ini[$currentSection] = @{} }
            elseif ($line -match "^([^=]+)=(.*)") {
                if ($currentSection) {
                    $key = $matches[1].Trim(); $value = $matches[2].Trim() # Pas de gestion de commentaire en ligne ici
                    $ini[$currentSection][$key] = $value
                }
            }
        }
    } catch { return $null }
    return $ini
}

function Write-UserLog {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG")]
        [string]$Level = "INFO",
        [switch]$NoConsole
    )
    process {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logEntry = "$timestamp [$Level] [UserScript:$($env:USERNAME)] - $Message"

        $LogParentDirUser = Split-Path $LogFileUser -Parent
        if (-not (Test-Path -Path $LogParentDirUser -PathType Container)) {
            try { New-Item -Path $LogParentDirUser -ItemType Directory -Force -ErrorAction Stop | Out-Null } catch {}
        }

        try { Add-Content -Path $LogFileUser -Value $logEntry -ErrorAction Stop }
        catch {
            $fallbackLogDir = "C:\ProgramData\StartupScriptLogs"
            if (-not (Test-Path -Path $fallbackLogDir -PathType Container)) {
                try { New-Item -Path $fallbackLogDir -ItemType Directory -Force -ErrorAction Stop | Out-Null } catch {}
            }
            $fallbackLogFile = Join-Path -Path $fallbackLogDir -ChildPath "config_utilisateur_FATAL_LOG_ERROR.txt"
            $fallbackMessage = "$timestamp [FATAL_USER_LOG_ERROR] - Impossible d'ecrire dans '$LogFileUser': $($_.Exception.Message). Message original: $logEntry"
            Write-Host $fallbackMessage -ForegroundColor Red
            try { Add-Content -Path $fallbackLogFile -Value $fallbackMessage -ErrorAction Stop } catch {}
        }
        if (-not $NoConsole -and ($Host.Name -eq "ConsoleHost" -or $PSEdition -eq "Core")) {
            Write-Host $logEntry
        }
    }
}

function Add-UserAction {
    param([string]$ActionMessage)
    $Global:UserActionsEffectuees.Add($ActionMessage)
    Write-UserLog -Message "ACTION: $ActionMessage" -Level "INFO" -NoConsole
}

function Add-UserError {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true, Position=0)]
        [string]$Message
    )
    $detailedErrorMessage = $Message
    if ([string]::IsNullOrWhiteSpace($detailedErrorMessage)) {
        if ($global:Error.Count -gt 0) {
            $lastError = $global:Error[0]
            $detailedErrorMessage = "Erreur utilisateur non specifiee. PowerShell: $($lastError.Exception.Message) - StackTrace: $($lastError.ScriptStackTrace) - InvocationInfo: $($lastError.InvocationInfo.Line)"
        } else {
            $detailedErrorMessage = "Erreur utilisateur non specifiee, et aucune information d'erreur PowerShell supplementaire disponible."
        }
    }
    $Global:UserErreursRencontrees.Add($detailedErrorMessage)
    Write-UserLog -Message "ERREUR CAPTUREE: $detailedErrorMessage" -Level "ERROR"
}

function Get-ConfigValue {
    param(
        [string]$Section,
        [string]$Key,
        [object]$DefaultValue = $null,
        [System.Type]$Type = ([string]),
        [bool]$KeyMustExist = $false
    )
    $value = $null; $keyExists = $false
    if ($null -ne $Global:Config) {
         $keyExists = $Global:Config.ContainsKey($Section) -and $Global:Config[$Section].ContainsKey($Key)
         if ($keyExists) { $value = $Global:Config[$Section][$Key] }
    }
    if ($KeyMustExist -and (-not $keyExists)) { return [pscustomobject]@{ Undefined = $true } }
    if (-not $keyExists) {
        if ($null -ne $DefaultValue) { return $DefaultValue }
        if ($Type -eq ([bool])) { return $false }; if ($Type -eq ([int])) { return 0 }; return $null
    }
    if ([string]::IsNullOrWhiteSpace($value) -and $Type -eq ([bool])) {
        if ($null -ne $DefaultValue) { return $DefaultValue }; return $false
    }
    try { return [System.Convert]::ChangeType($value, $Type) }
    catch {
        Add-UserError "Valeur config invalide pour [$($Section)]$($Key): '$value'. Type attendu '$($Type.Name)'. Defaut/vide utilise."
        if ($null -ne $DefaultValue) { return $DefaultValue }
        if ($Type -eq ([bool])) { return $false }; if ($Type -eq ([int])) { return 0 }; return $null
    }
}
# --- FIN Fonctions Utilitaires ---

# --- Début du Script Utilisateur ---
try {
    $Global:Config = Get-IniContent -FilePath $ConfigFile
    if (-not $Global:Config) {
         Write-UserLog -Message "Impossible de lire ou parser '$ConfigFile'. Arret des configurations utilisateur." -Level ERROR
         throw "Echec critique: Impossible de charger config.ini pour le script utilisateur."
    }

    Write-UserLog -Message "Demarrage de $ScriptIdentifierUser ($ScriptInternalBuildUser) pour '$($env:USERNAME)'..."
    Write-UserLog -Message "Execution des actions utilisateur '$($env:USERNAME)' configurees..."

    # --- Gérer le processus spécifié ---
    $processNameToManageRaw = Get-ConfigValue -Section "Process" -Key "ProcessName"
    $processNameToManageExpanded = ""
    if (-not [string]::IsNullOrWhiteSpace($processNameToManageRaw)) {
        try {
            $processNameToManageExpanded = [System.Environment]::ExpandEnvironmentVariables($processNameToManageRaw.Trim('"'))
        } catch {
            Add-UserError "Erreur expansion variables pour ProcessName '$processNameToManageRaw': $($_.Exception.Message)"
            $processNameToManageExpanded = $processNameToManageRaw.Trim('"')
        }
    }
    $processArgumentsToPass = Get-ConfigValue -Section "Process" -Key "ProcessArguments"
    $launchMethod = (Get-ConfigValue -Section "Process" -Key "LaunchMethod" -DefaultValue "direct").ToLower()

    if (-not [string]::IsNullOrWhiteSpace($processNameToManageExpanded)) {
        Write-UserLog -Message "Gestion processus utilisateur (brut:'$processNameToManageRaw', resolu:'$processNameToManageExpanded'). Methode: $launchMethod"
        if (-not [string]::IsNullOrWhiteSpace($processArgumentsToPass)) { Write-UserLog -Message "Avec arguments : '$processArgumentsToPass'" -Level DEBUG }

        $processNameIsFilePath = Test-Path -LiteralPath $processNameToManageExpanded -PathType Leaf -ErrorAction SilentlyContinue

        if (($launchMethod -eq "direct" -and $processNameIsFilePath) -or ($launchMethod -ne "direct")) {
            $exeForStartProcess = ""
            $argsForStartProcess = ""
            $processBaseNameToMonitor = ""

            if ($launchMethod -eq "direct") {
                $exeForStartProcess = $processNameToManageExpanded
                $argsForStartProcess = $processArgumentsToPass
                try { $processBaseNameToMonitor = [System.IO.Path]::GetFileNameWithoutExtension($processNameToManageExpanded) }
                catch { Write-UserLog "Erreur extraction nom base de '$processNameToManageExpanded' (direct)." -L WARN; $processBaseNameToMonitor = "UnknownProcess" }
            } elseif ($launchMethod -eq "powershell") {
                $exeForStartProcess = "powershell.exe"
                $commandToRun = "& `"$processNameToManageExpanded`""
                if (-not [string]::IsNullOrWhiteSpace($processArgumentsToPass)) { $commandToRun += " $processArgumentsToPass" }
                $argsForStartProcess = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $commandToRun)
                try { $processBaseNameToMonitor = [System.IO.Path]::GetFileNameWithoutExtension($processNameToManageExpanded) }
                catch { $processBaseNameToMonitor = "powershell" }
            } elseif ($launchMethod -eq "cmd") {
                $exeForStartProcess = "cmd.exe"
                $commandToRun = "/c `"$processNameToManageExpanded`""
                if (-not [string]::IsNullOrWhiteSpace($processArgumentsToPass)) { $commandToRun += " $processArgumentsToPass" }
                $argsForStartProcess = $commandToRun
                try { $processBaseNameToMonitor = [System.IO.Path]::GetFileNameWithoutExtension($processNameToManageExpanded) }
                catch { $processBaseNameToMonitor = "cmd" }
            } else {
                Add-UserError "LaunchMethod '$launchMethod' non reconnu. Options: direct, powershell, cmd."
                if ([string]::IsNullOrWhiteSpace($exeForStartProcess)) { throw "LaunchMethod non gere ou ProcessName invalide." }
            }

            if ($launchMethod -ne "direct") {
                $interpreterPath = (Get-Command $exeForStartProcess -ErrorAction SilentlyContinue).Source
                if (-not (Test-Path -LiteralPath $interpreterPath -PathType Leaf)) {
                    Add-UserError "Interpreteur '$exeForStartProcess' non trouve pour LaunchMethod '$launchMethod'."
                    throw "Interpreteur pour LaunchMethod non trouve."
                }
            }

            $workingDir = ""
            if ($processNameIsFilePath) {
                try { $workingDir = Split-Path -Path $processNameToManageExpanded -Parent } catch {}
            } elseif ($launchMethod -ne "direct") {
                 $workingDir = $ScriptDir
                 Write-UserLog "ProcessName '$processNameToManageExpanded' non chemin fichier; WorkingDir='$ScriptDir' pour '$launchMethod'." -L WARN
            }
            if (-not [string]::IsNullOrWhiteSpace($workingDir) -and (-not (Test-Path -LiteralPath $workingDir -PathType Container))) {
                Write-UserLog "Repertoire de travail '$workingDir' non trouve. WorkingDirectory non defini." -L WARN
                $workingDir = ""
            }

            try {
                $currentUserSID = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
                $runningProcess = $null
                if (-not [string]::IsNullOrWhiteSpace($processBaseNameToMonitor)) {
                    Get-Process -Name $processBaseNameToMonitor -ErrorAction SilentlyContinue | ForEach-Object {
                        try {
                            $ownerInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" | Select-Object -ExpandProperty @{Name="Owner"; Expression={ $_.GetProcessOwner() }} -ErrorAction SilentlyContinue
                            if ($ownerInfo -and $ownerInfo.SID -eq $currentUserSID) { $runningProcess = $_; break } # break sort de ForEach-Object ici
                        } catch {}
                    }
                } else { Write-UserLog "Nom de base du processus a monitorer est vide." -L WARN }

                $startProcessSplat = @{ FilePath = $exeForStartProcess; ErrorAction = 'Stop' }
                if (($argsForStartProcess -is [array] -and $argsForStartProcess.Count -gt 0) -or
                    ($argsForStartProcess -is [string] -and -not [string]::IsNullOrWhiteSpace($argsForStartProcess))) {
                    $startProcessSplat.ArgumentList = $argsForStartProcess
                }
                if (-not [string]::IsNullOrWhiteSpace($workingDir)) { $startProcessSplat.WorkingDirectory = $workingDir }

                if ($runningProcess) {
                    Write-UserLog "Processus '$processBaseNameToMonitor' (PID: $($runningProcess.Id)) en cours. Arret..."
                    $runningProcess | Stop-Process -Force -ErrorAction Stop
                    Add-UserAction "Processus '$processBaseNameToMonitor' arrete."
                    $logArgsForRestart = if ($argsForStartProcess -is [array]) { $argsForStartProcess -join ' ' } else { $argsForStartProcess }
                    Write-UserLog "Redemarrage via $launchMethod : '$exeForStartProcess' avec args: '$logArgsForRestart'"
                    Start-Process @startProcessSplat
                    Add-UserAction "Processus '$processBaseNameToMonitor' redemarre (via $launchMethod)."
                } else {
                    $logArgsForStart = if ($argsForStartProcess -is [array]) { $argsForStartProcess -join ' ' } else { $argsForStartProcess }
                    Write-UserLog "Processus '$processBaseNameToMonitor' non trouve. Demarrage via $launchMethod : '$exeForStartProcess' avec args: '$logArgsForStart'"
                    Start-Process @startProcessSplat
                    Add-UserAction "Processus '$processBaseNameToMonitor' demarre (via $launchMethod)."
                }
            } catch {
                $logArgsCatch = if ($argsForStartProcess -is [array]) { $argsForStartProcess -join ' ' } else { $argsForStartProcess }
                Add-UserError "Echec gestion processus '$processBaseNameToMonitor' (Methode: $launchMethod, Path: '$exeForStartProcess', Args: '$logArgsCatch'): $($_.Exception.Message). StackTrace: $($_.ScriptStackTrace)"
            }
        } else {
            Add-UserError "Fichier executable pour ProcessName '$processNameToManageExpanded' (mode direct) INTROUVABLE."
        }
    } else {
        Write-UserLog -Message "Aucun ProcessName specifie dans [Process] ou chemin brut vide."
    }

} catch {
    # Utilisation de $null -ne $Global:Config comme dans config_systeme.ps1
    if ($null -ne $Global:Config) {
        Add-UserError -Message "ERREUR FATALE SCRIPT UTILISATEUR '$($env:USERNAME)': $($_.Exception.Message) `n$($_.ScriptStackTrace)"
    } else {
        $timestampError = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $errorMsg = "$timestampError [FATAL SCRIPT USER ERROR - CONFIG NON INITIALISEE/CHARGEE] - Erreur: $($_.Exception.Message) `nStackTrace: $($_.ScriptStackTrace)"
        try { Add-Content -Path (Join-Path $LogDirToUseUser "config_utilisateur_FATAL_ERROR.txt") -Value $errorMsg -ErrorAction SilentlyContinue } catch {}
        try { Add-Content -Path (Join-Path $ScriptDir "config_utilisateur_FATAL_ERROR_fallback.txt") -Value $errorMsg -ErrorAction SilentlyContinue } catch {}
        Write-Host $errorMsg -ForegroundColor Red
    }
} finally {
    # --- Notification Gotify ---
    if ($Global:Config -and (Get-ConfigValue -Section "Gotify" -Key "EnableGotify" -Type ([bool]) -DefaultValue $false)) {
        $gotifyUrl = Get-ConfigValue -Section "Gotify" -Key "Url"
        $gotifyToken = Get-ConfigValue -Section "Gotify" -Key "Token"
        $gotifyPriority = Get-ConfigValue -Section "Gotify" -Key "Priority" -Type ([int]) -DefaultValue 5

        if ((-not [string]::IsNullOrWhiteSpace($gotifyUrl)) -and (-not [string]::IsNullOrWhiteSpace($gotifyToken))) {
            Write-UserLog -Message "Preparation de la notification Gotify pour le script utilisateur..."

            $titleSuccessTemplateUser = Get-ConfigValue -Section "Gotify" -Key "GotifyTitleSuccessUser" -DefaultValue ("%COMPUTERNAME% %USERNAME% " + $ScriptIdentifierUser + " OK")
            $titleErrorTemplateUser = Get-ConfigValue -Section "Gotify" -Key "GotifyTitleErrorUser" -DefaultValue ("ERREUR " + $ScriptIdentifierUser + " %USERNAME% sur %COMPUTERNAME%")

            $finalMessageTitleUser = ""
            if ($Global:UserErreursRencontrees.Count -gt 0) {
                $finalMessageTitleUser = $titleErrorTemplateUser -replace "%COMPUTERNAME%", $env:COMPUTERNAME -replace "%USERNAME%", $env:USERNAME
            } else {
                $finalMessageTitleUser = $titleSuccessTemplateUser -replace "%COMPUTERNAME%", $env:COMPUTERNAME -replace "%USERNAME%", $env:USERNAME
            }

            #$messageBodyUser = "Script '$ScriptIdentifierUser' (Build: $ScriptInternalBuildUser) pour $($env:USERNAME) le $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss').`n`n"
            #$messageBodyUser = "'$ScriptIdentifierUser' le $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss').`n`n"
            $messageBodyUser = "Le $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss').`n"
            if ($Global:UserActionsEffectuees.Count -gt 0) { $messageBodyUser += "Actions UTILISATEUR:`n" + ($Global:UserActionsEffectuees -join "`n") }
            else { $messageBodyUser += "Aucune action UTILISATEUR." }
            if ($Global:UserErreursRencontrees.Count -gt 0) { $messageBodyUser += "`n`nErreurs UTILISATEUR:`n" + ($Global:UserErreursRencontrees -join "`n") }

            $payloadUser = @{ message = $messageBodyUser; title = $finalMessageTitleUser; priority = $gotifyPriority } | ConvertTo-Json -Depth 3 -Compress
            $fullUrlUser = "$($gotifyUrl.TrimEnd('/'))/message?token=$gotifyToken"
            Write-UserLog -Message "Envoi Gotify (utilisateur) a $fullUrlUser..."
            try { Invoke-RestMethod -Uri $fullUrlUser -Method Post -Body $payloadUser -ContentType "application/json" -TimeoutSec 30 -ErrorAction Stop
                Write-UserLog -Message "Gotify (utilisateur) envoyee."
            } catch { Add-UserError "Echec Gotify (IRM): $($_.Exception.Message)"; $curlUserPath=Get-Command curl -ErrorAction SilentlyContinue
                if ($curlUserPath) { Write-UserLog "Repli curl Gotify (utilisateur)..."; $tempJsonFileUser = Join-Path $env:TEMP "gotify_user_$($PID)_$((Get-Random).ToString()).json"
                    try { $payloadUser|Out-File $tempJsonFileUser -Encoding UTF8 -ErrorAction Stop; $curlArgsUser="-s -k -X POST `"$fullUrlUser`" -H `"Content-Type: application/json`" -d `@`"$tempJsonFileUser`""
                        Invoke-Expression "curl $($curlArgsUser -join ' ')"|Out-Null; Write-UserLog "Gotify (utilisateur - curl) envoyee."
                    } catch { Add-UserError "Echec Gotify (curl): $($_.Exception.Message)" }
                    finally { if (Test-Path $tempJsonFileUser) { Remove-Item $tempJsonFileUser -ErrorAction SilentlyContinue } }
                } else { Add-UserError "curl.exe non trouve pour repli Gotify (utilisateur)." }
            }
        } else { Add-UserError "Params Gotify incomplets pour script utilisateur." }
    }

    Write-UserLog -Message "$ScriptIdentifierUser ($ScriptInternalBuildUser) pour '$($env:USERNAME)' terminee."
    if ($Global:UserErreursRencontrees.Count -gt 0) { Write-UserLog -Message "Des erreurs se sont produites." -Level WARN }
}
