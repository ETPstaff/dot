# Starship Initialization
if (Get-Command starship -ErrorAction SilentlyContinue) {
  Invoke-Expression (&starship init powershell)
}

# Command Alias

## Neovim
function vim {
  nvim @args
}

## lsd
Remove-Item Alias:ls -Force -ErrorAction SilentlyContinue
function ls {
  lsd @args
}

## tree
function tree {
  lsd --tree @args
}
