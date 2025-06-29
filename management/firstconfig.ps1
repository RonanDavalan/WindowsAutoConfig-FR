$OutputEncoding = [System.Text.UTF8Encoding]::new($true)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($true)

<#
.SYNOPSIS
    Assistant de configuration graphique pour WindowsAutoConfig.
.DESCRIPTION
    Permet à l'utilisateur de configurer les options essentielles du fichier config.ini.
.NOTES
    Auteur: Ronan Davalan & Gemini 2.5-pro
    Version: Voir la configuration globale du projet (config.ini ou documentation)
    IMPORTANT: Pour les accents, si ce script est enregistré en UTF-8, il doit l'être AVEC BOM.
               Sinon, l'enregistrer en ANSI (Windows-1252 pour le français) peut fonctionner avec Windows PowerShell.
#>

#region Setup Form and Assemblies
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

try {
    $PSScriptRootCorrected = $PSScriptRoot
    if (-not $PSScriptRootCorrected) {
        $PSScriptRootCorrected = Split-Path -Parent $MyInvocation.MyCommand.Definition
    }
    $ProjectRootDir = Split-Path -Parent $PSScriptRootCorrected -ErrorAction Stop
    $ConfigIniPath = Join-Path $ProjectRootDir "config.ini"
    # Ajouter une vérification ici que $ConfigIniPath est trouvable, sinon MessageBox d'erreur et exit.
    if (-not (Test-Path $ConfigIniPath -PathType Leaf -ErrorAction SilentlyContinue) -and -not (Test-Path (Join-Path $PSScriptRootCorrected "config.ini") -PathType Leaf)) {
         # Tenter de le trouver aussi à côté du script au cas où.
         $TestAlternativeConfigPath = Join-Path $PSScriptRootCorrected "config.ini"
         if(Test-Path $TestAlternativeConfigPath -PathType Leaf){
            $ConfigIniPath = $TestAlternativeConfigPath
            $ProjectRootDir = $PSScriptRootCorrected
         } else {
            throw "Fichier config.ini introuvable à '$ConfigIniPath' ou à '$TestAlternativeConfigPath'"
         }
    }

} catch {
    [System.Windows.Forms.MessageBox]::Show("Impossible de déterminer le chemin du fichier config.ini. Erreur: $($_.Exception.Message). Le script va se fermer.", "Erreur Critique Path", "OK", "Error")
    exit 1
}
#endregion Setup Form and Assemblies

#region Helper Functions for INI
function Get-IniValue {
    param($FilePath, $Section, $Key, $DefaultValue = "")
    if (-not (Test-Path $FilePath -PathType Leaf)) { return $DefaultValue }
    # Pour l'instant, supposons UTF8 ou ANSI compatible.
    $iniContent = Get-Content $FilePath -Encoding UTF8 -ErrorAction SilentlyContinue
    $inSection = $false
    foreach ($line in $iniContent) {
        if ($line.Trim() -eq "[$Section]") { $inSection = $true; continue }
        if ($line.Trim().StartsWith("[") -and $inSection) { $inSection = $false; break }
        if ($inSection -and $line -match "^$([regex]::Escape($Key))\s*=(.*)") { return $matches[1].Trim() }
    }
    return $DefaultValue
}

