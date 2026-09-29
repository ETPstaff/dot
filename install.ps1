[CmdletBinding(SupportsShouldProcess)]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info {
  param([string]$Message)
  Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Success {
  param([string]$Message)
  Write-Host "[SUCCESS] $Message" -ForegroundColor Green
}

function Write-WarningMessage {
  param([string]$Message)
  Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-ErrorMessage {
  param([string]$Message)
  Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function New-SymbolicLinkSafe {
  param(
    [Parameter(Mandatory)]
    [string]$Source,

    [Parameter(Mandatory)]
    [string]$Target
  )
  $targetParent = Split-Path -Parent $Target
  $targetName = Split-Path -Leaf $Target
  if (-not (Test-Path -LiteralPath $targetParent)) {
    Write-Info "Creating parent directory: $targetParent"

    New-Item `
      -ItemType Directory `
      -Path $targetParent `
      -Force | Out-Null
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
      $currentTarget = $null
      if ($existingItem.Target) {
        $currentTarget = $existingItem.Target
      }

      if ($currentTarget) {
        $normalizedCurrentTarget = [System.IO.Path]::GetFullPath($currentTarget)
        $normalizedSource = [System.IO.Path]::GetFullPath($Source)

        if ($normalizedCurrentTarget -eq $normalizedSource) {
          Write-Info "Link already exists: $Target"
          return
        }
      }

      Write-WarningMessage "Removing existing symbolic link: $Target"
      Remove-Item `
        -LiteralPath $Target `
        -Force
    }
    else {
      $timestamp = Get-Date -Format "yyyyMMdd_HHmmssfff"
      $backupPath = "$Target.backup.$timestamp"
      Write-WarningMessage "Backing up existing item: $Target -> $backupPath"
      Move-Item `
        -LiteralPath $Target `
        -Destination $backupPath `
        -Force
    }
  }

  if ($PSCmdlet.ShouldProcess($Target, "Create symbolic link")) {
    Write-Success "Linking: $Target -> $Source"
    try {
      New-Item `
        -ItemType SymbolicLink `
        -Path $Target `
        -Value $Source `
        -Force | Out-Null
    }
    catch {
      Write-ErrorMessage "Failed to create symbolic link."
      Write-ErrorMessage "Please make sure you are running PowerShell as Administrator, or Windows Developer Mode is enabled."
      throw
    }
  }
}

function Invoke-DotfilesSetup {

  $dotfilesRoot = if ($PSScriptRoot) {
    $PSScriptRoot
  }
  else {
    Get-Location
  }

  $links = [ordered]@{
    # VSCode
    "$dotfilesRoot\vscode\keybindings.json" = "$env:APPDATA\Code\User\keybindings.json"
    "$dotfilesRoot\vscode\settings.json" = "$env:APPDATA\Code\User\settings.json"

    # wt
    "$dotfilesRoot\wt\settings.json" = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
  }

  foreach ($link in $links.GetEnumerator()) {
    New-SymbolicLinkSafe `
      -Source $link.Key `
      -Target $link.Value
  }
}

Invoke-DotfilesSetup