#requires -version 5.1

[CmdletBinding()]
param()

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

try {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class ADAccountCenterTaskbarIdentity
{
    [DllImport("shell32.dll", SetLastError = true)]
    public static extern int SetCurrentProcessExplicitAppUserModelID(string appID);
}
"@
    [ADAccountCenterTaskbarIdentity]::SetCurrentProcessExplicitAppUserModelID('ADAccountCenter') | Out-Null
}
catch {
    # The app can still run if Windows does not allow an explicit taskbar identity.
}

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

function New-AppColor {
    param([int]$Red, [int]$Green, [int]$Blue)
    return [System.Drawing.Color]::FromArgb($Red, $Green, $Blue)
}

$colorBackground = New-AppColor 22 24 30
$colorPanel = New-AppColor 31 34 42
$colorPanelRaised = New-AppColor 42 46 56
$colorInput = New-AppColor 16 18 23
$colorText = New-AppColor 239 242 247
$colorMuted = New-AppColor 159 168 184
$colorAccent = New-AppColor 111 76 224
$colorAccentDark = New-AppColor 79 55 159
$colorGreen = New-AppColor 42 153 93
$colorOrange = New-AppColor 201 126 48
$colorRed = New-AppColor 197 68 68
$colorBlue = New-AppColor 63 122 207
$colorBorder = New-AppColor 67 73 87
$colorOutput = New-AppColor 13 15 20

$script:ConfigPath = Join-Path $PSScriptRoot 'config.json'
$script:SettingsPath = Join-Path $PSScriptRoot 'settings.json'
$script:WorkerPath = Join-Path $PSScriptRoot 'ADAccountWorker.ps1'

