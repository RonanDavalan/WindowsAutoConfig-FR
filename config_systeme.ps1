#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Script de configuration SYSTEME automatisee pour Windows.
.DESCRIPTION
    Lit les parametres depuis config.ini et applique les configurations SYSTEME.
    Gère la rotation de ses logs et des logs du script utilisateur.
    Gère une action planifiée avant le redémarrage système, en ciblant l'utilisateur
    de l'autologon pour %USERPROFILE% dans PreRebootActionCommand.
    Envoie sa propre notification Gotify.
.NOTES
    Auteur: Ronan Davalan & Gemini 2.5-pro
    Version: Voir la configuration globale du projet (config.ini ou documentation)
#>

# --- Fonction de Rotation des Logs ---
function Rotate-LogFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$BaseLogPath,
        [Parameter(Mandatory=$true)][string]$LogExtension = ".txt",
        [Parameter(Mandatory=$true)][int]$MaxLogsToKeep = 7
    )
    if ($MaxLogsToKeep -lt 1) { return }
    $oldestArchiveIndex = if ($MaxLogsToKeep -eq 1) { 1 } else { $MaxLogsToKeep - 1 }
    $oldestArchive = "$($BaseLogPath).$($oldestArchiveIndex)$LogExtension"
    if (Test-Path $oldestArchive) { Remove-Item $oldestArchive -ErrorAction SilentlyContinue }
    if ($MaxLogsToKeep -gt 1) {
        for ($i = $MaxLogsToKeep - 2; $i -ge 1; $i--) {
            $currentArchive = "$($BaseLogPath).$i$LogExtension"; $nextArchive = "$($BaseLogPath).$($i + 1)$LogExtension"
            if (Test-Path $currentArchive) {
                if (Test-Path $nextArchive) { Remove-Item $nextArchive -Force -ErrorAction SilentlyContinue }
                Rename-Item $currentArchive $nextArchive -ErrorAction SilentlyContinue
            }
        }
    }
    $currentLogFileToArchive = "$BaseLogPath$LogExtension"; $firstArchive = "$($BaseLogPath).1$LogExtension"
    if (Test-Path $currentLogFileToArchive) {
        if (Test-Path $firstArchive) { Remove-Item $firstArchive -Force -ErrorAction SilentlyContinue }
        Rename-Item $currentLogFileToArchive $firstArchive -ErrorAction SilentlyContinue
    }
}

# --- Get-IniContent (doit être définie tôt pour la rotation) ---
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
                    $key = $matches[1].Trim(); $value = $matches[2].Trim()
                    $ini[$currentSection][$key] = $value
                }
            }
        }
    } catch { return $null }
    return $ini
}

