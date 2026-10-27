[CmdletBinding(SupportsShouldProcess)]
param(
  # Internal: set when the script relaunches itself as Administrator.
  [switch]$Elevated,
  # Internal: the account that started the script, so the elevated copy can
  # refuse to link into a different user's profile.
  [string]$OriginalUser,
  # Internal: the elevated copy runs in a hidden window and writes its output
  # here; the original window reads it and prints it.
  [string]$LogFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

$script:LogColors = @{
  INFO    = "Cyan"
  SUCCESS = "Green"
  WARN    = "Yellow"
  ERROR   = "Red"
}
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Show-LogLine {
  param([string]$Level, [string]$Message)
  $color = $script:LogColors[$Level]
  if (-not $color) { $color = "Gray" }
  Write-Host "[$Level] $Message" -ForegroundColor $color
}

function Write-Log {
  param([string]$Level, [string]$Message)
  if (-not $LogFile) {
    Show-LogLine $Level $Message
    return
  }
  # Hidden elevated copy: append to the log file (retry if the reader has it open)
  $line = "$Level`t$($Message -replace '[\r\n]+', ' ')`n"
  for ($i = 0; $i -lt 20; $i++) {
    try {
      [System.IO.File]::AppendAllText($LogFile, $line, $script:Utf8NoBom)
      return
    }
    catch [System.IO.IOException] {
      Start-Sleep -Milliseconds 50
    }
  }
}

function Write-Info {
  param([string]$Message)
  Write-Log "INFO" $Message
}

function Write-Success {
  param([string]$Message)
  Write-Log "SUCCESS" $Message
}

function Write-WarningMessage {
  param([string]$Message)
  Write-Log "WARN" $Message
}

function Write-ErrorMessage {
  param([string]$Message)
  Write-Log "ERROR" $Message
}

# Print complete lines of the log file past the first $Printed ones.
# Returns the new count of printed lines.
function Show-NewLogLines {
  param([string]$Path, [int]$Printed)
  try {
    $stream = [System.IO.File]::Open($Path, "Open", "Read", "ReadWrite")
    try {
      $reader = New-Object System.IO.StreamReader($stream, $script:Utf8NoBom)
      $content = $reader.ReadToEnd()
    }
    finally {
      $stream.Dispose()
    }
  }
  catch [System.IO.IOException] {
    return $Printed
  }

  # Only lines terminated by "`n" are complete; the last element is a partial line
  $lines = $content -split "`n"
  for ($i = $Printed; $i -lt $lines.Count - 1; $i++) {
    $level, $message = $lines[$i] -split "`t", 2
    Show-LogLine $level $message
  }
  return [Math]::Max($Printed, $lines.Count - 1)
}

function Write-Skip {
  param([string]$Name)
  Write-Info "Skipping $Name (not installed)"
}

# ---------------------------------------------------------------------------
# Detection helpers
# ---------------------------------------------------------------------------

function Test-Command {
  param([Parameter(Mandatory)][string[]]$Name)
  foreach ($n in $Name) {
    if (Get-Command $n -ErrorAction SilentlyContinue) { return $true }
  }
  return $false
}

function Test-AnyPath {
  param([Parameter(Mandatory)][string[]]$Path)
  foreach ($p in $Path) {
    if ($p -and (Test-Path -LiteralPath $p)) { return $true }
  }
  return $false
}

function Get-CurrentUserName {
  return [Security.Principal.WindowsIdentity]::GetCurrent().Name
}

function Test-IsAdmin {
  $principal = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------------------
# Symbolic links
# ---------------------------------------------------------------------------

# Windows PowerShell 5.1's New-Item does not use the unprivileged-create flag
# that Developer Mode allows, but mklink does. PowerShell 7+ handles it itself.
function New-SymbolicLinkRaw {
  param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Target
  )
  if ($PSVersionTable.PSVersion.Major -ge 6) {
    New-Item -ItemType SymbolicLink -Path $Target -Value $Source -WhatIf:$false | Out-Null
  }
  else {
    $dirFlag = if (Test-Path -LiteralPath $Source -PathType Container) { "/D " } else { "" }
    $ErrorActionPreference = "Continue"
    $output = cmd /c "mklink $dirFlag`"$Target`" `"$Source`"" 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw "mklink failed: $output"
    }
  }
}