function Set-IniValue {
    param($FilePath, $Section, $Key, $Value)
    $fileExists = Test-Path $FilePath -PathType Leaf # Ajout -PathType Leaf
    $iniContent = if ($fileExists) { Get-Content $FilePath -Encoding UTF8 -ErrorAction SilentlyContinue } else { [string[]]@() } # Lire en UTF8, écrire en UTF8
    $newContent = [System.Collections.Generic.List[string]]::new()
    $sectionExists = $false; $keyExists = $false; $inTargetSection = $false
    foreach ($line in $iniContent) {
        if ($line.Trim() -eq "[$Section]") {
            $sectionExists = $true; $inTargetSection = $true
            $newContent.Add($line)
        } elseif ($line.Trim().StartsWith("[")) {
            if ($inTargetSection -and -not $keyExists) { $newContent.Add("$Key=$Value"); $keyExists = $true }
            $inTargetSection = $false
            $newContent.Add($line)
        } elseif ($inTargetSection -and $line -match "^$([regex]::Escape($Key))\s*=") {
            $newContent.Add("$Key=$Value"); $keyExists = $true
        } else { $newContent.Add($line) }
    }
    if ($inTargetSection -and -not $keyExists) {
         $newContent.Add("$Key=$Value"); $keyExists = $true
    }
    if (-not $sectionExists) {
        if ($newContent.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($newContent[$newContent.Count -1])) { $newContent.Add("") }
        $newContent.Add("[$Section]"); $newContent.Add("$Key=$Value")
    } elseif (-not $keyExists) {
        $sectionIndex = -1; for ($i = 0; $i -lt $newContent.Count; $i++) { if ($newContent[$i].Trim() -eq "[$Section]") { $sectionIndex = $i; break }}
        if ($sectionIndex -ne -1) {
            $insertAt = $sectionIndex + 1
            while ($insertAt -lt $newContent.Count -and -not $newContent[$insertAt].Trim().StartsWith("[")) { $insertAt++ }
            $newContent.Insert($insertAt, "$Key=$Value")
        } else { $newContent.Add("$Key=$Value") }
    }
    # S'assurer que le dossier parent existe avant d'écrire
    $ParentDir = Split-Path -Path $FilePath -Parent
    if (-not (Test-Path $ParentDir -PathType Container)) {
        New-Item -Path $ParentDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    }
    Out-File -FilePath $FilePath -InputObject $newContent -Encoding utf8 -Force # Ecrire en UTF8 (par défaut avec BOM en PS5.1)
}
#endregion Helper Functions for INI

#region Form Creation
$form = New-Object System.Windows.Forms.Form
$form.Text = "Assistant de Configuration - WindowsAutoConfig"
# TAILLE
$form.Size = New-Object System.Drawing.Size(590, 530)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false
#endregion Form Creation

#region Load Initial Values from config.ini
$defaultValues = @{
    AutoLoginUsername = ""; DisableFastStartup = $true; DisableSleep = $true
    DisableScreenSleep = $false; EnableAutoLogin = $true; DisableWindowsUpdate = $true
    DisableAutoReboot = $true; PreRebootActionTime = "03:55"; PreRebootActionCommand = ""
    PreRebootActionArguments = ""; PreRebootActionLaunchMethod = "powershell"
    ScheduledRebootTime = "04:00"; DisableOneDrive = $true; ProcessName = ""
    ProcessArguments = ""; LaunchMethod = "cmd"
}
$currentValues = @{}
if (-not (Test-Path $ConfigIniPath -PathType Leaf)) {
    [System.Windows.Forms.MessageBox]::Show("Fichier config.ini non trouvé. Des valeurs par défaut seront utilisées. Veuillez enregistrer pour créer le fichier.", "Information", "OK", "Information")
    $currentValues = $defaultValues.Clone()
} else {
    foreach ($key in $defaultValues.Keys) {
        $section = if ($key -in ("ProcessName", "ProcessArguments", "LaunchMethod")) { "Process" } else { "SystemConfig" }
        # DefaultValue dans Get-IniValue est utilisé si la clé n'est pas trouvée
        $rawValue = Get-IniValue -FilePath $ConfigIniPath -Section $section -Key $key -DefaultValue $defaultValues[$key]
        if ($defaultValues[$key] -is [boolean]) {
            if ($rawValue -is [boolean]) { $currentValues[$key] = $rawValue }
            elseif ([string]::IsNullOrWhiteSpace($rawValue.ToString())) { $currentValues[$key] = $defaultValues[$key] }
            else {
                # Essayer une conversion plus permissive
                if ($rawValue.ToString().ToLower() -eq "true" -or $rawValue.ToString() -eq "1") { $currentValues[$key] = $true }
                elseif ($rawValue.ToString().ToLower() -eq "false" -or $rawValue.ToString() -eq "0") { $currentValues[$key] = $false }
                else { $currentValues[$key] = $defaultValues[$key] } # Fallback
            }
        } else { $currentValues[$key] = $rawValue }
    }
}
#endregion Load Initial Values

#region Controls Creation
# Utilisation de tes noms de variables originaux ($yCurrent, $itemSpacing, etc.)
[int]$xPadding = 20
[int]$yCurrent = 20
[int]$lblWidth = 230
[int]$ctrlWidth = 270
[int]$ctrlHeight = 20
[int]$itemSpacing = 5
[int]$sectionSpacing = 10
[int]$itemTotalHeight = $ctrlHeight + $itemSpacing

