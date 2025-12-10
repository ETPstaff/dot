$DotDir = $PSScriptRoot
New-Item -ItemType SymbolicLink -Path (Join-Path (Join-Path (Join-Path (Join-Path $env:LOCALAPPDATA "Packages") "Microsoft.WindowsTerminal_8wekyb3d8bbwe") "LocalState") "settings.json") -Value (Join-Path (Join-Path $DotDir "wt") "settings.json") -Force | Out-Null
New-Item -ItemType SymbolicLink -Path (Join-Path (Join-Path $env:APPDATA "helix") "config.toml") -Value (Join-Path (Join-Path $DotDir "helix") "config.toml") -Force | Out-Null
New-Item -ItemType SymbolicLink -Path (Join-Path (Join-Path (Join-Path $env:APPDATA "Code") "User") "settings.json") -Value (Join-Path (Join-Path $DotDir "vscode") "settings.json") -Force | Out-Null
New-Item -ItemType SymbolicLink -Path (Join-Path (Join-Path (Join-Path $env:APPDATA "Code") "User") "keybindings.json") -Value (Join-Path (Join-Path $DotDir "vscode") "keybindings.json") -Force | Out-Null