# Try creating a throwaway link in %TEMP% to find out whether this process
# can create symbolic links at all, before touching any real config.
function Test-CanCreateSymlink {
  $probeDir = Join-Path ([System.IO.Path]::GetTempPath()) ("dotfiles-probe-" + [guid]::NewGuid())
  try {
    New-Item -ItemType Directory -Path $probeDir -WhatIf:$false | Out-Null
    $probeSource = Join-Path $probeDir "source"
    $probeTarget = Join-Path $probeDir "target"
    Set-Content -LiteralPath $probeSource -Value "" -WhatIf:$false
    New-SymbolicLinkRaw -Source $probeSource -Target $probeTarget
    return $true
  }
  catch {
    return $false
  }
  finally {
    Remove-Item -LiteralPath $probeDir -Recurse -Force -WhatIf:$false -ErrorAction SilentlyContinue
  }
}

# Relaunch this script as Administrator and wait for it.
# Returns the child's exit code, or $null when elevation is unavailable or the
# UAC prompt was declined.
function Invoke-SelfElevation {
  if (-not $PSCommandPath) {
    Write-WarningMessage "Script is not running from a file; cannot relaunch as Administrator."
    return $null
  }

  $exe = (Get-Process -Id $PID).Path
  $logPath = Join-Path ([System.IO.Path]::GetTempPath()) ("dotfiles-install-" + [guid]::NewGuid() + ".log")
  [System.IO.File]::WriteAllText($logPath, "", $script:Utf8NoBom)

  $argList = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", "`"$PSCommandPath`"",
    "-Elevated",
    "-OriginalUser", "`"$(Get-CurrentUserName)`"",
    "-LogFile", "`"$logPath`""
  )

  Write-Info "Requesting Administrator privileges (UAC prompt)..."
  try {
    # Note: Start-Process has no -WhatIf in Windows PowerShell 5.1. This
    # function is never reached under -WhatIf anyway.
    $process = Start-Process -FilePath $exe -ArgumentList $argList -Verb RunAs -WindowStyle Hidden -PassThru
    # Touch the handle now so ExitCode is still readable after the process ends (PS 5.1 quirk)
    $null = $process.Handle

    Write-Info "Running elevated; output follows."
    $printed = 0
    while ($true) {
      $exited = $process.HasExited   # check first so the final lines are read after exit
      $printed = Show-NewLogLines -Path $logPath -Printed $printed
      if ($exited) { break }
      Start-Sleep -Milliseconds 200
    }
    $process.WaitForExit()

    $childExit = $process.ExitCode
    if ($null -eq $childExit) { $childExit = 1 }
    if ($printed -eq 0) {
      Write-ErrorMessage "Elevated process exited with code $childExit without any output."
    }
    return $childExit
  }
  catch {
    # ERROR_CANCELLED (1223): the user clicked "No" on the UAC prompt
    $inner = $_.Exception
    while ($inner.InnerException) { $inner = $inner.InnerException }
    if ($inner -is [System.ComponentModel.Win32Exception] -and $inner.NativeErrorCode -eq 1223) {
      Write-WarningMessage "UAC prompt was declined."
    }
    else {
      Write-ErrorMessage "Failed to relaunch as Administrator: $($_.Exception.Message)"
    }
    return $null
  }
  finally {
    Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
  }
}

function New-SymbolicLinkSafe {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)]
    [string]$Source,

    [Parameter(Mandatory)]
    [string]$Target
  )
  $targetParent = Split-Path -Parent $Target
  $targetName = Split-Path -Leaf $Target

  if (-not (Test-Path -LiteralPath $Source)) {
    Write-ErrorMessage "Source does not exist, skipping: $Source"
    return
  }

  if (-not (Test-Path -LiteralPath $targetParent)) {
    if ($PSCmdlet.ShouldProcess($targetParent, "Create directory")) {
      Write-Info "Creating parent directory: $targetParent"
      New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
    }
  }

  # Existing target (PS 5.1-compatible check for broken symlinks)
  $existingItem = $null
  if (Test-Path -LiteralPath $targetParent) {
    $existingItem = Get-ChildItem -LiteralPath $targetParent -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq $targetName }
  }

  if ($existingItem) {
    $isSymbolicLink = $existingItem.Attributes -match "ReparsePoint" -or $existingItem.LinkType
    if ($isSymbolicLink) {
      # PS 5.1 returns Target as an array; relative targets are relative to the link's folder
      $currentTarget = @($existingItem.Target) | Select-Object -First 1
      if ($currentTarget) {
        if (-not [System.IO.Path]::IsPathRooted($currentTarget)) {
          $currentTarget = Join-Path $targetParent $currentTarget
        }
        $normalizedCurrentTarget = [System.IO.Path]::GetFullPath($currentTarget)
        $normalizedSource = [System.IO.Path]::GetFullPath($Source)

        if ($normalizedCurrentTarget -eq $normalizedSource) {
          Write-Info "Already linked: $Target"
          return
        }
      }

      if ($PSCmdlet.ShouldProcess($Target, "Remove existing symbolic link (-> $currentTarget)")) {
        Write-WarningMessage "Removing existing symbolic link: $Target (-> $currentTarget)"
        Remove-Item -LiteralPath $Target -Force
      }
    }
    else {
      $timestamp = Get-Date -Format "yyyyMMdd_HHmmssfff"
      $backupPath = "$Target.backup.$timestamp"
      if ($PSCmdlet.ShouldProcess($Target, "Back up to $backupPath")) {
        Write-WarningMessage "Backing up existing item: $Target -> $backupPath"
        Move-Item -LiteralPath $Target -Destination $backupPath -Force
      }
    }
  }

  if ($PSCmdlet.ShouldProcess($Target, "Create symbolic link to $Source")) {
    Write-Success "Linking: $Target -> $Source"
    New-SymbolicLinkRaw -Source $Source -Target $Target
  }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Decide up front whether this process may create symbolic links, so nothing
