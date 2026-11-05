#requires -version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$JobPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

function Write-WorkerEvent {
    param(
        [string]$Type,
        [string]$User,
        [string]$Status,
        [string]$Message,
        [string]$Details = ''
    )

    $event = [ordered]@{
        type = $Type
        user = $User
        status = $Status
        message = $Message
        details = $Details
        timestamp = (Get-Date).ToString('o')
    }
    $line = $event | ConvertTo-Json -Compress
    [System.IO.File]::AppendAllText(
        $OutputPath,
        $line + [Environment]::NewLine,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Invoke-AdCommand {
    param(
        [string]$Executable,
        [string[]]$Arguments
    )

    $commandOutput = @(& $Executable @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{
        ExitCode = $exitCode
        Lines = @($commandOutput | ForEach-Object { [string]$_ })
        Text = (($commandOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
    }
}

function Resolve-UserDistinguishedName {
    param([string]$EmailAddress)

    $query = Invoke-AdCommand -Executable 'dsquery.exe' -Arguments @(
        '*',
        'domainroot',
        '-filter',
        ('(mail=' + $EmailAddress + ')'),
        '-limit',
        '1'
    )

    if ($query.ExitCode -ne 0) {
        throw ('Directory lookup failed. ' + $query.Text)
    }

    $distinguishedName = @(
        $query.Lines |
            ForEach-Object { ([string]$_).Trim().Trim('"') } |
            Where-Object { $_ -match '^(?i)(CN|OU|DC)=' }
    ) | Select-Object -First 1

    if (-not $distinguishedName) {
        return $null
    }

    return [string]$distinguishedName
}

function Get-UsefulOutput {
    param([string[]]$Lines)

    return (@(
        $Lines |
            ForEach-Object { ([string]$_).Trim() } |
            Where-Object {
                $_ -and
                $_ -notmatch '^(?i)(dsget|dsmod|dsmove) succeeded'
            }
    ) -join [Environment]::NewLine).Trim()
}

try {
    $job = Get-Content -LiteralPath $JobPath -Raw | ConvertFrom-Json
    $requiredTools = @('dsquery.exe', 'dsmod.exe', 'dsget.exe', 'dsmove.exe')
    $missingTools = @(
        $requiredTools | Where-Object {
            -not (Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue)
        }
    )

    if ($missingTools.Count -gt 0) {
        Write-WorkerEvent -Type 'fatal' -User '' -Status 'error' -Message (
            'Active Directory command-line tools are missing: ' + ($missingTools -join ', ')
        ) -Details 'Run the app on a computer with the Active Directory tools installed (RSAT: Active Directory Domain Services).'
        exit 2
    }

    # OUs come from the same config.json the app uses, and destination keys
    # are re-checked here so the worker never moves accounts to an unknown OU.
    $config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json
    $studentDisabledOu = [string]$config.StudentDisabledOu
    $staffDisabledOu = [string]$config.StaffDisabledOu
    $moveDestinations = @{}
    foreach ($destination in @($config.MoveDestinations)) {
        $moveDestinations[[string]$destination.Key] = $destination
    }

    foreach ($emailAddress in @($job.Users)) {
        $email = [string]$emailAddress

        try {
            $distinguishedName = Resolve-UserDistinguishedName -EmailAddress $email
            if (-not $distinguishedName) {
                Write-WorkerEvent -Type 'result' -User $email -Status 'notfound' -Message 'Account not found by email address.'
                continue
            }

            switch ([string]$job.ActionKey) {
                'disable' {
                    $result = Invoke-AdCommand -Executable 'dsmod.exe' -Arguments @(
                        'user', $distinguishedName, '-disabled', 'yes'
                    )
                    if ($result.ExitCode -ne 0) {
                        throw $result.Text
                    }
                    Write-WorkerEvent -Type 'result' -User $email -Status 'success' -Message 'Account disabled.' -Details $distinguishedName
                }

                'move_student' {
                    $result = Invoke-AdCommand -Executable 'dsmove.exe' -Arguments @(
                        $distinguishedName, '-newparent', $studentDisabledOu
                    )
                    if ($result.ExitCode -ne 0) {
                        throw $result.Text
                    }
                    Write-WorkerEvent -Type 'result' -User $email -Status 'success' -Message 'Moved to Student Disabled Accounts.' -Details $distinguishedName
                }

                'check_status' {
                    $result = Invoke-AdCommand -Executable 'dsget.exe' -Arguments @(
                        'user', $distinguishedName, '-dn', '-disabled'
                    )
                    if ($result.ExitCode -ne 0) {
                        throw $result.Text
                    }
                    $details = Get-UsefulOutput -Lines $result.Lines
                    if (-not $details) {
                        $details = $distinguishedName
                    }
                    Write-WorkerEvent -Type 'result' -User $email -Status 'success' -Message 'Account status retrieved.' -Details $details
                }

                'move_class' {
                    $destinationKey = [string]$job.DestinationKey
                    if (-not $moveDestinations.ContainsKey($destinationKey)) {
                        throw 'The selected destination OU is not in config.json.'
                    }
                    $destination = $moveDestinations[$destinationKey]
                    $result = Invoke-AdCommand -Executable 'dsmove.exe' -Arguments @(
                        $distinguishedName, '-newparent', [string]$destination.DistinguishedName
                    )
                    if ($result.ExitCode -ne 0) {
                        throw $result.Text
                    }
                    Write-WorkerEvent -Type 'result' -User $email -Status 'success' -Message (
                        'Moved to OU: ' + [string]$destination.Label + '.'
                    ) -Details $distinguishedName
                }

                'move_staff' {
                    $result = Invoke-AdCommand -Executable 'dsmove.exe' -Arguments @(
                        $distinguishedName, '-newparent', $staffDisabledOu
                    )
                    if ($result.ExitCode -ne 0) {
                        throw $result.Text
                    }
                    Write-WorkerEvent -Type 'result' -User $email -Status 'success' -Message 'Moved to Staff Disabled Accounts.' -Details $distinguishedName
                }

                'remove_groups' {
                    $membership = Invoke-AdCommand -Executable 'dsget.exe' -Arguments @(
                        'user', $distinguishedName, '-memberof'
                    )
                    if ($membership.ExitCode -ne 0) {
                        throw $membership.Text
                    }

                    $groups = @(
                        $membership.Lines |
                            ForEach-Object { ([string]$_).Trim().Trim('"') } |
                            Where-Object { $_ -match '^(?i)(CN|OU|DC)=' }
                    )

                    $removed = 0
                    $failedGroups = New-Object System.Collections.ArrayList
                    foreach ($groupDn in $groups) {
                        $removeResult = Invoke-AdCommand -Executable 'dsmod.exe' -Arguments @(
                            'group', [string]$groupDn, '-rmmbr', $distinguishedName
                        )
                        if ($removeResult.ExitCode -eq 0) {
                            $removed++
                        }
                        else {
                            $null = $failedGroups.Add(([string]$groupDn + ': ' + $removeResult.Text))
                        }
                    }

                    if ($failedGroups.Count -gt 0) {
                        throw (
                            'Removed ' + $removed + ' group(s), but ' + $failedGroups.Count +
                            ' group removal(s) failed.' + [Environment]::NewLine +
                            ($failedGroups -join [Environment]::NewLine)
                        )
                    }

                    Write-WorkerEvent -Type 'result' -User $email -Status 'success' -Message (
                        'Removed from ' + $removed + ' group(s). Domain Users remains as the primary group.'
                    ) -Details $distinguishedName
                }

                default {
                    throw ('Unknown action: ' + [string]$job.ActionKey)
                }
            }
        }
        catch {
            $errorMessage = $_.Exception.Message
            if (-not $errorMessage) {
                $errorMessage = 'An unknown Active Directory error occurred.'
            }
            Write-WorkerEvent -Type 'result' -User $email -Status 'error' -Message $errorMessage
        }
    }

    Write-WorkerEvent -Type 'complete' -User '' -Status 'complete' -Message 'Bulk operation finished.'
    exit 0
}
catch {
    Write-WorkerEvent -Type 'fatal' -User '' -Status 'error' -Message $_.Exception.Message
    exit 1
}
finally {
    Remove-Item -LiteralPath $JobPath -Force -ErrorAction SilentlyContinue
}