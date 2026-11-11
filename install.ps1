<#
  OneShot RTX (RayTrace2D) - installer
  Works on your own copy of OneShot (Steam or not). Needs nothing but Windows PowerShell.

  What it does:
    1. finds your OneShot folder (or asks you to pick it)
    2. copies the mod into <OneShot>\Mods
    3. backs up Data\xScripts.rxdata once (xScripts.rxdata.rt2d-backup)
    4. adds a tiny loader script right before the game's "Main" script
  Running it again is safe (it updates the mod and replaces the loader).
#>
param([string]$GameDir = "")

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'tools\rxdata.ps1')

function Say($msg, $color = 'Gray') { Write-Host $msg -ForegroundColor $color }

function Test-Game($dir) {
    return ($dir -and (Test-Path (Join-Path $dir 'oneshot.exe')) -and (Test-Path (Join-Path $dir 'Data\xScripts.rxdata')))
}

function Find-Game {
    if (Test-Game $GameDir) { return (Resolve-Path $GameDir).Path }
    foreach ($d in @($Here, (Split-Path -Parent $Here))) { if (Test-Game $d) { return $d } }
    # Steam libraries
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if ($steam) {
        $libs = @($steam)
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            $libs += [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"') | ForEach-Object { $_.Groups[1].Value -replace '\\\\', '\' }
        }
        foreach ($l in $libs) {
            $c = Join-Path $l 'steamapps\common\OneShot'
            if (Test-Game $c) { return $c }
        }
    }
    # ask
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Pick your OneShot folder (the one with oneshot.exe)'
    if ($dlg.ShowDialog() -eq 'OK' -and (Test-Game $dlg.SelectedPath)) { return $dlg.SelectedPath }
    return $null
}

Say ''
Say '  OneShot RTX - installer' 'Yellow'
Say '  -----------------------' 'Yellow'

$game = Find-Game
if (-not $game) { Say '  Could not find OneShot (no oneshot.exe + Data\xScripts.rxdata). Nothing changed.' 'Red'; exit 1 }
Say "  Game folder: $game"

if (Get-Process oneshot -ErrorAction SilentlyContinue) {
    Say '  OneShot is running. Close the game first, then run the installer again.' 'Red'; exit 1
}

# 1) mod files
$mods = Join-Path $game 'Mods'
New-Item -ItemType Directory -Force $mods, (Join-Path $mods 'ru_custom') | Out-Null
Copy-Item (Join-Path $Here 'Mods\RayTrace2D.rb') $mods -Force
Copy-Item (Join-Path $Here 'Mods\ru_custom\*.txt') (Join-Path $mods 'ru_custom') -Force
Copy-Item (Join-Path $Here 'Mods\README-RayTrace2D.txt') $mods -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $mods 'ru_custom.po') -Force -ErrorAction SilentlyContinue   # rebuilt by the mod
Say '  Mod files copied.' 'Green'

# 2) one-time backup of the game's script pack
$xs = Join-Path $game 'Data\xScripts.rxdata'
$bak = "$xs.rt2d-backup"
if (-not (Test-Path $bak)) { Copy-Item $xs $bak; Say '  Backup made: Data\xScripts.rxdata.rt2d-backup' 'Green' }
else { Say '  Backup already exists (kept as is).' }

# 3) loader before Main
$scripts = Read-RxScripts $xs
$scripts = @($scripts | Where-Object { $_.Name -ne $LoaderName })
$mainIdx = -1
for ($i = 0; $i -lt $scripts.Count; $i++) { if ($scripts[$i].Name -eq 'Main') { $mainIdx = $i } }
if ($mainIdx -lt 0) { Say '  This does not look like OneShot''s script pack (no "Main"). Nothing changed.' 'Red'; exit 1 }

$used = @{}; foreach ($s in $scripts) { $used[$s.Id] = $true }
$id = 77000001; while ($used.ContainsKey($id)) { $id++ }
$gameRuby = ($game -replace '\\', '/') -replace '"', ''
$loader = Get-LoaderCode $gameRuby
$entry = [pscustomobject]@{ Id = $id; Name = $LoaderName; NameBytes = [Text.Encoding]::UTF8.GetBytes($LoaderName); Code = (Compress-Zlib ([Text.Encoding]::UTF8.GetBytes($loader))) }
$list = New-Object System.Collections.ArrayList
$list.AddRange($scripts)
$list.Insert($mainIdx, $entry)

$tmp = "$xs.rt2d-new"
Write-RxScripts $list $tmp
# verify by reading our own output back before touching the real file
$check = Read-RxScripts $tmp
$ok = ($check.Count -eq $list.Count)
for ($i = 0; $ok -and $i -lt $check.Count; $i++) {
    if ($check[$i].Id -ne $list[$i].Id -or $check[$i].Name -ne $list[$i].Name -or $check[$i].Code.Length -ne $list[$i].Code.Length) { $ok = $false }
}
if (-not $ok) { Remove-Item $tmp -Force; Say '  Verification failed - your game was NOT changed.' 'Red'; exit 1 }
Move-Item $tmp $xs -Force
Say "  Loader installed before Main ($($list.Count) scripts, verified)." 'Green'

Say ''
Say '  Done! Start OneShot as usual.' 'Yellow'
Say '  In the game press HOME, F8 or tap ALT to open the RTX menu.'
Say '  To remove it later, run uninstall.bat.'
Say ''