# --- AutoLoginUsername ---
$lblAutoLoginUsername = New-Object System.Windows.Forms.Label
$lblAutoLoginUsername.Text = "Identifiant pour Auto-Login (optionnel) :"
$lblAutoLoginUsername.Location = New-Object System.Drawing.Point([int]$xPadding, [int]$yCurrent)
$lblAutoLoginUsername.Size = New-Object System.Drawing.Size([int]$lblWidth, [int]$ctrlHeight)
$form.Controls.Add($lblAutoLoginUsername)

$txtAutoLoginUsername = New-Object System.Windows.Forms.TextBox
$txtAutoLoginUsername.Text = $currentValues.AutoLoginUsername
$txtAutoLoginUsername.Location = New-Object System.Drawing.Point([int]($xPadding + $lblWidth + $itemSpacing), [int]$yCurrent)
$txtAutoLoginUsername.Size = New-Object System.Drawing.Size([int]$ctrlWidth, [int]$ctrlHeight)
$form.Controls.Add($txtAutoLoginUsername)
$yCurrent += $itemTotalHeight

# --- Checkboxes for SystemConfig ---
function Create-And-Add-Checkbox {
    param($FormInst, $KeyName, $LabelText, [ref]$YPos_ref, $InitialValue, [int]$LocalXPadding, [int]$LocalItemSpacing)
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Name = "cb$KeyName"; $cb.Text = $LabelText; $cb.Checked = $InitialValue
    $cb.Location = New-Object System.Drawing.Point([int]$LocalXPadding, [int]$YPos_ref.Value)
    $cb.AutoSize = $true
    $FormInst.Controls.Add($cb)
    $YPos_ref.Value += [int]($cb.Height + $LocalItemSpacing)
}
$checkboxes = @(
    @{Name="DisableFastStartup"; Label="Désactiver Démarrage Rapide (recommandé)"; Initial=$currentValues.DisableFastStartup},
    @{Name="DisableSleep"; Label="Désactiver mise en veille machine"; Initial=$currentValues.DisableSleep},
    @{Name="DisableScreenSleep"; Label="Désactiver mise en veille écran"; Initial=$currentValues.DisableScreenSleep},
    @{Name="EnableAutoLogin"; Label="Activer gestion Auto-Login (via script)"; Initial=$currentValues.EnableAutoLogin},
    @{Name="DisableWindowsUpdate"; Label="Désactiver Mises à Jour Windows (via script)"; Initial=$currentValues.DisableWindowsUpdate},
    @{Name="DisableAutoReboot"; Label="Empêcher WU de redémarrer auto (si session active)"; Initial=$currentValues.DisableAutoReboot},
    @{Name="DisableOneDrive"; Label="Désactiver OneDrive (politique système)"; Initial=$currentValues.DisableOneDrive}
)
foreach ($cbInfo in $checkboxes) {
    Create-And-Add-Checkbox $form $cbInfo.Name $cbInfo.Label ([ref]$yCurrent) $cbInfo.Initial $xPadding $itemSpacing
}
$yCurrent += $sectionSpacing

# --- Série de Label + Contrôle ---
# Je garde ta structure répétitive pour l'instant pour minimiser les changements par rapport à l'original.
# Tous les calculs de Location/Size sont explicitement castés en [int] par sécurité.

# PreRebootActionTime
$lblPreRebootActionTime = New-Object System.Windows.Forms.Label; $lblPreRebootActionTime.Text = "Heure Action Pré-Redémarrage (HH:MM) :"
$lblPreRebootActionTime.Location = New-Object System.Drawing.Point([int]$xPadding, [int]$yCurrent); $lblPreRebootActionTime.Size = New-Object System.Drawing.Size([int]$lblWidth, [int]$ctrlHeight); $form.Controls.Add($lblPreRebootActionTime)
$txtPreRebootActionTime = New-Object System.Windows.Forms.TextBox; $txtPreRebootActionTime.Text = $currentValues.PreRebootActionTime
$txtPreRebootActionTime.Location = New-Object System.Drawing.Point([int]($xPadding + $lblWidth + $itemSpacing), [int]$yCurrent); $txtPreRebootActionTime.Size = New-Object System.Drawing.Size(100, [int]$ctrlHeight); $form.Controls.Add($txtPreRebootActionTime)
$yCurrent += $itemTotalHeight