# --- Configuration Globale & Initialisation Précoce des Logs ---
$ScriptIdentifier = "AllSysConfig-Systeme"
$ScriptInternalBuild = "Build-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
if ($MyInvocation.MyCommand.CommandType -eq 'ExternalScript') { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
else { try { $ScriptDir = Split-Path -Parent $script:MyInvocation.MyCommand.Path -ErrorAction Stop } catch { $ScriptDir = Get-Location } }

$TargetLogDir = Join-Path -Path $ScriptDir -ChildPath "Logs"
$LogDirToUse = $ScriptDir
if (Test-Path $TargetLogDir -PathType Container) { $LogDirToUse = $TargetLogDir }
else { try { New-Item -Path $TargetLogDir -ItemType Directory -Force -ErrorAction Stop | Out-Null; $LogDirToUse = $TargetLogDir } catch {} }

$BaseLogPathForRotationSystem = Join-Path -Path $LogDirToUse -ChildPath "config_systeme_ps_log"
$BaseLogPathForRotationUser = Join-Path -Path $LogDirToUse -ChildPath "config_utilisateur_log"
$DefaultMaxLogs = 7

$tempConfigFile = Join-Path -Path $ScriptDir -ChildPath "config.ini"
$tempIniContent = Get-IniContent -FilePath $tempConfigFile
$rotationEnabledByConfig = $true
if ($null -ne $tempIniContent -and $tempIniContent.ContainsKey("Logging") -and $tempIniContent["Logging"].ContainsKey("EnableLogRotation")) {
    if ($tempIniContent["Logging"]["EnableLogRotation"].ToLower() -eq "false") { $rotationEnabledByConfig = $false }
}
if ($rotationEnabledByConfig) {
    Rotate-LogFile -BaseLogPath $BaseLogPathForRotationSystem -LogExtension ".txt" -MaxLogsToKeep $DefaultMaxLogs
    Rotate-LogFile -BaseLogPath $BaseLogPathForRotationUser -LogExtension ".txt" -MaxLogsToKeep $DefaultMaxLogs
}

$LogFile = Join-Path -Path $LogDirToUse -ChildPath "config_systeme_ps_log.txt"
$ConfigFile = Join-Path -Path $ScriptDir -ChildPath "config.ini"
$Global:ActionsEffectuees = [System.Collections.Generic.List[string]]::new()
$Global:ErreursRencontrees = [System.Collections.Generic.List[string]]::new()
$Global:Config = $null

# --- Fonctions Utilitaires (Write-Log, Add-Action, Add-Error, Get-ConfigValue) ---
function Write-Log {
    [CmdletBinding()] param ([string]$Message, [ValidateSet("INFO","WARN","ERROR","DEBUG")][string]$Level="INFO", [switch]$NoConsole)
    process {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"; $logEntry = "$timestamp [$Level] - $Message"
        $LogParentDir = Split-Path $LogFile -Parent
        if (-not (Test-Path -Path $LogParentDir -PathType Container)) { try { New-Item -Path $LogParentDir -ItemType Directory -Force -ErrorAction Stop | Out-Null } catch {}}
        try { Add-Content -Path $LogFile -Value $logEntry -ErrorAction Stop }
        catch {
            $fallbackLogDir = "C:\ProgramData\StartupScriptLogs"
            if (-not (Test-Path $fallbackLogDir)) { try { New-Item $fallbackLogDir -ItemType Directory -Force -EA Stop | Out-Null } catch {}}
            $fallbackLogFile = Join-Path $fallbackLogDir "config_systeme_ps_FATAL_LOG_ERROR.txt"
            $fallbackMessage = "$timestamp [FATAL_LOG_ERROR] - Erreur écriture '$LogFile': $($_.Exception.Message). Original: $logEntry"
            Write-Host $fallbackMessage -ForegroundColor Red; try { Add-Content $fallbackLogFile $fallbackMessage -EA Stop } catch {}
        }
        if (-not $NoConsole -and ($Host.Name -eq "ConsoleHost" -or $PSEdition -eq "Core")) { Write-Host $logEntry }
    }
}
function Add-Action { param([string]$ActionMessage) $Global:ActionsEffectuees.Add($ActionMessage); Write-Log -Message "ACTION: $ActionMessage" -Level "INFO" -NoConsole }
function Add-Error {
    [CmdletBinding()] param ([Parameter(Mandatory=$true,Position=0)][string]$Message)
    $detailedErrorMessage = $Message; if ([string]::IsNullOrWhiteSpace($detailedErrorMessage)) { if ($global:Error.Count -gt 0) { $lastError = $global:Error[0]; $detailedErrorMessage = "Erreur non spec. PowerShell: $($lastError.Exception.Message) - Stack: $($lastError.ScriptStackTrace) - Invocation: $($lastError.InvocationInfo.Line)"} else { $detailedErrorMessage = "Erreur non spec. et pas d'info PowerShell." } }
    $Global:ErreursRencontrees.Add($detailedErrorMessage); Write-Log -Message "ERREUR CAPTUREE: $detailedErrorMessage" -Level "ERROR"
}
function Get-ConfigValue {
    param([string]$Section, [string]$Key, [object]$DefaultValue=$null, [System.Type]$Type=([string]), [bool]$KeyMustExist=$false)
    $value = $null; $keyExists = $false; if ($null -ne $Global:Config) { $keyExists = $Global:Config.ContainsKey($Section) -and $Global:Config[$Section].ContainsKey($Key); if ($keyExists) { $value = $Global:Config[$Section][$Key] } }
    if ($KeyMustExist -and (-not $keyExists)) { return [pscustomobject]@{ Undefined = $true } }
    if (-not $keyExists) { if ($null -ne $DefaultValue) { return $DefaultValue }; if ($Type -eq ([bool])) { return $false }; if ($Type -eq ([int])) { return 0 }; return $null }
    if ([string]::IsNullOrWhiteSpace($value) -and $Type -eq ([bool])) { if ($null -ne $DefaultValue) { return $DefaultValue }; return $false }
    try { return [System.Convert]::ChangeType($value, $Type) }
    catch { Add-Error "Valeur config invalide pour [$($Section)]$($Key): '$value'. Type attendu '$($Type.Name)'. Defaut/vide utilise."; if ($null -ne $DefaultValue) { return $DefaultValue }; if ($Type -eq ([bool])) { return $false }; if ($Type -eq ([int])) { return 0 }; return $null }
}
# --- FIN Fonctions Utilitaires ---

# --- Début du Script Principal ---
try {
    $Global:Config = Get-IniContent -FilePath $ConfigFile
    if (-not $Global:Config) { $tsInitErr = Get-Date -F "yyyy-MM-dd HH:mm:ss"; try { Add-Content $LogFile "$tsInitErr [ERROR] - Impossible de lire '$ConfigFile'. Arret." } catch {}; throw "Echec critique: config.ini."}

    if ($rotationEnabledByConfig) {
        $maxSysLogs = Get-ConfigValue -Section "Logging" -Key "MaxSystemLogsToKeep" -Type ([int]) -DefaultValue $DefaultMaxLogs; if($maxSysLogs -lt 1){Write-Log "MaxSystemLogsToKeep ($maxSysLogs) invalide." -L WARN} Write-Log "Rotation logs sys active. Max(cfg):$maxSysLogs. Init($DefaultMaxLogs)." -L INFO
        $maxUserLogs = Get-ConfigValue -Section "Logging" -Key "MaxUserLogsToKeep" -Type ([int]) -DefaultValue $DefaultMaxLogs; if($maxUserLogs -lt 1){Write-Log "MaxUserLogsToKeep ($maxUserLogs) invalide." -L WARN} Write-Log "Rotation logs user active. Max(cfg):$maxUserLogs. Init($DefaultMaxLogs)." -L INFO
    } else { Write-Log "Rotation logs desactivee. Initiale ($DefaultMaxLogs) si applicable." -L INFO }

    Write-Log -Message "Demarrage de $ScriptIdentifier ($ScriptInternalBuild)..."
    $networkReady = $false; Write-Log "Verification connectivite reseau..."; for ($i = 0; $i -lt 6; $i++) { if (Test-NetConnection -ComputerName "8.8.8.8" -Port 53 -InformationLevel Quiet -WarningAction SilentlyContinue) { Write-Log "Connectivite reseau detectee."; $networkReady = $true; break }; if ($i -lt 5) { Write-Log "Reseau non dispo, tentative dans 10s..."; Start-Sleep -Seconds 10 }}; if (-not $networkReady) { Write-Log "Reseau non etabli. Gotify pourrait echouer." -Level "WARN" }
    Write-Log "Execution actions SYSTEME configurees..."

    # Détermination de l'utilisateur cible pour les configurations qui en ont besoin (Autologon, PreRebootAction %USERPROFILE%)
    $targetUsernameForConfiguration = Get-ConfigValue -Section "SystemConfig" -Key "AutoLoginUsername"
    if ([string]::IsNullOrWhiteSpace($targetUsernameForConfiguration)) {
        Write-Log "AutoLoginUsername non specifie. Tentative lecture DefaultUserName Registre." -L INFO
        try {
            $winlogonKeyForDefaultUser = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
            $regDefaultUser = (Get-ItemProperty -Path $winlogonKeyForDefaultUser -Name DefaultUserName -ErrorAction SilentlyContinue).DefaultUserName
            if (-not [string]::IsNullOrWhiteSpace($regDefaultUser)) {
                $targetUsernameForConfiguration = $regDefaultUser
                Write-Log "DefaultUserName Registre utilise comme utilisateur cible: $targetUsernameForConfiguration." -L INFO
            } else { Write-Log "DefaultUserName Registre non trouve ou vide. Aucun utilisateur cible par defaut." -L WARN }
        } catch { Write-Log "Erreur lecture DefaultUserName Registre: $($_.Exception.Message)" -L WARN }
    } else { Write-Log "AutoLoginUsername du config.ini utilise comme utilisateur cible: $targetUsernameForConfiguration." -L INFO }

    # --- Gérer le Démarrage Rapide ---
    $disableFastStartup = Get-ConfigValue -Section "SystemConfig" -Key "DisableFastStartup" -Type ([bool]) -KeyMustExist $true
    if ($disableFastStartup -is [pscustomobject] -and $disableFastStartup.Undefined) { Write-Log "Param 'DisableFastStartup' non specifie." -L INFO }
    else {
        $powerRegPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power"
        if (-not(Test-Path $powerRegPath)){ Add-Error "Reg Power introuvable: $powerRegPath" }
        else {
            $currentHiberboot = (Get-ItemProperty -Path $powerRegPath -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
            if($disableFastStartup){ Write-Log "Cfg: Desact. FastStartup."
                if($currentHiberboot -ne 0){ try{Set-ItemProperty $powerRegPath HiberbootEnabled 0 -Force -EA Stop;Add-Action "FastStartup desactive."}catch{Add-Error "Echec desact. FastStartup: $($_.Exception.Message)"} }
                else{ Write-Log "FastStartup deja desact." -L INFO;Add-Action "FastStartup verifie (deja desact.)" }
            } else { Write-Log "Cfg: Act. FastStartup."
                if($currentHiberboot -ne 1){ try{Set-ItemProperty $powerRegPath HiberbootEnabled 1 -Force -EA Stop;Add-Action "FastStartup active."}catch{Add-Error "Echec act. FastStartup: $($_.Exception.Message)"} }
                else{ Write-Log "FastStartup deja act." -L INFO;Add-Action "FastStartup verifie (deja act.)" }
            }
        }
    }

    # --- Désactiver mise en veille machine ---
    if (Get-ConfigValue "SystemConfig" "DisableSleep" -Type ([bool]) -DefaultValue $false) { Write-Log "Desact. veille machine..."; try {
        powercfg /change standby-timeout-ac 0 | Out-Null; powercfg /change standby-timeout-dc 0 | Out-Null
        powercfg /change hibernate-timeout-ac 0 | Out-Null; powercfg /change hibernate-timeout-dc 0 | Out-Null
        Add-Action "Veille machine (S3/S4) desactivee." } catch { Add-Error "Echec desact. veille machine: $($_.Exception.Message)" }}

    # --- Désactiver mise en veille écran ---
    if (Get-ConfigValue "SystemConfig" "DisableScreenSleep" -Type ([bool]) -DefaultValue $false) { Write-Log "Desact. veille ecran..."; try {
        powercfg /change monitor-timeout-ac 0 | Out-Null; powercfg /change monitor-timeout-dc 0 | Out-Null
        Add-Action "Veille ecran desactivee." } catch { Add-Error "Echec desact. veille ecran: $($_.Exception.Message)" }}

    # --- Gérer AutoLogin ---
    $enableAutoLogin = Get-ConfigValue "SystemConfig" "EnableAutoLogin" -Type ([bool]) -DefaultValue $false
    $winlogonKeyForAutologon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" # variable distincte
    if ($enableAutoLogin) { Write-Log "Verif/Activ. AutoLogin..."
        if (-not [string]::IsNullOrWhiteSpace($targetUsernameForConfiguration)) { try {
            Set-ItemProperty -Path $winlogonKeyForAutologon -Name AutoAdminLogon -Value "1" -Type String -Force -ErrorAction Stop; Add-Action "AutoAdminLogon active."
            Set-ItemProperty -Path $winlogonKeyForAutologon -Name DefaultUserName -Value $targetUsernameForConfiguration -Type String -Force -ErrorAction Stop; Add-Action "DefaultUserName: $targetUsernameForConfiguration."
            } catch { Add-Error "Echec cfg AutoLogin: $($_.Exception.Message)" }}
        else { Write-Log "EnableAutoLogin=true mais user cible non determinable." -L WARN; Add-Error "AutoLogin active mais user cible non determinable."}
    } else { Write-Log "Desactiv. AutoLogin..."; try {
        Set-ItemProperty -Path $winlogonKeyForAutologon -Name AutoAdminLogon -Value "0" -Type String -Force -ErrorAction Stop; Add-Action "AutoAdminLogon desactive."
        } catch { Add-Error "Echec desact. AutoAdminLogon: $($_.Exception.Message)" }}

    # --- Gérer MAJ Windows ---
    $disableWindowsUpdate = Get-ConfigValue "SystemConfig" "DisableWindowsUpdate" -Type ([bool]) -DefaultValue $false
    $windowsUpdatePolicyKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"; $windowsUpdateService = "wuauserv"
    try { if(-not(Test-Path $windowsUpdatePolicyKey)){New-Item $windowsUpdatePolicyKey -Force -EA Stop|Out-Null}
        if($disableWindowsUpdate){ Write-Log "Desactiv. MAJ Win..."; Set-ItemProperty $windowsUpdatePolicyKey NoAutoUpdate 1 -Type DWord -Force -EA Stop
            Get-Service $windowsUpdateService -EA Stop|Set-Service -StartupType Disabled -PassThru -EA Stop|Stop-Service -Force -EA SilentlyContinue; Add-Action "MAJ Win desactivees."}
        else{ Write-Log "Activ. MAJ Win..."; Set-ItemProperty $windowsUpdatePolicyKey NoAutoUpdate 0 -Type DWord -Force -EA Stop
            Get-Service $windowsUpdateService -EA Stop|Set-Service -StartupType Automatic -PassThru -EA Stop|Start-Service -EA SilentlyContinue; Add-Action "MAJ Win activees."}
    } catch { Add-Error "Echec gestion MAJ Win: $($_.Exception.Message)"}

    # --- Désactiver redémarrages auto (WU) ---
    if(Get-ConfigValue "SystemConfig" "DisableAutoReboot" -Type ([bool]) -DefaultValue $false){ Write-Log "Desactiv. redem. auto (WU)..."; try {
        if(-not(Test-Path $windowsUpdatePolicyKey)){New-Item $windowsUpdatePolicyKey -Force -EA Stop|Out-Null}
        Set-ItemProperty $windowsUpdatePolicyKey NoAutoRebootWithLoggedOnUsers 1 -Type DWord -Force -EA Stop; Add-Action "Redem. auto (WU) desactives."
        } catch { Add-Error "Echec desact. redem. auto: $($_.Exception.Message)"}}

    # --- Configurer redémarrage planifié ---
    $rebootTime = Get-ConfigValue "SystemConfig" "ScheduledRebootTime"
    $rebootTaskName = "AllSys_SystemScheduledReboot"
    if (-not [string]::IsNullOrWhiteSpace($rebootTime)) { Write-Log "Cfg redem. planifie a $rebootTime...";
        $shutdownPath = Join-Path $env:SystemRoot "System32\shutdown.exe"
        $rebootDesc = "Redem. quotidien par AllSysConfig (Build: $ScriptInternalBuild)"
        $rebootAction = New-ScheduledTaskAction -Execute $shutdownPath -Argument "/r /f /t 60 /c `"$rebootDesc`""
        try {
            $rebootTrigger = New-ScheduledTaskTrigger -Daily -At $rebootTime -ErrorAction Stop
            $rebootPrincipal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\System" -LogonType ServiceAccount -RunLevel Highest
            $rebootSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2) -Compatibility Win8
            Unregister-ScheduledTask -TaskName $rebootTaskName -Confirm:$false -ErrorAction SilentlyContinue
            Register-ScheduledTask -TaskName $rebootTaskName -Action $rebootAction -Trigger $rebootTrigger -Principal $rebootPrincipal -Settings $rebootSettings -Description $rebootDesc -Force -ErrorAction Stop
            Add-Action "Redem. planifie a $rebootTime (Tache: $rebootTaskName)."
        } catch { Add-Error "Echec cfg redem. planifie ($rebootTime) tache '$rebootTaskName': $($_.Exception.Message)." }}
    else { Write-Log "ScheduledRebootTime non spec. Suppression tache '$rebootTaskName'." -L INFO; Unregister-ScheduledTask $rebootTaskName -Confirm:$false -ErrorAction SilentlyContinue }

    # --- Configurer l'action préparatoire avant redémarrage (Candidate v1.4) ---
    Write-Log -Message "Debut configuration de l'action pre-redemarrage..." -Level DEBUG

    $preRebootActionTime = Get-ConfigValue -Section "SystemConfig" -Key "PreRebootActionTime"
    $preRebootCmdFromFile = Get-ConfigValue -Section "SystemConfig" -Key "PreRebootActionCommand"
    $preRebootArgsFromFile = Get-ConfigValue -Section "SystemConfig" -Key "PreRebootActionArguments"
    $preRebootLaunchMethodFromFile = (Get-ConfigValue -Section "SystemConfig" -Key "PreRebootActionLaunchMethod" -DefaultValue "direct").ToLower()

    $preRebootTaskName = "AllSys_SystemPreRebootAction"

    if ((-not [string]::IsNullOrWhiteSpace($preRebootActionTime)) -and (-not [string]::IsNullOrWhiteSpace($preRebootCmdFromFile))) {
        Write-Log -Message "Parametres PreReboot valides detectes: Time='$preRebootActionTime', Command='$preRebootCmdFromFile', Args='$preRebootArgsFromFile', Method='$preRebootLaunchMethodFromFile'."

        # Chemin brut depuis config.ini, sans les guillemets externes
        $programToExecute = $preRebootCmdFromFile.Trim('"')

        if ($programToExecute -match "%USERPROFILE%") {
            if (-not [string]::IsNullOrWhiteSpace($targetUsernameForConfiguration)) {
                $userProfilePathTarget = $null
                try {
                    $userAccount = New-Object System.Security.Principal.NTAccount($targetUsernameForConfiguration)
                    $userSid = $userAccount.Translate([System.Security.Principal.SecurityIdentifier]).Value
                    $userProfilePathTarget = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$userSid" -Name ProfileImagePath -ErrorAction Stop).ProfileImagePath
                } catch {
                    Add-Error -Message "Impossible de determiner le chemin du profil pour '$targetUsernameForConfiguration' via SID pour PreRebootAction. Erreur: $($_.Exception.Message)"
                    $userProfilePathTarget = "C:\Users\$targetUsernameForConfiguration" # Fallback heuristique
                    Write-Log -Message "Utilisation du chemin construit '$userProfilePathTarget' comme fallback pour le profil de '$targetUsernameForConfiguration'." -Level WARN
                }

                if (-not [string]::IsNullOrWhiteSpace($userProfilePathTarget) -and (Test-Path $userProfilePathTarget -PathType Container)) {
                    $programToExecute = $programToExecute -replace "%USERPROFILE%", [regex]::Escape($userProfilePathTarget)
                    Write-Log -Message "%USERPROFILE% dans PreRebootActionCommand remplace par '$userProfilePathTarget'. Chemin resultant: '$programToExecute'" -Level INFO
                } else {
                    Add-Error -Message "Profil '$userProfilePathTarget' pour l'utilisateur cible '$targetUsernameForConfiguration' non trouve/invalide. %USERPROFILE% non resolu."
                    # Laisser $programToExecute avec %USERPROFILE%, l'expansion par SYSTEM sera le fallback risqué
                    Write-Log -Message "Laissant %USERPROFILE% pour expansion par SYSTEM pour PreRebootActionCommand: '$programToExecute'" -Level WARN
                }
            } else {
                Add-Error -Message "%USERPROFILE% detecte dans PreRebootActionCommand, mais utilisateur cible (AutoLoginUsername) non determine. %USERPROFILE% ne sera pas resolu a un utilisateur specifique."
                # Laisser $programToExecute avec %USERPROFILE%
                Write-Log -Message "Laissant %USERPROFILE% pour expansion par SYSTEM pour PreRebootActionCommand: '$programToExecute'" -Level WARN
            }
        }

        # ----- DEBUT DE LA MODIFICATION POUR CHEMINS RELATIFS AU PROJET -----
        # Si $programToExecute n'est pas un chemin absolu, ni une variable d'env, ni une commande simple du PATH,
        # on essaie de le résoudre par rapport à $ScriptDir (répertoire racine du projet).
        if (($programToExecute -notmatch '^[a-zA-Z]:\\') -and `
            ($programToExecute -notmatch '^\\\\') -and `
            ($programToExecute -notmatch '^%') -and `
            (-not (Get-Command $programToExecute -CommandType Application,ExternalScript -ErrorAction SilentlyContinue)) ) {

            $potentialProjectPath = ""
            try {
                # S'assurer que $ScriptDir est un chemin absolu avant Join-Path
                if (-not [System.IO.Path]::IsPathRooted($ScriptDir)) {
                    # Ceci ne devrait pas arriver si $ScriptDir est correctement initialisé
                    Add-Error -Message "Le repertoire racine du script (\$ScriptDir='$ScriptDir') n'est pas un chemin absolu. Impossible de resoudre le chemin relatif '$programToExecute'."
                } else {
                    $potentialProjectPath = Join-Path -Path $ScriptDir -ChildPath $programToExecute -Resolve -ErrorAction SilentlyContinue
                }
            } catch {
                 Add-Error -Message "Erreur lors de la tentative de Join-Path pour '$ScriptDir' et '$programToExecute': $($_.Exception.Message)"
            }

            if (-not [string]::IsNullOrWhiteSpace($potentialProjectPath) -and (Test-Path -LiteralPath $potentialProjectPath -PathType Leaf)) {
                Write-Log -Message "PreRebootActionCommand '$preRebootCmdFromFile' (interprete comme '$programToExecute') resolu en chemin relatif au projet: '$potentialProjectPath'" -Level DEBUG
                $programToExecute = $potentialProjectPath
            } elseif (-not [string]::IsNullOrWhiteSpace($potentialProjectPath)) {
                 Write-Log -Message "PreRebootActionCommand '$preRebootCmdFromFile' (interprete comme '$programToExecute') ressemble a un chemin relatif au projet, mais '$potentialProjectPath' non trouve ou n'est pas un fichier." -Level WARN
            } else {
                 Write-Log -Message "PreRebootActionCommand '$preRebootCmdFromFile' (interprete comme '$programToExecute') n'a pas pu etre resolu comme chemin relatif au projet. $potentialProjectPath est vide." -Level WARN
            }
        }
        # ----- FIN DE LA MODIFICATION POUR CHEMINS RELATIFS AU PROJET -----

        # Expansion finale des autres variables d'environnement (ex: %SystemRoot%)
        try {
            $programToExecute = [System.Environment]::ExpandEnvironmentVariables($programToExecute)
        } catch {
            Add-Error -Message "Erreur lors de l'expansion des variables d'environnement finales pour PreRebootActionCommand '$programToExecute': $($_.Exception.Message)"
            # $programToExecute reste tel quel si l'expansion échoue
        }
        Write-Log -Message "Programme a executer pour PreReboot (apres tout traitement): '$programToExecute'" -Level DEBUG

        $exeForTaskScheduler = ""
        $argumentStringForTaskScheduler = ""
        $workingDirectoryForTask = "" # Initialisation

        if ($preRebootLaunchMethodFromFile -eq "direct") {
            $exeForTaskScheduler = $programToExecute
            $argumentStringForTaskScheduler = $preRebootArgsFromFile
            if (Test-Path -LiteralPath $exeForTaskScheduler -PathType Leaf) {
                try { $workingDirectoryForTask = Split-Path -Path $exeForTaskScheduler -Parent } catch {}
            }
        } elseif ($preRebootLaunchMethodFromFile -eq "powershell") {
            $exeForTaskScheduler = "powershell.exe"
            $psCommand = "& `"$programToExecute`""
            if (-not [string]::IsNullOrWhiteSpace($preRebootArgsFromFile)) { $psCommand += " $preRebootArgsFromFile" }
            $argumentStringForTaskScheduler = "-NoProfile -ExecutionPolicy Bypass -Command `"$($psCommand.Replace('"', '\"'))`""
            if (Test-Path -LiteralPath $programToExecute -PathType Leaf) { # Si c'est un script .ps1
                try { $workingDirectoryForTask = Split-Path -Path $programToExecute -Parent } catch {}
            }
        } elseif ($preRebootLaunchMethodFromFile -eq "cmd") {
            $exeForTaskScheduler = "cmd.exe"
            $cmdCommand = "/c `"$programToExecute`""
            if (-not [string]::IsNullOrWhiteSpace($preRebootArgsFromFile)) { $cmdCommand += " $preRebootArgsFromFile" }
            $argumentStringForTaskScheduler = $cmdCommand
            if (Test-Path -LiteralPath $programToExecute -PathType Leaf) { # Si c'est un .bat ou .exe
                try { $workingDirectoryForTask = Split-Path -Path $programToExecute -Parent } catch {}
            }
        } else {
            Add-Error -Message "PreRebootActionLaunchMethod '$preRebootLaunchMethodFromFile' non reconnu. Tache non creee."
            $exeForTaskScheduler = "" # Force l'échec de la création de tâche
        }

        # Si workingDirectoryForTask est vide et que ce n'est pas une commande simple, utiliser $ScriptDir comme fallback
        if ([string]::IsNullOrWhiteSpace($workingDirectoryForTask) -and `
            ($exeForTaskScheduler -notmatch '^[a-zA-Z]:\\') -and `
            ($exeForTaskScheduler -notmatch '^\\\\') -and `
            (Test-Path -LiteralPath (Join-Path $ScriptDir $exeForTaskScheduler) -ErrorAction SilentlyContinue) ) {
            # Ne pas faire cela pour les commandes simples du PATH (ex: taskkill.exe)
        } elseif ([string]::IsNullOrWhiteSpace($workingDirectoryForTask) -and (-not (Get-Command $exeForTaskScheduler -ErrorAction SilentlyContinue))) {
             # Si ce n'est pas une commande du PATH et que le working dir n'a pas été défini (ex: chemin relatif au projet non-fichier?)
             $workingDirectoryForTask = $ScriptDir
             Write-Log -Message "WorkingDirectory pour PreRebootAction non determine a partir de '$programToExecute', utilise '$ScriptDir' par defaut." -Level DEBUG
        }

        Write-Log -Message "Pour la tache PreReboot: Exe='$exeForTaskScheduler', Args='$argumentStringForTaskScheduler', WorkDir='$workingDirectoryForTask'" -Level DEBUG

        $canProceedWithTaskCreation = $false
        if (-not [string]::IsNullOrWhiteSpace($exeForTaskScheduler)) {
            if ($exeForTaskScheduler -eq "powershell.exe" -or $exeForTaskScheduler -eq "cmd.exe") {
                # Pour les interpréteurs, on vérifie que le script/programme qu'ils doivent lancer ($programToExecute) existe
                if (Test-Path -LiteralPath $programToExecute -PathType Leaf -ErrorAction SilentlyContinue) {
                    $canProceedWithTaskCreation = $true
                } elseif (Get-Command $programToExecute -ErrorAction SilentlyContinue -CommandType Application,ExternalScript) {
                    Write-Log -Message "Programme '$programToExecute' pour PreRebootAction (via $preRebootLaunchMethodFromFile) semble etre une commande du PATH." -Level WARN
                    $canProceedWithTaskCreation = $true
                } else {
                    Add-Error -Message "Script/Programme '$programToExecute' pour PreRebootAction (via $preRebootLaunchMethodFromFile) est introuvable."
                }
            } elseif (Test-Path -LiteralPath $exeForTaskScheduler -PathType Leaf -ErrorAction SilentlyContinue) {
                $canProceedWithTaskCreation = $true
            } elseif (Get-Command $exeForTaskScheduler -ErrorAction SilentlyContinue -CommandType Application,ExternalScript) {
                 Write-Log -Message "Programme '$exeForTaskScheduler' (direct) semble etre une commande du PATH." -Level WARN
                 $canProceedWithTaskCreation = $true
            } else {
                Add-Error -Message "Executable principal '$exeForTaskScheduler' pour PreRebootAction est introuvable."
            }
        } else {
             Add-Error -Message "Aucun executable determine pour PreRebootAction. Tache non creee."
        }

        if ($canProceedWithTaskCreation) {
            try {
                $taskAction = New-ScheduledTaskAction -Execute $exeForTaskScheduler
                if (-not [string]::IsNullOrWhiteSpace($argumentStringForTaskScheduler)) {
                    $taskAction.Arguments = $argumentStringForTaskScheduler
                }
                # Définir le répertoire de travail pour l'action de la tâche
                if (-not [string]::IsNullOrWhiteSpace($workingDirectoryForTask) -and (Test-Path -LiteralPath $workingDirectoryForTask -PathType Container)) {
                    $taskAction.WorkingDirectory = $workingDirectoryForTask
                } elseif (-not [string]::IsNullOrWhiteSpace($workingDirectoryForTask)) {
                    Write-Log -Message "Repertoire de travail '$workingDirectoryForTask' pour PreRebootAction est specifie mais n'existe pas ou n'est pas un conteneur. Non applique." -Level WARN
                }


                $taskTrigger = New-ScheduledTaskTrigger -Daily -At $preRebootActionTime -ErrorAction Stop
                $taskPrincipal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\System" -LogonType ServiceAccount -RunLevel Highest
                $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
                $taskDescription = "Action preparatoire avant redemarrage par AllSysConfig (Build: $ScriptInternalBuild)"

                Unregister-ScheduledTask -TaskName $preRebootTaskName -Confirm:$false -ErrorAction SilentlyContinue
                Register-ScheduledTask -TaskName $preRebootTaskName -Action $taskAction -Trigger $taskTrigger -Principal $taskPrincipal -Settings $taskSettings -Description $taskDescription -Force -ErrorAction Stop
                Add-Action "Action pre-redemarrage a '$preRebootActionTime' configuree (Tache: $preRebootTaskName)."
                Write-Log -Message "Tache '$preRebootTaskName' creee/mise a jour pour executer: '$($taskAction.Execute)' avec args: '$($taskAction.Arguments)' et WorkDir: '$($taskAction.WorkingDirectory)'" -Level INFO
            } catch {
                Add-Error -Message "Echec creation/MAJ tache '$preRebootTaskName' pour PreRebootAction: $($_.Exception.Message)"
            }
        } else {
            Write-Log -Message "Validation du programme pour PreRebootAction a echoue. Tache '$preRebootTaskName' non creee/mise a jour." -Level ERROR
        }
    } else {
        Write-Log -Message "PreRebootActionTime ou PreRebootActionCommand non specifie dans config.ini. Suppression de la tache '$preRebootTaskName' si elle existe." -Level INFO
        Unregister-ScheduledTask -TaskName $preRebootTaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    Write-Log -Message "Fin configuration de l'action pre-redemarrage." -Level DEBUG

    # --- Gérer OneDrive (politique système) ---
    $oneDrivePolicyKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive"
    if(Get-ConfigValue -Section "SystemConfig" -Key "DisableOneDrive" -Type ([bool]) -DefaultValue $false){ Write-Log -Message "Desactiv. OneDrive (politique)..."; try {
        if (-not(Test-Path $oneDrivePolicyKey)){New-Item -Path $oneDrivePolicyKey -Force -ErrorAction Stop | Out-Null}
        Set-ItemProperty -Path $oneDrivePolicyKey -Name DisableFileSyncNGSC -Value 1 -Type DWord -Force -ErrorAction Stop
        Get-Process -Name "OneDrive" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue; Add-Action "OneDrive desactive (politique)."}
        catch { Add-Error -Message "Echec desact. OneDrive: $($_.Exception.Message)"}}
    else { Write-Log -Message "Activ./Maintien OneDrive (politique)..."; try {
        if(Test-Path $oneDrivePolicyKey){ If(Get-ItemProperty -Path $oneDrivePolicyKey -Name DisableFileSyncNGSC -ErrorAction SilentlyContinue){ Remove-ItemProperty -Path $oneDrivePolicyKey -Name DisableFileSyncNGSC -Force -ErrorAction Stop }}
        Add-Action "OneDrive autorise (politique)."} catch { Add-Error -Message "Echec activ. OneDrive: $($_.Exception.Message)"}}

} catch {
    if ($null -ne $Global:Config) { Add-Error -Message "ERREUR FATALE SCRIPT (bloc principal): $($_.Exception.Message) `n$($_.ScriptStackTrace)" }
    else { $tsErr = Get-Date -Format "yyyy-MM-dd HH:mm:ss"; $errMsg = "$tsErr [FATAL SCRIPT ERROR - CONFIG NON INITIALISEE/CHARGEE] - Erreur: $($_.Exception.Message) `nStackTrace: $($_.ScriptStackTrace)"; try { Add-Content -Path (Join-Path $LogDirToUse "config_systeme_ps_FATAL_ERROR.txt") -Value $errMsg -ErrorAction SilentlyContinue } catch {}; try { Add-Content -Path (Join-Path $ScriptDir "config_systeme_ps_FATAL_ERROR_fallback.txt") -Value $errMsg -ErrorAction SilentlyContinue } catch {}; Write-Host $errMsg -ForegroundColor Red }
} finally {
    # --- Notification Gotify ---
    if ($Global:Config -and (Get-ConfigValue -Section "Gotify" -Key "EnableGotify" -Type ([bool]) -DefaultValue $false)) {
        $gotifyUrl = Get-ConfigValue -Section "Gotify" -Key "Url"; $gotifyToken = Get-ConfigValue -Section "Gotify" -Key "Token"
        $gotifyPriority = Get-ConfigValue -Section "Gotify" -Key "Priority" -Type ([int]) -DefaultValue 5
        if ((-not [string]::IsNullOrWhiteSpace($gotifyUrl)) -and (-not [string]::IsNullOrWhiteSpace($gotifyToken))) {
            $networkReadyForGotify = $false; if($networkReady){$networkReadyForGotify=$true} else { Write-Log -Message "Re-verif net pour Gotify..." -Level WARN; if(Test-NetConnection -ComputerName "8.8.8.8" -Port 53 -InformationLevel Quiet -WarningAction SilentlyContinue){Write-Log -Message "Net pour Gotify OK.";$networkReadyForGotify=$true}else{Write-Log -Message "Net pour Gotify tjrs KO." -Level WARN}}
            if($networkReadyForGotify){ Write-Log -Message "Preparation notif Gotify (systeme)..."
                $titleSuccessTemplate = Get-ConfigValue -Section "Gotify" -Key "GotifyTitleSuccessSystem" -DefaultValue ("%COMPUTERNAME% " + $ScriptIdentifier + " OK")
                $titleErrorTemplate = Get-ConfigValue -Section "Gotify" -Key "GotifyTitleErrorSystem" -DefaultValue ("ERREUR " + $ScriptIdentifier + " sur %COMPUTERNAME%")
                $finalMessageTitle = if($Global:ErreursRencontrees.Count -gt 0){$titleErrorTemplate -replace "%COMPUTERNAME%",$env:COMPUTERNAME}else{$titleSuccessTemplate -replace "%COMPUTERNAME%",$env:COMPUTERNAME}
                #$messageBody = "Script '$ScriptIdentifier' (Build: $ScriptInternalBuild) le $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss').`n`n"
                #$messageBody = "'$ScriptIdentifier' le $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss').`n`n"
                $messageBody = "Le $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss').`n"
                if($Global:ActionsEffectuees.Count -gt 0){$messageBody += "Actions SYSTEME:`n" + ($Global:ActionsEffectuees -join "`n")}else{$messageBody += "Aucune action SYSTEME."}
                if($Global:ErreursRencontrees.Count -gt 0){$messageBody += "`n`nErreurs SYSTEME:`n" + ($Global:ErreursRencontrees -join "`n")}
                $payload = @{message=$messageBody; title=$finalMessageTitle; priority=$gotifyPriority} | ConvertTo-Json -Depth 3 -Compress
                $fullUrl = "$($gotifyUrl.TrimEnd('/'))/message?token=$gotifyToken"
                Write-Log "Envoi Gotify (systeme) a $fullUrl..."; try { Invoke-RestMethod -Uri $fullUrl -Method Post -Body $payload -ContentType "application/json" -TimeoutSec 30 -ErrorAction Stop; Write-Log -Message "Gotify (systeme) envoyee."}
                catch {Add-Error "Echec Gotify (IRM): $($_.Exception.Message)"; $curlPath=Get-Command curl -ErrorAction SilentlyContinue
                    if($curlPath){ Write-Log "Repli curl Gotify..."; $tempJsonFile = Join-Path $env:TEMP "gotify_sys_$($PID)_$((Get-Random).ToString()).json"
                        try{$payload|Out-File $tempJsonFile -Encoding UTF8 -ErrorAction Stop; $cArgs="-s -k -X POST `"$fullUrl`" -H `"Content-Type: application/json`" -d `@`"$tempJsonFile`""
                            Invoke-Expression "curl $($cArgs -join ' ')"|Out-Null;Write-Log "Gotify (curl) envoyee."}
                        catch{Add-Error "Echec Gotify (curl): $($_.Exception.Message)"}finally{if(Test-Path $tempJsonFile){Remove-Item $tempJsonFile -ErrorAction SilentlyContinue}}}
                    else{Add-Error "curl.exe non trouve."}}}
            else {Add-Error "Reseau non dispo pour Gotify systeme."}}
        else {Add-Error "Params Gotify incomplets."}}

    Write-Log -Message "$ScriptIdentifier ($ScriptInternalBuild) terminee."
    if ($Global:ErreursRencontrees.Count -gt 0) { Write-Log -Message "Des erreurs se sont produites." -Level WARN }
    if ($Host.Name -eq "ConsoleHost" -and $Global:ErreursRencontrees.Count -gt 0 -and (-not $env:TF_BUILD)) {
        Write-Warning "Des erreurs se sont produites (script systeme). Log: $LogFile"
    }
}