# gets backed up or removed unless the link that replaces it can be created.
# Returns $true to continue in this process, $false to stop. May exit the
# script when an elevated copy has done the work.
function Initialize-Privilege {
  if ($WhatIfPreference) {
    Write-Info "-WhatIf: skipping privilege checks (nothing will be changed)."
    return $true
  }

  if ($Elevated) {
    # Guard: an over-the-shoulder elevation with a different admin account would
    # make $env:APPDATA point at that account's profile.
    $currentUser = Get-CurrentUserName
    if ($OriginalUser -and $OriginalUser -ne $currentUser) {
      Write-ErrorMessage "Elevated as '$currentUser', but the script was started by '$OriginalUser'."
      Write-ErrorMessage "Links would go into the wrong profile. Enable Developer Mode and run without elevation instead."
      return $false
    }
  }
  elseif (-not (Test-IsAdmin)) {
    $exitCode = Invoke-SelfElevation
    if ($null -ne $exitCode) {
      exit $exitCode
    }
    Write-WarningMessage "Continuing as the current user."
  }

  if (Test-CanCreateSymlink) {
    return $true
  }

  Write-ErrorMessage "This process cannot create symbolic links. No files were changed."
  Write-ErrorMessage "Either approve the UAC prompt, or enable Developer Mode (Settings > System > For developers)."
  return $false
}

function Invoke-DotfilesSetup {
  $dotfilesRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

  $apps = @(
    @{
      Name      = "PowerShell (built-in)"
      Installed = { (Test-Command powershell) }
      Links     = [ordered]@{
        "$dotfilesRoot\WindowsPowerShell" = "$env:USERPROFILE\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1"
      }
    }
    @{
      Name      = "VSCode"
      Installed = {
        (Test-Command code) -or (Test-AnyPath @(
            "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe",
            "$env:ProgramFiles\Microsoft VS Code\Code.exe"
          ))
      }
      Links     = [ordered]@{
        "$dotfilesRoot\vscode\keybindings.json" = "$env:APPDATA\Code\User\keybindings.json"
        "$dotfilesRoot\vscode\settings.json"    = "$env:APPDATA\Code\User\settings.json"
      }
    },
    @{
      Name      = "Windows Terminal"
      Installed = { (Test-Command wt) -or (Test-AnyPath "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe") }
      Links     = [ordered]@{
        "$dotfilesRoot\wt\settings.json" = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
      }
    }
  )

  $failed = 0
  foreach ($app in $apps) {
    if (-not (& $app.Installed)) {
      Write-Skip $app.Name
      continue
    }
    foreach ($link in $app.Links.GetEnumerator()) {
      try {
        New-SymbolicLinkSafe -Source $link.Key -Target $link.Value
      }
      catch {
        # Keep going with the other links; report at the end.
        $failed++
        Write-ErrorMessage "Failed to link $($link.Value): $($_.Exception.Message)"
      }
    }
  }
  return $failed
}

$exitCode = 0
try {
  if (Initialize-Privilege) {
    $failed = Invoke-DotfilesSetup
    if ($failed -gt 0) {
      Write-ErrorMessage "$failed link(s) failed."
      $exitCode = 1
    }
    else {
      Write-Success "Done."
    }
  }
  else {
    $exitCode = 1
  }
}
catch {
  Write-ErrorMessage $_.Exception.Message
  $exitCode = 1
}
exit $exitCode
