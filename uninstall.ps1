<#
  OneShot RTX (RayTrace2D) - uninstaller
  Puts the game's script pack back and removes the mod files.
  Your saves and settings are never touched.
#>
param([string]$GameDir = "")

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'tools\rxdata.ps1')

function Say($msg, $color = 'Gray') { Write-Host $msg -ForegroundColor $color }
function Test-Game($dir) { return ($dir -and (Test-Path (Join-Path $dir 'oneshot.exe')) -and (Test-Path (Join-Path $dir 'Data\xScripts.rxdata'))) }

$game = $null
foreach ($d in @($GameDir, $Here, (Split-Path -Parent $Here))) { if (Test-Game $d) { $game = (Resolve-Path $d).Path; break } }
if (-not $game) {
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Pick your OneShot folder (the one with oneshot.exe)'
    if ($dlg.ShowDialog() -eq 'OK' -and (Test-Game $dlg.SelectedPath)) { $game = $dlg.SelectedPath }
}
if (-not $game) { Say 'Could not find OneShot. Nothing changed.' 'Red'; exit 1 }
if (Get-Process oneshot -ErrorAction SilentlyContinue) { Say 'Close OneShot first, then run this again.' 'Red'; exit 1 }

Say ''
Say '  OneShot RTX - uninstall' 'Yellow'
Say "  Game folder: $game"

$xs = Join-Path $game 'Data\xScripts.rxdata'
$bak = "$xs.rt2d-backup"
# remove the loader entry (works even if the backup is missing)
$scripts = @(Read-RxScripts $xs)
$clean = @($scripts | Where-Object { $_.Name -ne $LoaderName })
if ($clean.Count -ne $scripts.Count) {
    $tmp = "$xs.rt2d-new"
    Write-RxScripts $clean $tmp
    if (@(Read-RxScripts $tmp).Count -ne $clean.Count) { Remove-Item $tmp -Force; Say '  Verification failed - nothing changed.' 'Red'; exit 1 }
    Move-Item $tmp $xs -Force
    Say '  Loader removed from the game scripts.' 'Green'
} else {
    Say '  No loader found in the game scripts.'
}
if (Test-Path $bak) { Remove-Item $bak -Force }

$mods = Join-Path $game 'Mods'
foreach ($f in 'RayTrace2D.rb', 'ru_custom.po', 'README-RayTrace2D.txt') { Remove-Item (Join-Path $mods $f) -Force -ErrorAction SilentlyContinue }
Remove-Item (Join-Path $mods 'ru_custom') -Recurse -Force -ErrorAction SilentlyContinue
Say '  Mod files removed (your RayTrace2D.cfg/log stay, delete them if you want).' 'Green'
Say ''
Say '  OneShot is back to normal.' 'Yellow'
Say ''