# PreRebootActionCommand
$lblPreRebootActionCommand = New-Object System.Windows.Forms.Label; $lblPreRebootActionCommand.Text = "Commande Pré-Redémarrage (chemin) :"
$lblPreRebootActionCommand.Location = New-Object System.Drawing.Point([int]$xPadding, [int]$yCurrent); $lblPreRebootActionCommand.Size = New-Object System.Drawing.Size([int]$lblWidth, [int]$ctrlHeight); $form.Controls.Add($lblPreRebootActionCommand)
$txtPreRebootActionCommand = New-Object System.Windows.Forms.TextBox; $txtPreRebootActionCommand.Text = $currentValues.PreRebootActionCommand
$txtPreRebootActionCommand.Location = New-Object System.Drawing.Point([int]($xPadding + $lblWidth + $itemSpacing), [int]$yCurrent); $txtPreRebootActionCommand.Size = New-Object System.Drawing.Size([int]$ctrlWidth, [int]$ctrlHeight); $form.Controls.Add($txtPreRebootActionCommand)
$yCurrent += $itemTotalHeight

# PreRebootActionArguments
$lblPreRebootActionArguments = New-Object System.Windows.Forms.Label; $lblPreRebootActionArguments.Text = "Arguments Commande Pré-Redémarrage :"
$lblPreRebootActionArguments.Location = New-Object System.Drawing.Point([int]$xPadding, [int]$yCurrent); $lblPreRebootActionArguments.Size = New-Object System.Drawing.Size([int]$lblWidth, [int]$ctrlHeight); $form.Controls.Add($lblPreRebootActionArguments)
$txtPreRebootActionArguments = New-Object System.Windows.Forms.TextBox; $txtPreRebootActionArguments.Text = $currentValues.PreRebootActionArguments
$txtPreRebootActionArguments.Location = New-Object System.Drawing.Point([int]($xPadding + $lblWidth + $itemSpacing), [int]$yCurrent); $txtPreRebootActionArguments.Size = New-Object System.Drawing.Size([int]$ctrlWidth, [int]$ctrlHeight); $form.Controls.Add($txtPreRebootActionArguments)
$yCurrent += $itemTotalHeight

# PreRebootActionLaunchMethod
$lblPreRebootActionLaunchMethod = New-Object System.Windows.Forms.Label; $lblPreRebootActionLaunchMethod.Text = "Méthode Lancement Pré-Redémarrage :"
$lblPreRebootActionLaunchMethod.Location = New-Object System.Drawing.Point([int]$xPadding, [int]$yCurrent); $lblPreRebootActionLaunchMethod.Size = New-Object System.Drawing.Size([int]$lblWidth, [int]$ctrlHeight); $form.Controls.Add($lblPreRebootActionLaunchMethod)
$cmbPreRebootActionLaunchMethod = New-Object System.Windows.Forms.ComboBox; $cmbPreRebootActionLaunchMethod.Items.AddRange(@("direct", "powershell", "cmd")); $cmbPreRebootActionLaunchMethod.SelectedItem = $currentValues.PreRebootActionLaunchMethod; $cmbPreRebootActionLaunchMethod.DropDownStyle = "DropDownList"
$cmbPreRebootActionLaunchMethod.Location = New-Object System.Drawing.Point([int]($xPadding + $lblWidth + $itemSpacing), [int]$yCurrent); $cmbPreRebootActionLaunchMethod.Size = New-Object System.Drawing.Size(100, [int]$ctrlHeight); $form.Controls.Add($cmbPreRebootActionLaunchMethod)
$yCurrent += $itemTotalHeight + $sectionSpacing

# ScheduledRebootTime
$lblScheduledRebootTime = New-Object System.Windows.Forms.Label; $lblScheduledRebootTime.Text = "Heure Redémarrage Quotidien (HH:MM) :"
$lblScheduledRebootTime.Location = New-Object System.Drawing.Point([int]$xPadding, [int]$yCurrent); $lblScheduledRebootTime.Size = New-Object System.Drawing.Size([int]$lblWidth, [int]$ctrlHeight); $form.Controls.Add($lblScheduledRebootTime)
$txtScheduledRebootTime = New-Object System.Windows.Forms.TextBox; $txtScheduledRebootTime.Text = $currentValues.ScheduledRebootTime
$txtScheduledRebootTime.Location = New-Object System.Drawing.Point([int]($xPadding + $lblWidth + $itemSpacing), [int]$yCurrent); $txtScheduledRebootTime.Size = New-Object System.Drawing.Size(100, [int]$ctrlHeight); $form.Controls.Add($txtScheduledRebootTime)
$yCurrent += $itemTotalHeight + $sectionSpacing