# All environment-specific values (domain, admin account, OUs) live in
# config.json so the same code works in any Active Directory domain.
try {
    $script:Config = Get-Content -LiteralPath $script:ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
}
catch {
    [System.Windows.Forms.MessageBox]::Show(
        'Could not read config.json next to this script.' + [Environment]::NewLine + [Environment]::NewLine +
            'Copy config.example.json to config.json and fill in your domain, admin account and OUs.',
        'AD Account Center - configuration missing',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 1
}

$script:Domain = [string]$script:Config.Domain

$script:OuDestinations = [ordered]@{}
foreach ($destination in @($script:Config.MoveDestinations)) {
    $script:OuDestinations[[string]$destination.Key] = [pscustomobject]@{
        Label = [string]$destination.Label
        DistinguishedName = [string]$destination.DistinguishedName
    }
}

$script:MainForm = $null
$script:AppSettings = $null
$script:CurrentActionKey = 'check_status'
$script:CurrentDestinationKey = @($script:OuDestinations.Keys)[0]
$script:Busy = $false
$script:CurrentProcess = $null
$script:CurrentJobPath = $null
$script:CurrentOutputPath = $null
$script:DisplayedEventCount = 0
$script:TotalUsers = 0
$script:CompletedUsers = 0
$script:SuccessCount = 0
$script:NotFoundCount = 0
$script:ErrorCount = 0
$script:ActionButtons = @{}

$script:Actions = [ordered]@{
    check_status = [pscustomobject]@{
        Title = 'Check OU and Disabled Status'
        ShortTitle = 'Check Status'
        Description = 'Finds each account by email address and returns its distinguished name, OU, and disabled state.'
        Destructive = $false
        ButtonColor = $colorBlue
    }
    move_class = [pscustomobject]@{
        Title = 'Move to Destination OU'
        ShortTitle = 'Move to OU'
        Description = 'Moves one account or a pasted bulk list to the selected destination OU.'
        Destructive = $true
        ButtonColor = $colorOrange
    }
    disable = [pscustomobject]@{
        Title = 'Disable Account'
        ShortTitle = 'Disable Account'
        Description = 'Disables each selected Active Directory user account.'
        Destructive = $true
        ButtonColor = $colorOrange
    }
    move_student = [pscustomobject]@{
        Title = 'Move to Student Disabled Accounts'
        ShortTitle = 'Move Student'
        Description = 'Moves each account into Student Disabled Accounts under User Accounts.'
        Destructive = $true
        ButtonColor = $colorOrange
    }
    move_staff = [pscustomobject]@{
        Title = 'Move to Staff Disabled Accounts'
        ShortTitle = 'Move Staff'
        Description = 'Moves each account into the staff Disabled Accounts OU under User Accounts.'
        Destructive = $true
        ButtonColor = $colorOrange
    }
    remove_groups = [pscustomobject]@{
        Title = 'Remove All Groups'
        ShortTitle = 'Remove Groups'
        Description = 'Removes every returned group membership. Domain Users remains as the account primary group.'
        Destructive = $true
        ButtonColor = $colorRed
    }
}

function New-FlatButton {
    param(
        [string]$Text,
        [System.Drawing.Color]$BackColor,
        [System.Drawing.Color]$ForeColor,
        [int]$Width,
        [int]$Height
    )

    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Width = $Width
    $button.Height = $Height
    $button.BackColor = $BackColor
    $button.ForeColor = $ForeColor
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderColor = $colorBorder
    $button.FlatAppearance.BorderSize = 1
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $button.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
    $button.UseVisualStyleBackColor = $false
    return $button
}

function Get-ConfiguredAdminAccount {
    # The Windows account this app must run as (set in config.json).
    return ([string]$script:Config.AdminAccount).Trim()
}

function Get-CurrentWindowsIdentity {
    try {
        return [string][System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    }
    catch {
        return ''
    }
}

function Test-IsConfiguredIdentity {
    $configuredAccount = Get-ConfiguredAdminAccount
    $currentIdentity = Get-CurrentWindowsIdentity
    if (-not $configuredAccount -or -not $currentIdentity) {
        return $false
    }

    return $configuredAccount.Equals($currentIdentity, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-AppSettings {
    if (-not (Test-Path -LiteralPath $script:SettingsPath -PathType Leaf)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $script:SettingsPath -Raw -ErrorAction Stop | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Save-AppSettings {
    $data = @{
        LastAction = $script:CurrentActionKey
        LastDestination = $script:CurrentDestinationKey
    }

    if ($script:MainForm -and $script:MainForm.WindowState -eq [System.Windows.Forms.FormWindowState]::Normal) {
        $data.X = $script:MainForm.Left
        $data.Y = $script:MainForm.Top
        $data.Width = $script:MainForm.Width
        $data.Height = $script:MainForm.Height
    }
    elseif ($script:AppSettings) {
        $data.X = $script:AppSettings.X
        $data.Y = $script:AppSettings.Y
        $data.Width = $script:AppSettings.Width
        $data.Height = $script:AppSettings.Height
    }

    try {
        $data | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
        $script:AppSettings = [pscustomobject]$data
    }
    catch {
        # A settings failure should never block directory work.
    }
}

function Get-UserList {
    param([switch]$Quiet)

    $validUsers = New-Object System.Collections.ArrayList
    $invalidEntries = New-Object System.Collections.ArrayList
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    $rawText = [string]$script:UserInputBox.Text
    $tokens = @($rawText -split '[\s,;]+')
    foreach ($rawToken in $tokens) {
        $token = ([string]$rawToken).Trim().Trim('"').Trim("'")
        if (-not $token) {
            continue
        }

        if ($token -match '^(?i)(username|usernames|email|emails|studentid|student_id)$') {
            continue
        }

        if ($token -notmatch '@') {
            if ($token -notmatch '^[A-Za-z0-9._+-]+$') {
                $null = $invalidEntries.Add($token)
                continue
            }
            $token = $token + '@' + $script:Domain
        }

        if ($token -notmatch ('^(?i)[A-Za-z0-9._+-]+@' + [regex]::Escape($script:Domain) + '$')) {
            $null = $invalidEntries.Add($token)
            continue
        }

        $normalized = $token.ToLowerInvariant()
        if ($seen.Add($normalized)) {
            $null = $validUsers.Add($normalized)
        }
    }

    return [pscustomobject]@{
        Users = @($validUsers)
        Invalid = @($invalidEntries)
    }
}

function Build-CmdCommand {
    param(
        [string]$ActionKey,
        [string]$EmailAddress,
        [string]$DestinationKey = ''
    )

    switch ($ActionKey) {
        'disable' {
            return ('for /f "delims=" %D in (''dsquery * domainroot -filter "(mail=' +
                $EmailAddress + ')" -limit 1'') do dsmod user "%~D" -disabled yes')
        }
        'move_student' {
            return ('for /f "delims=" %D in (''dsquery * domainroot -filter "(mail=' +
                $EmailAddress + ')" -limit 1'') do dsmove "%~D" -newparent "' + $script:Config.StudentDisabledOu + '"')
        }
        'check_status' {
            return ('for /f "delims=" %D in (''dsquery * domainroot -filter "(mail=' +
                $EmailAddress + ')" -limit 1'') do dsget user "%~D" -dn -disabled')
        }
        'move_class' {
            if (-not $script:OuDestinations.Contains($DestinationKey)) {
                throw 'Select a destination OU.'
            }
            $targetOu = $script:OuDestinations[$DestinationKey].DistinguishedName
            return ('for /f "delims=" %D in (''dsquery * domainroot -filter "(mail=' +
                $EmailAddress + ')" -limit 1'') do dsmove "%~D" -newparent "' + $targetOu + '"')
        }
        'move_staff' {
            return ('for /f "delims=" %D in (''dsquery * domainroot -filter "(mail=' +
                $EmailAddress + ')" -limit 1'') do dsmove "%~D" -newparent "' + $script:Config.StaffDisabledOu + '"')
        }
        'remove_groups' {
            return ('for /f "delims=" %U in (''dsquery * domainroot -filter "(mail=' +
                $EmailAddress + ')" -limit 1'') do @for /f "delims=" %G in (''dsget user "%~U" -memberof 2^>nul ^| findstr /V /C:"dsget succeeded"'') do @dsmod group "%~G" -rmmbr "%~U"')
        }
        default {
            throw ('Unknown action: ' + $ActionKey)
        }
    }
}

function Update-InputSummary {
    if (-not $script:UserInputBox) {
        return
    }

    $parsed = Get-UserList -Quiet
    $validCount = $parsed.Users.Count
    $invalidCount = $parsed.Invalid.Count

    if ($validCount -eq 1) {
        $summary = '1 unique account ready'
    }
    else {
        $summary = $validCount.ToString('N0') + ' unique accounts ready'
    }

    if ($invalidCount -gt 0) {
        $summary += '  |  ' + $invalidCount.ToString('N0') + ' invalid entr' + $(if ($invalidCount -eq 1) { 'y' } else { 'ies' })
        $script:InputSummaryLabel.ForeColor = New-AppColor 239 183 94
    }
    elseif ($validCount -gt 0) {
        $script:InputSummaryLabel.ForeColor = New-AppColor 111 215 151
    }
    else {
        $script:InputSummaryLabel.ForeColor = $colorMuted
    }

    $script:InputSummaryLabel.Text = $summary
    Update-CommandPreview
}

function Update-CommandPreview {
    if (-not $script:CommandPreviewBox) {
        return
    }

    $parsed = Get-UserList -Quiet
    if ($parsed.Users.Count -eq 0) {
        $script:CommandPreviewBox.Text = 'Enter one username or paste an entire list to preview the commands.'
        return
    }

    $previewUsers = @($parsed.Users | Select-Object -First 6)
    $commands = @(
        foreach ($email in $previewUsers) {
            Build-CmdCommand -ActionKey $script:CurrentActionKey -EmailAddress $email -DestinationKey $script:CurrentDestinationKey
        }
    )

    if ($parsed.Users.Count -gt $previewUsers.Count) {
        $commands += ('... plus ' + ($parsed.Users.Count - $previewUsers.Count).ToString('N0') + ' more command(s)')
    }

    $script:CommandPreviewBox.Text = $commands -join ([Environment]::NewLine + [Environment]::NewLine)
}

function Show-Action {
    param([string]$ActionKey)

    if (-not $script:Actions.Contains($ActionKey)) {
        return
    }

    $script:CurrentActionKey = $ActionKey
    $action = $script:Actions[$ActionKey]
    $script:ActionTitleLabel.Text = $action.Title
    $script:ActionDescriptionLabel.Text = $action.Description
    $script:RunButton.Text = if ($ActionKey -eq 'check_status') { 'Run Status Check' } else { 'Run Selected Action' }
    $script:RunButton.BackColor = $action.ButtonColor

    $showDestination = ($ActionKey -eq 'move_class')
    $script:DestinationLabel.Visible = $showDestination
    $script:DestinationCombo.Visible = $showDestination
    if ($showDestination) {
        $destination = $script:OuDestinations[$script:CurrentDestinationKey]
        $script:ActionDescriptionLabel.Text = $action.Description + ' Destination: ' + $destination.Label + '.'
    }

    $selectorLeft = [Math]::Max(430, $script:ActionHeader.ClientSize.Width - 290)
    if ($showDestination) {
        $script:ActionTitleLabel.Width = [Math]::Max(360, $selectorLeft - 36)
        $script:ActionDescriptionLabel.Width = [Math]::Max(360, $selectorLeft - 38)
    }
    else {
        $script:ActionTitleLabel.Width = [Math]::Max(500, $script:ActionHeader.ClientSize.Width - 36)
        $script:ActionDescriptionLabel.Width = [Math]::Max(500, $script:ActionHeader.ClientSize.Width - 40)
    }

    foreach ($key in $script:ActionButtons.Keys) {
        $script:ActionButtons[$key].BackColor = if ($key -eq $ActionKey) {
            $colorAccentDark
        }
        else {
            $colorPanel
        }
    }

    Update-CommandPreview
    $script:StatusLabel.Text = $action.ShortTitle
}

function Show-InputProblem {
    param([psobject]$ParsedUsers)

    if ($ParsedUsers.Users.Count -eq 0) {
        $message = 'Enter at least one username or full email address.'
    }
    else {
        $shown = @($ParsedUsers.Invalid | Select-Object -First 12)
        $message = 'Fix or remove these invalid entries:' + [Environment]::NewLine + [Environment]::NewLine +
            ($shown -join [Environment]::NewLine)
        if ($ParsedUsers.Invalid.Count -gt $shown.Count) {
            $message += [Environment]::NewLine + '...and ' + ($ParsedUsers.Invalid.Count - $shown.Count) + ' more.'
        }
        $message += [Environment]::NewLine + [Environment]::NewLine +
            'Only usernames and @' + $script:Domain + ' addresses are accepted.'
    }

    [System.Windows.Forms.MessageBox]::Show(
        $script:MainForm,
        $message,
        'Check the account list',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null
}

function Add-ResultLine {
    param(
        [string]$Text,
        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Detail')]
        [string]$Level = 'Info'
    )

    if (-not $script:ResultsBox -or $script:ResultsBox.IsDisposed) {
        return
    }

    $lineColor = $colorText
    switch ($Level) {
        'Success' { $lineColor = New-AppColor 111 215 151 }
        'Warning' { $lineColor = New-AppColor 239 183 94 }
        'Error' { $lineColor = New-AppColor 247 121 121 }
        'Detail' { $lineColor = New-AppColor 181 192 211 }
    }

    $script:ResultsBox.SelectionStart = $script:ResultsBox.TextLength
    $script:ResultsBox.SelectionLength = 0
    $script:ResultsBox.SelectionColor = $lineColor
    $script:ResultsBox.AppendText($Text + [Environment]::NewLine)
    $script:ResultsBox.SelectionColor = $script:ResultsBox.ForeColor
    $script:ResultsBox.SelectionStart = $script:ResultsBox.TextLength
    $script:ResultsBox.ScrollToCaret()
}

function Copy-SelectedCommands {
    $parsed = Get-UserList
    if ($parsed.Users.Count -eq 0 -or $parsed.Invalid.Count -gt 0) {
        Show-InputProblem -ParsedUsers $parsed
        return
    }

    $commands = @(
        foreach ($email in $parsed.Users) {
            Build-CmdCommand -ActionKey $script:CurrentActionKey -EmailAddress $email -DestinationKey $script:CurrentDestinationKey
        }
    )
    [System.Windows.Forms.Clipboard]::SetText(($commands -join [Environment]::NewLine))
    $script:StatusLabel.Text = $commands.Count.ToString('N0') + ' command(s) copied'
    Add-ResultLine -Text ('Copied ' + $commands.Count.ToString('N0') + ' command(s) to the clipboard.') -Level 'Success'
}

function Test-AdToolsAvailable {
    $requiredTools = @('dsquery.exe', 'dsmod.exe', 'dsget.exe', 'dsmove.exe')
    return @(
        $requiredTools | Where-Object {
            -not (Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue)
        }
    )
}

function Set-ControlsBusy {
    param([bool]$IsBusy)

    $script:Busy = $IsBusy
    $script:UserInputBox.Enabled = -not $IsBusy
    $script:RunButton.Enabled = -not $IsBusy
    $script:CopyButton.Enabled = -not $IsBusy
    $script:ClearListButton.Enabled = -not $IsBusy
    foreach ($button in $script:ActionButtons.Values) {
        $button.Enabled = -not $IsBusy
    }

    if ($IsBusy) {
        $script:ProgressBar.Visible = $true
    }
}

function Confirm-SelectedAction {
    param(
        [psobject]$Action,
        [string[]]$Users
    )

    if (-not $Action.Destructive) {
        return $true
    }

    $preview = @($Users | Select-Object -First 8)
    $message = $Action.Title.ToUpperInvariant() + [Environment]::NewLine + [Environment]::NewLine +
        'This will affect ' + $Users.Count.ToString('N0') + ' account(s):' + [Environment]::NewLine +
        ($preview -join [Environment]::NewLine)

    if ($script:CurrentActionKey -eq 'move_class') {
        $message = $Action.Title.ToUpperInvariant() + [Environment]::NewLine +
            'Destination: ' + $script:OuDestinations[$script:CurrentDestinationKey].Label +
            [Environment]::NewLine + [Environment]::NewLine +
            'This will affect ' + $Users.Count.ToString('N0') + ' account(s):' + [Environment]::NewLine +
            ($preview -join [Environment]::NewLine)
    }

    if ($Users.Count -gt $preview.Count) {
        $message += [Environment]::NewLine + '...and ' + ($Users.Count - $preview.Count).ToString('N0') + ' more.'
    }

    $message += [Environment]::NewLine + [Environment]::NewLine + 'Continue?'
    $answer = [System.Windows.Forms.MessageBox]::Show(
        $script:MainForm,
        $message,
        'Confirm Active Directory action',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2
    )
    return ($answer -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Start-SelectedAction {
    if ($script:Busy) {
        return
    }

    $parsed = Get-UserList
    if ($parsed.Users.Count -eq 0 -or $parsed.Invalid.Count -gt 0) {
        Show-InputProblem -ParsedUsers $parsed
        return
    }

    if (-not (Test-IsConfiguredIdentity)) {
        $configuredAccount = Get-ConfiguredAdminAccount
        $currentIdentity = Get-CurrentWindowsIdentity
        $message = if (-not $configuredAccount) {
            'The AD administrator account is not set. Add AdminAccount to config.json.'
        }
        else {
            'This copy is running as:' + [Environment]::NewLine +
                $currentIdentity + [Environment]::NewLine + [Environment]::NewLine +
                'It must run as:' + [Environment]::NewLine +
                $configuredAccount + [Environment]::NewLine + [Environment]::NewLine +
                'Close this window and start the app with Start-ADAccountCenter.ps1.'
        }
        [System.Windows.Forms.MessageBox]::Show(
            $script:MainForm,
            $message,
            'Wrong Windows identity',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    $missingTools = @(Test-AdToolsAvailable)
    if ($missingTools.Count -gt 0) {
        [System.Windows.Forms.MessageBox]::Show(
            $script:MainForm,
            'This Windows session is missing: ' + ($missingTools -join ', ') +
                [Environment]::NewLine + [Environment]::NewLine +
                'Run the app on a computer with the Active Directory tools installed (RSAT: Active Directory Domain Services).',
            'Active Directory tools not found',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    $action = $script:Actions[$script:CurrentActionKey]
    $users = @($parsed.Users)
    if (-not (Confirm-SelectedAction -Action $action -Users $users)) {
        return
    }

    if (-not (Test-Path -LiteralPath $script:WorkerPath -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show(
            $script:MainForm,
            'ADAccountWorker.ps1 is missing. Keep it in the same folder as this app.',
            'App file missing',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return
    }

    $id = [Guid]::NewGuid().ToString('N')
    $script:CurrentJobPath = Join-Path $env:TEMP ('ad-account-center-' + $id + '.job.json')
    $script:CurrentOutputPath = Join-Path $env:TEMP ('ad-account-center-' + $id + '.results.jsonl')

    $job = [ordered]@{
        ActionKey = $script:CurrentActionKey
        DestinationKey = $script:CurrentDestinationKey
        Users = $users
        Domain = $script:Domain
    }
    $job | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:CurrentJobPath -Encoding UTF8
    [System.IO.File]::WriteAllText(
        $script:CurrentOutputPath,
        '',
        (New-Object System.Text.UTF8Encoding($false))
    )

    $script:DisplayedEventCount = 0
    $script:TotalUsers = $users.Count
    $script:CompletedUsers = 0
    $script:SuccessCount = 0
    $script:NotFoundCount = 0
    $script:ErrorCount = 0
    $script:ProgressBar.Minimum = 0
    $script:ProgressBar.Maximum = [Math]::Max(1, $users.Count)
    $script:ProgressBar.Value = 0

    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = 'powershell.exe'
        $startInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $script:WorkerPath +
            '" -JobPath "' + $script:CurrentJobPath +
            '" -OutputPath "' + $script:CurrentOutputPath + '"'
        $startInfo.WorkingDirectory = $PSScriptRoot
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        $null = $process.Start()
        $script:CurrentProcess = $process

        Set-ControlsBusy -IsBusy $true
        $script:StatusLabel.Text = 'Running ' + $action.ShortTitle + ' for ' + $users.Count.ToString('N0') + ' account(s)...'
        Add-ResultLine -Text '' -Level 'Info'
        Add-ResultLine -Text ('[' + (Get-Date).ToString('h:mm:ss tt') + '] ' + $action.Title + ' - ' + $users.Count.ToString('N0') + ' account(s)') -Level 'Info'
        $script:ProcessTimer.Start()
    }
    catch {
        Set-ControlsBusy -IsBusy $false
        Remove-Item -LiteralPath $script:CurrentJobPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:CurrentOutputPath -Force -ErrorAction SilentlyContinue
        $script:CurrentJobPath = $null
        $script:CurrentOutputPath = $null
        Add-ResultLine -Text ('Could not start the AD worker: ' + $_.Exception.Message) -Level 'Error'
    }
}

function Read-NewWorkerEvents {
    if (-not $script:CurrentOutputPath -or -not (Test-Path -LiteralPath $script:CurrentOutputPath)) {
        return
    }

    try {
        $lines = @([System.IO.File]::ReadAllLines($script:CurrentOutputPath, [System.Text.Encoding]::UTF8))
    }
    catch {
        return
    }
    if ($lines.Count -le $script:DisplayedEventCount) {
        return
    }

    for ($index = $script:DisplayedEventCount; $index -lt $lines.Count; $index++) {
        $line = [string]$lines[$index]
        if (-not $line.Trim()) {
            continue
        }

        try {
            $event = $line | ConvertFrom-Json
        }
        catch {
            continue
        }

        switch ([string]$event.type) {
            'result' {
                $script:CompletedUsers++
                $prefix = '[INFO]'
                $level = 'Info'
                switch ([string]$event.status) {
                    'success' {
                        $script:SuccessCount++
                        $prefix = '[SUCCESS]'
                        $level = 'Success'
                    }
                    'notfound' {
                        $script:NotFoundCount++
                        $prefix = '[NOT FOUND]'
                        $level = 'Warning'
                    }
                    'error' {
                        $script:ErrorCount++
                        $prefix = '[ERROR]'
                        $level = 'Error'
                    }
                }

                Add-ResultLine -Text ($prefix + ' ' + [string]$event.user + ' - ' + [string]$event.message) -Level $level
                if ([string]$event.details) {
                    foreach ($detailLine in @(([string]$event.details) -split '\r?\n')) {
                        if ($detailLine) {
                            Add-ResultLine -Text ('    ' + $detailLine) -Level 'Detail'
                        }
                    }
                }

                $script:ProgressBar.Value = [Math]::Min($script:ProgressBar.Maximum, $script:CompletedUsers)
                $script:ProgressLabel.Text = $script:CompletedUsers.ToString('N0') + ' / ' + $script:TotalUsers.ToString('N0')
            }

            'fatal' {
                $script:ErrorCount++
                Add-ResultLine -Text ('[STOPPED] ' + [string]$event.message) -Level 'Error'
                if ([string]$event.details) {
                    Add-ResultLine -Text ('    ' + [string]$event.details) -Level 'Detail'
                }
            }
        }
    }

    $script:DisplayedEventCount = $lines.Count
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'AD Account Center'
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.Size = New-Object System.Drawing.Size(1260, 850)
$form.MinimumSize = New-Object System.Drawing.Size(1080, 730)
$form.BackColor = $colorBackground
$form.ForeColor = $colorText
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.KeyPreview = $true
$iconPath = Join-Path $PSScriptRoot 'ADAccountCenter.ico'
if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
    try {
        $form.Icon = New-Object System.Drawing.Icon($iconPath)
    }
    catch {
        # The app remains functional if Windows cannot load the custom icon.
    }
}
$script:MainForm = $form

$statusStrip = New-Object System.Windows.Forms.StatusStrip
$statusStrip.BackColor = $colorPanelRaised
$statusStrip.ForeColor = $colorText
$statusStrip.SizingGrip = $false

$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = 'Ready'
$statusLabel.Spring = $true
$statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$statusStrip.Items.Add($statusLabel) | Out-Null
$script:StatusLabel = $statusLabel

$domainLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$domainLabel.Text = 'Domain: ' + $script:Domain
$domainLabel.ForeColor = $colorMuted
$statusStrip.Items.Add($domainLabel) | Out-Null

$header = New-Object System.Windows.Forms.Panel
$header.Dock = [System.Windows.Forms.DockStyle]::Top
$header.Height = 88
$header.BackColor = $colorPanel

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = 'AD Account Center'
$titleLabel.Location = New-Object System.Drawing.Point(24, 11)
$titleLabel.Size = New-Object System.Drawing.Size(560, 39)
$titleLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 22)
$titleLabel.ForeColor = $colorText
$header.Controls.Add($titleLabel)

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Text = 'One account or an entire pasted list. One secure admin sign-in.'
$subtitleLabel.Location = New-Object System.Drawing.Point(28, 53)
$subtitleLabel.Size = New-Object System.Drawing.Size(620, 22)
$subtitleLabel.ForeColor = $colorMuted
$header.Controls.Add($subtitleLabel)

$adminStatusLabel = New-Object System.Windows.Forms.Label
$adminStatusLabel.Location = New-Object System.Drawing.Point(760, 14)
$adminStatusLabel.Size = New-Object System.Drawing.Size(446, 24)
$adminStatusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$adminStatusLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$adminStatusLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$header.Controls.Add($adminStatusLabel)
$script:AdminStatusLabel = $adminStatusLabel

$toolsStatusLabel = New-Object System.Windows.Forms.Label
$toolsStatusLabel.Location = New-Object System.Drawing.Point(760, 48)
$toolsStatusLabel.Size = New-Object System.Drawing.Size(446, 22)
$toolsStatusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$toolsStatusLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$toolsStatusLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$header.Controls.Add($toolsStatusLabel)
$script:ToolsStatusLabel = $toolsStatusLabel

$header.Add_Resize({
    $statusLeft = [Math]::Max(650, $header.ClientSize.Width - 470)
    $script:AdminStatusLabel.Left = $statusLeft
    $script:ToolsStatusLabel.Left = $statusLeft
})

$body = New-Object System.Windows.Forms.Panel
$body.Dock = [System.Windows.Forms.DockStyle]::Fill
$body.BackColor = $colorBackground

$sidebar = New-Object System.Windows.Forms.Panel
$sidebar.Dock = [System.Windows.Forms.DockStyle]::Left
$sidebar.Width = 270
$sidebar.BackColor = $colorPanel

$navTitle = New-Object System.Windows.Forms.Label
$navTitle.Text = 'ACTIVE DIRECTORY ACTIONS'
$navTitle.Location = New-Object System.Drawing.Point(18, 18)
$navTitle.Size = New-Object System.Drawing.Size(230, 24)
$navTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$navTitle.ForeColor = $colorMuted
$sidebar.Controls.Add($navTitle)

$navTop = 52
foreach ($actionKey in $script:Actions.Keys) {
    $action = $script:Actions[$actionKey]
    $button = New-FlatButton -Text $action.ShortTitle -BackColor $colorPanel -ForeColor $colorText -Width 238 -Height 52
    $button.Location = New-Object System.Drawing.Point(16, $navTop)
    $button.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $button.Padding = New-Object System.Windows.Forms.Padding(15, 0, 0, 0)
    $button.Tag = $actionKey
    $button.Add_Click({
        param($sender, $eventArgs)
        Show-Action -ActionKey ([string]$sender.Tag)
    })
    $sidebar.Controls.Add($button)
    $script:ActionButtons[$actionKey] = $button
    $navTop += 60
}

$securityNote = New-Object System.Windows.Forms.Label
$securityNote.Text = 'PASSWORD SAFETY' + [Environment]::NewLine +
    'Windows handles the admin prompt. This app never receives or saves your password.'
$securityNote.Location = New-Object System.Drawing.Point(18, 432)
$securityNote.Size = New-Object System.Drawing.Size(232, 90)
$securityNote.ForeColor = $colorMuted
$securityNote.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
$sidebar.Controls.Add($securityNote)

$main = New-Object System.Windows.Forms.Panel
$main.Dock = [System.Windows.Forms.DockStyle]::Fill
$main.BackColor = $colorBackground
$main.Padding = New-Object System.Windows.Forms.Padding(18)

$actionHeader = New-Object System.Windows.Forms.Panel
$actionHeader.Dock = [System.Windows.Forms.DockStyle]::Top
$actionHeader.Height = 86
$actionHeader.BackColor = $colorPanelRaised
$actionHeader.Padding = New-Object System.Windows.Forms.Padding(18)
$script:ActionHeader = $actionHeader

$actionTitleLabel = New-Object System.Windows.Forms.Label
$actionTitleLabel.Location = New-Object System.Drawing.Point(18, 12)
$actionTitleLabel.Size = New-Object System.Drawing.Size(820, 30)
$actionTitleLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 16)
$actionTitleLabel.ForeColor = $colorText
$actionTitleLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$actionHeader.Controls.Add($actionTitleLabel)
$script:ActionTitleLabel = $actionTitleLabel

$actionDescriptionLabel = New-Object System.Windows.Forms.Label
$actionDescriptionLabel.Location = New-Object System.Drawing.Point(20, 46)
$actionDescriptionLabel.Size = New-Object System.Drawing.Size(850, 25)
$actionDescriptionLabel.ForeColor = $colorMuted
$actionDescriptionLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$actionHeader.Controls.Add($actionDescriptionLabel)
$script:ActionDescriptionLabel = $actionDescriptionLabel

$destinationLabel = New-Object System.Windows.Forms.Label
$destinationLabel.Text = 'DESTINATION OU'
$destinationLabel.Location = New-Object System.Drawing.Point(602, 10)
$destinationLabel.Size = New-Object System.Drawing.Size(270, 20)
$destinationLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 8.5)
$destinationLabel.ForeColor = $colorMuted
$destinationLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$destinationLabel.Visible = $false
$actionHeader.Controls.Add($destinationLabel)
$script:DestinationLabel = $destinationLabel

$destinationCombo = New-Object System.Windows.Forms.ComboBox
$destinationCombo.Location = New-Object System.Drawing.Point(602, 33)
$destinationCombo.Size = New-Object System.Drawing.Size(270, 30)
$destinationCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$destinationCombo.BackColor = $colorInput
$destinationCombo.ForeColor = $colorText
$destinationCombo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$destinationCombo.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$destinationCombo.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$destinationCombo.DisplayMember = 'Label'
$destinationCombo.Visible = $false
foreach ($destinationKey in $script:OuDestinations.Keys) {
    $null = $destinationCombo.Items.Add([pscustomobject]@{
        Key = $destinationKey
        Label = $script:OuDestinations[$destinationKey].Label
    })
}
$destinationCombo.SelectedIndex = 0
$actionHeader.Controls.Add($destinationCombo)
$script:DestinationCombo = $destinationCombo

$inputPanel = New-Object System.Windows.Forms.Panel
$inputPanel.Dock = [System.Windows.Forms.DockStyle]::Top
$inputPanel.Height = 230
$inputPanel.BackColor = $colorBackground

$inputLabel = New-Object System.Windows.Forms.Label
$inputLabel.Text = 'USERNAMES OR EMAIL ADDRESSES'
$inputLabel.Location = New-Object System.Drawing.Point(2, 14)
$inputLabel.Size = New-Object System.Drawing.Size(420, 22)
$inputLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$inputLabel.ForeColor = $colorMuted
$inputPanel.Controls.Add($inputLabel)

$inputHelp = New-Object System.Windows.Forms.Label
$inputHelp.Text = 'Enter one account, or paste as many as you want. Separate entries with new lines, spaces, commas, or semicolons.'
$inputHelp.Location = New-Object System.Drawing.Point(2, 38)
$inputHelp.Size = New-Object System.Drawing.Size(890, 23)
$inputHelp.ForeColor = $colorMuted
$inputHelp.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$inputPanel.Controls.Add($inputHelp)

$userInputBox = New-Object System.Windows.Forms.TextBox
$userInputBox.Location = New-Object System.Drawing.Point(2, 67)
$userInputBox.Size = New-Object System.Drawing.Size(870, 104)
$userInputBox.Multiline = $true
$userInputBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$userInputBox.AcceptsReturn = $true
$userInputBox.AcceptsTab = $false
$userInputBox.BackColor = $colorInput
$userInputBox.ForeColor = $colorText
$userInputBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$userInputBox.Font = New-Object System.Drawing.Font('Consolas', 11)
$userInputBox.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$inputPanel.Controls.Add($userInputBox)
$script:UserInputBox = $userInputBox

$inputSummaryLabel = New-Object System.Windows.Forms.Label
$inputSummaryLabel.Text = '0 unique accounts ready'
$inputSummaryLabel.Location = New-Object System.Drawing.Point(2, 180)
$inputSummaryLabel.Size = New-Object System.Drawing.Size(360, 24)
$inputSummaryLabel.ForeColor = $colorMuted
$inputSummaryLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$inputPanel.Controls.Add($inputSummaryLabel)
$script:InputSummaryLabel = $inputSummaryLabel

$clearListButton = New-FlatButton -Text 'Clear List' -BackColor $colorPanelRaised -ForeColor $colorText -Width 110 -Height 38
$clearListButton.Location = New-Object System.Drawing.Point(386, 174)
$clearListButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$clearListButton.Add_Click({
    $script:UserInputBox.Clear()
    $script:UserInputBox.Focus()
})
$inputPanel.Controls.Add($clearListButton)
$script:ClearListButton = $clearListButton

$copyButton = New-FlatButton -Text 'Copy Commands' -BackColor $colorAccentDark -ForeColor $colorText -Width 160 -Height 38
$copyButton.Location = New-Object System.Drawing.Point(510, 174)
$copyButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$copyButton.Add_Click({ Copy-SelectedCommands })
$inputPanel.Controls.Add($copyButton)
$script:CopyButton = $copyButton

$runButton = New-FlatButton -Text 'Run Selected Action' -BackColor $colorGreen -ForeColor $colorText -Width 192 -Height 38
$runButton.Location = New-Object System.Drawing.Point(680, 174)
$runButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$runButton.Add_Click({ Start-SelectedAction })
$inputPanel.Controls.Add($runButton)
$script:RunButton = $runButton

$previewPanel = New-Object System.Windows.Forms.Panel
$previewPanel.Dock = [System.Windows.Forms.DockStyle]::Top
$previewPanel.Height = 150
$previewPanel.BackColor = $colorPanel
$previewPanel.Padding = New-Object System.Windows.Forms.Padding(14)

$previewLabel = New-Object System.Windows.Forms.Label
$previewLabel.Text = 'COMMAND PREVIEW'
$previewLabel.Location = New-Object System.Drawing.Point(14, 9)
$previewLabel.Size = New-Object System.Drawing.Size(240, 20)
$previewLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 8.5)
$previewLabel.ForeColor = $colorMuted
$previewPanel.Controls.Add($previewLabel)

$commandPreviewBox = New-Object System.Windows.Forms.TextBox
$commandPreviewBox.Location = New-Object System.Drawing.Point(14, 32)
$commandPreviewBox.Size = New-Object System.Drawing.Size(844, 102)
$commandPreviewBox.Multiline = $true
$commandPreviewBox.ReadOnly = $true
$commandPreviewBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
$commandPreviewBox.WordWrap = $false
$commandPreviewBox.BackColor = $colorInput
$commandPreviewBox.ForeColor = New-AppColor 204 213 240
$commandPreviewBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$commandPreviewBox.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$commandPreviewBox.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$previewPanel.Controls.Add($commandPreviewBox)
$script:CommandPreviewBox = $commandPreviewBox

$resultsPanel = New-Object System.Windows.Forms.Panel
$resultsPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$resultsPanel.BackColor = $colorBackground

$resultsLabel = New-Object System.Windows.Forms.Label
$resultsLabel.Text = 'RESULTS AND ACTIVITY'
$resultsLabel.Location = New-Object System.Drawing.Point(2, 12)
$resultsLabel.Size = New-Object System.Drawing.Size(270, 20)
$resultsLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 8.5)
$resultsLabel.ForeColor = $colorMuted
$resultsPanel.Controls.Add($resultsLabel)

$progressLabel = New-Object System.Windows.Forms.Label
$progressLabel.Text = '0 / 0'
$progressLabel.Location = New-Object System.Drawing.Point(470, 10)
$progressLabel.Size = New-Object System.Drawing.Size(82, 22)
$progressLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$progressLabel.ForeColor = $colorMuted
$progressLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$resultsPanel.Controls.Add($progressLabel)
$script:ProgressLabel = $progressLabel

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(566, 13)
$progressBar.Size = New-Object System.Drawing.Size(206, 16)
$progressBar.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$progressBar.Visible = $false
$resultsPanel.Controls.Add($progressBar)
$script:ProgressBar = $progressBar

$clearResultsButton = New-FlatButton -Text 'Clear' -BackColor $colorPanelRaised -ForeColor $colorText -Width 78 -Height 28
$clearResultsButton.Location = New-Object System.Drawing.Point(786, 6)
$clearResultsButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$clearResultsButton.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 8.5)
$clearResultsButton.Add_Click({ $script:ResultsBox.Clear() })
$resultsPanel.Controls.Add($clearResultsButton)

$resultsBox = New-Object System.Windows.Forms.RichTextBox
$resultsBox.Location = New-Object System.Drawing.Point(2, 39)
$resultsBox.Size = New-Object System.Drawing.Size(870, 155)
$resultsBox.BackColor = $colorOutput
$resultsBox.ForeColor = $colorText
$resultsBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$resultsBox.ReadOnly = $true
$resultsBox.DetectUrls = $false
$resultsBox.WordWrap = $false
$resultsBox.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Both
$resultsBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$resultsBox.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$resultsPanel.Controls.Add($resultsBox)
$script:ResultsBox = $resultsBox

$main.Controls.Add($resultsPanel)
$main.Controls.Add($previewPanel)
$main.Controls.Add($inputPanel)
$main.Controls.Add($actionHeader)
$body.Controls.Add($main)
$body.Controls.Add($sidebar)
$form.Controls.Add($body)
$form.Controls.Add($header)
$form.Controls.Add($statusStrip)

$inputPanel.Add_Resize({
    $right = $inputPanel.ClientSize.Width - 2
    $script:UserInputBox.Width = [Math]::Max(450, $right)
    $script:ClearListButton.Left = $inputPanel.ClientSize.Width - 486
    $script:CopyButton.Left = $inputPanel.ClientSize.Width - 362
    $script:RunButton.Left = $inputPanel.ClientSize.Width - 192
})

$resultsPanel.Add_Resize({
    $script:ResultsBox.Width = [Math]::Max(450, $resultsPanel.ClientSize.Width - 4)
    $script:ResultsBox.Height = [Math]::Max(100, $resultsPanel.ClientSize.Height - 43)
    $clearResultsButton.Left = $resultsPanel.ClientSize.Width - $clearResultsButton.Width - 2
    $script:ProgressBar.Left = $clearResultsButton.Left - $script:ProgressBar.Width - 14
    $script:ProgressLabel.Left = $script:ProgressBar.Left - $script:ProgressLabel.Width - 10
})

$userInputBox.Add_TextChanged({ Update-InputSummary })

$destinationCombo.Add_SelectedIndexChanged({
    if ($script:DestinationCombo.SelectedItem) {
        $script:CurrentDestinationKey = [string]$script:DestinationCombo.SelectedItem.Key
        if ($script:CurrentActionKey -eq 'move_class') {
            $action = $script:Actions[$script:CurrentActionKey]
            $destination = $script:OuDestinations[$script:CurrentDestinationKey]
            $script:ActionDescriptionLabel.Text = $action.Description + ' Destination: ' + $destination.Label + '.'
        }
        Update-CommandPreview
    }
})

$actionHeader.Add_Resize({
    $selectorLeft = [Math]::Max(430, $actionHeader.ClientSize.Width - 290)
    $script:DestinationLabel.Left = $selectorLeft
    $script:DestinationCombo.Left = $selectorLeft
    if ($script:DestinationCombo.Visible) {
        $script:ActionTitleLabel.Width = [Math]::Max(360, $selectorLeft - 36)
        $script:ActionDescriptionLabel.Width = [Math]::Max(360, $selectorLeft - 38)
    }
    else {
        $script:ActionTitleLabel.Width = [Math]::Max(500, $actionHeader.ClientSize.Width - 36)
        $script:ActionDescriptionLabel.Width = [Math]::Max(500, $actionHeader.ClientSize.Width - 40)
    }
})

$processTimer = New-Object System.Windows.Forms.Timer
$processTimer.Interval = 400
$processTimer.Add_Tick({
    Read-NewWorkerEvents

    if (-not $script:CurrentProcess) {
        $script:ProcessTimer.Stop()
        return
    }

    if (-not $script:CurrentProcess.HasExited) {
        return
    }

    Read-NewWorkerEvents
    $exitCode = $script:CurrentProcess.ExitCode
    $script:CurrentProcess.Dispose()
    $script:CurrentProcess = $null
    $script:ProcessTimer.Stop()
    Set-ControlsBusy -IsBusy $false

    if ($script:CompletedUsers -lt $script:TotalUsers -and $exitCode -ne 0) {
        Add-ResultLine -Text ('The worker stopped before all accounts finished. Exit code: ' + $exitCode) -Level 'Error'
    }

    Add-ResultLine -Text (
        'Finished - ' + $script:SuccessCount.ToString('N0') + ' successful, ' +
        $script:NotFoundCount.ToString('N0') + ' not found, ' +
        $script:ErrorCount.ToString('N0') + ' error(s).'
    ) -Level $(if ($script:ErrorCount -gt 0) { 'Warning' } else { 'Success' })

    $script:StatusLabel.Text = 'Finished: ' + $script:SuccessCount.ToString('N0') + ' successful, ' +
        $script:NotFoundCount.ToString('N0') + ' not found, ' + $script:ErrorCount.ToString('N0') + ' error(s)'

    Remove-Item -LiteralPath $script:CurrentJobPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:CurrentOutputPath -Force -ErrorAction SilentlyContinue
    $script:CurrentJobPath = $null
    $script:CurrentOutputPath = $null
})
$script:ProcessTimer = $processTimer

$form.Add_Shown({
    $identityName = Get-CurrentWindowsIdentity
    $configuredAccount = Get-ConfiguredAdminAccount
    $identityReady = Test-IsConfiguredIdentity
    if ($identityReady) {
        $script:AdminStatusLabel.Text = 'AD IDENTITY: READY  |  ' + $identityName
        $script:AdminStatusLabel.ForeColor = New-AppColor 111 215 151
    }
    elseif (-not $configuredAccount) {
        $script:AdminStatusLabel.Text = 'AD IDENTITY: NOT CONFIGURED'
        $script:AdminStatusLabel.ForeColor = New-AppColor 247 121 121
    }
    else {
        $script:AdminStatusLabel.Text = 'WRONG IDENTITY: ' + $identityName
        $script:AdminStatusLabel.ForeColor = New-AppColor 247 121 121
    }

    $missingTools = @(Test-AdToolsAvailable)
    if ($missingTools.Count -eq 0) {
        $script:ToolsStatusLabel.Text = 'AD command tools: Ready'
        $script:ToolsStatusLabel.ForeColor = New-AppColor 111 215 151
    }
    else {
        $script:ToolsStatusLabel.Text = 'AD tools missing: ' + ($missingTools -join ', ')
        $script:ToolsStatusLabel.ForeColor = New-AppColor 239 183 94
    }

    $startingAction = 'check_status'
    if ($script:AppSettings -and $script:AppSettings.LastAction -and $script:Actions.Contains([string]$script:AppSettings.LastAction)) {
        $startingAction = [string]$script:AppSettings.LastAction
    }
    Show-Action -ActionKey $startingAction
    Add-ResultLine -Text 'AD Account Center started. Paste one account or an entire list.' -Level 'Info'

    if (-not $identityReady) {
        if ($configuredAccount) {
            Add-ResultLine -Text ('This copy is running as ' + $identityName + ', but it is configured for ' + $configuredAccount + '. Close it and start the app with Start-ADAccountCenter.ps1.') -Level 'Warning'
        }
        else {
            Add-ResultLine -Text 'The AD administrator account is not set. Add AdminAccount to config.json.' -Level 'Warning'
        }
    }
    if ($missingTools.Count -gt 0) {
        Add-ResultLine -Text 'The legacy AD command tools were not found in this Windows session.' -Level 'Warning'
    }
})

$form.Add_FormClosing({
    param($sender, $eventArgs)

    if ($script:Busy) {
        [System.Windows.Forms.MessageBox]::Show(
            $script:MainForm,
            'An Active Directory job is still running. Please wait for it to finish before closing the app.',
            'Job in progress',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        $eventArgs.Cancel = $true
        return
    }

    Save-AppSettings
})

$script:AppSettings = Get-AppSettings
if ($script:AppSettings -and
    $script:AppSettings.LastDestination -and
    $script:OuDestinations.Contains([string]$script:AppSettings.LastDestination)) {

    for ($destinationIndex = 0; $destinationIndex -lt $script:DestinationCombo.Items.Count; $destinationIndex++) {
        if ([string]$script:DestinationCombo.Items[$destinationIndex].Key -eq [string]$script:AppSettings.LastDestination) {
            $script:DestinationCombo.SelectedIndex = $destinationIndex
            break
        }
    }
}
if ($script:AppSettings -and
    $script:AppSettings.X -ne $null -and
    $script:AppSettings.Y -ne $null -and
    $script:AppSettings.Width -ne $null -and
    $script:AppSettings.Height -ne $null) {

    try {
        $savedBounds = New-Object System.Drawing.Rectangle(
            [int]$script:AppSettings.X,
            [int]$script:AppSettings.Y,
            [int]$script:AppSettings.Width,
            [int]$script:AppSettings.Height
        )
        $visibleOnScreen = @(
            [System.Windows.Forms.Screen]::AllScreens |
                Where-Object { $_.WorkingArea.IntersectsWith($savedBounds) }
        ).Count -gt 0

        if ($visibleOnScreen) {
            $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
            $form.Bounds = $savedBounds
        }
    }
    catch {
        # Use the centered default if the saved monitor layout changed.
    }
}

[System.Windows.Forms.Application]::Run($form)