# ProcessName
$lblProcessName = New-Object System.Windows.Forms.Label; $lblProcessName.Text = "Application à Lancer (ProcessName) :" # Accent
$lblProcessName.Location = New-Object System.Drawing.Point([int]$xPadding, [int]$yCurrent); $lblProcessName.Size = New-Object System.Drawing.Size([int]$lblWidth, [int]$ctrlHeight); $form.Controls.Add($lblProcessName)
$txtProcessName = New-Object System.Windows.Forms.TextBox; $txtProcessName.Text = $currentValues.ProcessName
$txtProcessName.Location = New-Object System.Drawing.Point([int]($xPadding + $lblWidth + $itemSpacing), [int]$yCurrent); $txtProcessName.Size = New-Object System.Drawing.Size([int]$ctrlWidth, [int]$ctrlHeight); $form.Controls.Add($txtProcessName)
$yCurrent += $itemTotalHeight

# ProcessArguments
$lblProcessArguments = New-Object System.Windows.Forms.Label; $lblProcessArguments.Text = "Arguments Application Principale :"
$lblProcessArguments.Location = New-Object System.Drawing.Point([int]$xPadding, [int]$yCurrent); $lblProcessArguments.Size = New-Object System.Drawing.Size([int]$lblWidth, [int]$ctrlHeight); $form.Controls.Add($lblProcessArguments)
$txtProcessArguments = New-Object System.Windows.Forms.TextBox; $txtProcessArguments.Text = $currentValues.ProcessArguments
$txtProcessArguments.Location = New-Object System.Drawing.Point([int]($xPadding + $lblWidth + $itemSpacing), [int]$yCurrent); $txtProcessArguments.Size = New-Object System.Drawing.Size([int]$ctrlWidth, [int]$ctrlHeight); $form.Controls.Add($txtProcessArguments)
$yCurrent += $itemTotalHeight

# LaunchMethod
$lblLaunchMethod = New-Object System.Windows.Forms.Label; $lblLaunchMethod.Text = "Méthode Lancement Application Principale :"
$lblLaunchMethod.Location = New-Object System.Drawing.Point([int]$xPadding, [int]$yCurrent); $lblLaunchMethod.Size = New-Object System.Drawing.Size([int]$lblWidth, [int]$ctrlHeight); $form.Controls.Add($lblLaunchMethod)
$cmbLaunchMethod = New-Object System.Windows.Forms.ComboBox; $cmbLaunchMethod.Items.AddRange(@("direct", "powershell", "cmd")); $cmbLaunchMethod.SelectedItem = $currentValues.LaunchMethod; $cmbLaunchMethod.DropDownStyle = "DropDownList"
$cmbLaunchMethod.Location = New-Object System.Drawing.Point([int]($xPadding + $lblWidth + $itemSpacing), [int]$yCurrent); $cmbLaunchMethod.Size = New-Object System.Drawing.Size(100, [int]$ctrlHeight); $form.Controls.Add($cmbLaunchMethod)
$yCurrent += $itemTotalHeight

#endregion Controls Creation

#region Buttons
$btnSave = New-Object System.Windows.Forms.Button; $btnSave.Text = "Enregistrer et Fermer"
$calculatedX_ButtonSave = [int]($xPadding + ($lblWidth / 2))
$calculatedY_Button = [int]$yCurrent
$btnSave.Location = New-Object System.Drawing.Point($calculatedX_ButtonSave, $calculatedY_Button); $btnSave.Size = New-Object System.Drawing.Size(150, 30)
$btnSave.DialogResult = [System.Windows.Forms.DialogResult]::OK; $form.AcceptButton = $btnSave; $form.Controls.Add($btnSave)

$btnCancel = New-Object System.Windows.Forms.Button; $btnCancel.Text = "Annuler"
$calculatedX_ButtonCancel = [int]($calculatedX_ButtonSave + 150 + $itemSpacing)
$btnCancel.Location = New-Object System.Drawing.Point($calculatedX_ButtonCancel, $calculatedY_Button); $btnCancel.Size = New-Object System.Drawing.Size(100, 30)
$btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $form.CancelButton = $btnCancel; $form.Controls.Add($btnCancel)

# Ajustement de la taille du formulaire pour s'assurer que tout est visible
# $yCurrent est maintenant la position Y des boutons. On ajoute leur hauteur et un peu de marge.
$form.ClientSize = New-Object System.Drawing.Size($form.ClientSize.Width, [int]($yCurrent + 30 + $xPadding))
#endregion Buttons

#region Form Event Handlers
$btnSave.Add_Click({
    if (($txtPreRebootActionTime.Text -ne "" -and $txtPreRebootActionTime.Text -notmatch "^\d{2}:\d{2}$") -or `
        ($txtScheduledRebootTime.Text -ne "" -and $txtScheduledRebootTime.Text -notmatch "^\d{2}:\d{2}$")) {
        [System.Windows.Forms.MessageBox]::Show("Le format des heures doit être HH:MM (ex: 03:55).", "Format Invalide", "OK", "Warning")
        $form.DialogResult = [System.Windows.Forms.DialogResult]::None; return # Empêche la fermeture
    }
    Set-IniValue $ConfigIniPath "SystemConfig" "AutoLoginUsername" $txtAutoLoginUsername.Text
    Set-IniValue $ConfigIniPath "SystemConfig" "DisableFastStartup" $form.Controls["cbDisableFastStartup"].Checked.ToString().ToLower()
    Set-IniValue $ConfigIniPath "SystemConfig" "DisableSleep" $form.Controls["cbDisableSleep"].Checked.ToString().ToLower()
    Set-IniValue $ConfigIniPath "SystemConfig" "DisableScreenSleep" $form.Controls["cbDisableScreenSleep"].Checked.ToString().ToLower()
    Set-IniValue $ConfigIniPath "SystemConfig" "EnableAutoLogin" $form.Controls["cbEnableAutoLogin"].Checked.ToString().ToLower()
    Set-IniValue $ConfigIniPath "SystemConfig" "DisableWindowsUpdate" $form.Controls["cbDisableWindowsUpdate"].Checked.ToString().ToLower()
    Set-IniValue $ConfigIniPath "SystemConfig" "DisableAutoReboot" $form.Controls["cbDisableAutoReboot"].Checked.ToString().ToLower()
    Set-IniValue $ConfigIniPath "SystemConfig" "DisableOneDrive" $form.Controls["cbDisableOneDrive"].Checked.ToString().ToLower()
    Set-IniValue $ConfigIniPath "SystemConfig" "PreRebootActionTime" $txtPreRebootActionTime.Text
    Set-IniValue $ConfigIniPath "SystemConfig" "PreRebootActionCommand" $txtPreRebootActionCommand.Text
    Set-IniValue $ConfigIniPath "SystemConfig" "PreRebootActionArguments" $txtPreRebootActionArguments.Text
    Set-IniValue $ConfigIniPath "SystemConfig" "PreRebootActionLaunchMethod" $cmbPreRebootActionLaunchMethod.SelectedItem.ToString()
    Set-IniValue $ConfigIniPath "SystemConfig" "ScheduledRebootTime" $txtScheduledRebootTime.Text
    Set-IniValue $ConfigIniPath "Process" "ProcessName" $txtProcessName.Text
    Set-IniValue $ConfigIniPath "Process" "ProcessArguments" $txtProcessArguments.Text
    Set-IniValue $ConfigIniPath "Process" "LaunchMethod" $cmbLaunchMethod.SelectedItem.ToString()
    [System.Windows.Forms.MessageBox]::Show("Configuration enregistrée dans $ConfigIniPath", "Succès", "OK", "Information")
    # Le DialogResult est déjà OK, donc le formulaire se fermera.
})
# Ajout des paramètres d'événement
$form.Add_FormClosing({ param($sender, $e)
    if ($form.DialogResult -ne [System.Windows.Forms.DialogResult]::OK) {
        # Annulation ou fermeture par la croix
    }
})
#endregion Form Event Handlers

#region Show Form
[System.Windows.Forms.Application]::EnableVisualStyles()
# Le Out-Null est implicite si on assigne à une variable
$DialogResult = $form.ShowDialog()

# Gérer la sortie du script pour 1_install.bat
if ($DialogResult -eq [System.Windows.Forms.DialogResult]::OK) {
    exit 0 # Succès
} else {
    Write-Host "Assistant de configuration annulé." -ForegroundColor Yellow # Message pour la console si visible
    exit 1 # Annulé ou fermé
}
#endregion Show Form
