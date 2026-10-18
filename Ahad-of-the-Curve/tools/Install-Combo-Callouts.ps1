param(
    [ValidateSet('Preflight','Install','Verify','Rollback')][string]$Action='Preflight',
    [Parameter(Mandatory=$true)][string]$GamePath,
    [switch]$ConfirmedByReset
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
. (Join-Path $PSScriptRoot 'SG-GfsLibrary.ps1')
$game=[IO.Path]::GetFullPath($GamePath.Trim().Trim('"')).TrimEnd('\','/')
$mod='AOTC_Combo_Original'
$targetEntry='core/localization/en_loc.json'
$sourceArchive=Join-Path $game 'data01\core.gfs'
$assetDir=Join-Path $root 'assets\combo'
$luaSource=Join-Path $assetDir ($mod+'.lua')
$textSource=Join-Path $assetDir 'en_loc.json'
$manifestPath=Join-Path $root 'patches\combo-callouts-v1.json'
$luaTarget=Join-Path $game ('mods\'+$mod+'.lua')
$textTarget=Join-Path $game ('mods\'+$mod+'\en_loc.json')
$backups=Join-Path $game 'Restoration Backups'
$loader=Join-Path $game 'CoreMessaging.dll'
$pinLoader=Join-Path $root 'assets\bigband\loader-sha256.txt'
$originalSha='1d63b1e7b669b8653f7434e2f35e0a698ef7a4fba4f3ac2c8159b1355ff62fc7'
$patchedSha='606eebfdd71814118b9f6e59662e492fa0d046f1bec082495e49d78fe749cbc4'
$utf8=[Text.UTF8Encoding]::new($false,$true)

function Need([string]$p){
    if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required AOTC file missing: $p"}
}
function Hash([string]$p){
    Need $p
    $info=Get-Item -LiteralPath $p
    if(($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw "Linked file is not permitted: $p"}
    return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Read-Modern {
    Need $sourceArchive
    $idx=Get-SGIndex $sourceArchive
    if(-not $idx.ContainsKey($targetEntry)){throw "Modern localization missing: $targetEntry"}
    if([long]$idx[$targetEntry].Size -ne 833546){throw 'Unsupported English localization version.'}
    $fs=[IO.File]::OpenRead($sourceArchive)
    try{return ,(Read-SGEntry $fs $idx[$targetEntry])}
    finally{$fs.Dispose()}
}
function Replace-Combo([string]$text,[string]$key,[string]$from,[string]$to){
    $pattern='("'+[regex]::Escape($key)+'"\s*:\s*")(?<value>[^"]*)(")'
    $matches=[regex]::Matches($text,$pattern)
    if($matches.Count -ne 1){throw "Localization key missing or duplicated: $key"}
    $g=$matches[0].Groups['value']
    if($g.Value -cne $from){throw "Unexpected English combo label $key : $($g.Value)"}
    return $text.Substring(0,$g.Index)+$to+$text.Substring($g.Index+$g.Length)
}
function Validate-Assets {
    Need $manifestPath
    $spec=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if([int]$spec.schema -ne 1 -or
       [string]$spec.patchId -cne 'combo-original-2023-v1' -or
       [string]$spec.modName -cne $mod -or
       [string]$spec.targetArchive -cne 'core' -or
       [string]$spec.targetEntry -cne $targetEntry -or
       [int]$spec.sourceBytes -ne 833546 -or
       [int]$spec.restoredBytes -ne 833551 -or
       [string]$spec.sourceSHA256 -cne $originalSha -or
       [string]$spec.restoredSHA256 -cne $patchedSha){
        throw 'Unsupported original combo localization manifest.'
    }
    $old=Read-Modern
    if((Get-SGByteHash $old) -cne $originalSha){
        throw 'Current English localization does not match the verified modern base.'
    }
    Need $textSource
    if((Get-Item -LiteralPath $textSource).Length -ne 833551 -or
       (Hash $textSource) -cne $patchedSha){
        throw 'Bundled original combo localization is missing or corrupt.'
    }
    Need $luaSource
    Need $pinLoader
    if((Hash $loader) -cne (Get-Content -LiteralPath $pinLoader -Raw -Encoding UTF8).Trim().ToLowerInvariant()){
        throw 'Expected AOTC SkullLoader is not installed.'
    }
    $modernText=$utf8.GetString([byte[]]$old)
    $patched=$modernText
    $patched=Replace-Combo $patched 'Combo_16' 'MILQUETOAST' 'SPIFFY'
    $patched=Replace-Combo $patched 'Combo_17' 'RATED R' 'MILQUETOAST'
    $patched=Replace-Combo $patched 'Combo_18' 'SPIFFY' 'BARELY LEGAL'
    if((Get-SGByteHash ($utf8.GetBytes($patched))) -cne $patchedSha){
        throw 'The original combo patch does not consist of the three verified changes.'
    }
    return [pscustomobject]@{
        LuaSha=(Hash $luaSource)
        PatchSha=$patchedSha
    }
}
function ActiveRecord {
    if(-not(Test-Path -LiteralPath $backups -PathType Container)){return $null}
    $found=@(Get-ChildItem -LiteralPath $backups -Directory -Filter 'AOTC-Combo-Production-*' |
        Where-Object {
            (Test-Path -LiteralPath (Join-Path $_.FullName 'installed-files.json') -PathType Leaf) -and
            -not(Test-Path -LiteralPath (Join-Path $_.FullName 'UNINSTALLED.txt') -PathType Leaf)
        })
    if($found.Count -gt 1){throw 'Multiple active combo installation ledgers.'}
    if($found.Count -eq 1){return $found[0].FullName}
    return $null
}
function Check-Record([string]$folder,[object]$pins) {
    $entries=@(Get-Content -LiteralPath (Join-Path $folder 'installed-files.json') -Raw -Encoding UTF8 |
        ConvertFrom-Json | ForEach-Object {$_})
    $needed=@(
        [pscustomobject]@{path=$luaTarget;sha=$pins.LuaSha},
        [pscustomobject]@{path=$textTarget;sha=$pins.PatchSha}
    )
    if($entries.Count -ne 2){throw 'Invalid combo installation record.'}
    foreach($item in $needed) {
        $one=@($entries | Where-Object {
            [string]$_.target -ieq $item.path -and [string]$_.sha256 -ceq $item.sha
        })
        if($one.Count -ne 1 -or (Hash $item.path) -cne $item.sha){
            throw "Combo overlay differs from installation record: $($item.path)"
        }
    }
}
function Move-Safely([string]$from,[string]$to,[object]$steps) {
    if(-not(Test-Path -LiteralPath $from)){throw "Rollback source missing: $from"}
    if(Test-Path -LiteralPath $to){throw "Rollback target occupied: $to"}
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $to) -Force -ErrorAction Stop)
    Move-Item -LiteralPath $from -Destination $to -ErrorAction Stop
    [void]$steps.Add([pscustomobject]@{From=$from;To=$to})
}
function Undo-Steps([object]$steps) {
    for($i=$steps.Count-1;$i -ge 0;$i--){
        $s=$steps[$i]
        if(Test-Path -LiteralPath $s.To) {
            Move-Item -LiteralPath $s.To -Destination $s.From -ErrorAction Stop
        }
    }
}

Need (Join-Path $game 'SkullGirls.exe')
if(Get-Process -Name SkullGirls -ErrorAction SilentlyContinue){throw 'Close Skullgirls first.'}
$pins=Validate-Assets
$active=ActiveRecord
$trialLua=Join-Path $game 'mods\AOTC_Combo_Original_Test.lua'
$trialFile=Join-Path $game 'mods\AOTC_Combo_Original_Test\en_loc.json'
if((Test-Path -LiteralPath $trialLua) -or (Test-Path -LiteralPath $trialFile)){
    throw 'An isolated original combo test is still installed. Run its -Action Remove first.'
}
if($Action -eq 'Preflight'){
    if($active){Check-Record $active $pins}
    elseif((Test-Path -LiteralPath $luaTarget) -or (Test-Path -LiteralPath $textTarget)){
        throw 'Untracked original combo mod files exist.'
    }
    Write-Host 'Original combo callouts preflight passed.' -ForegroundColor Green
    return
}
if($Action -eq 'Verify'){
    if(-not $active){throw 'Original combo callouts are not installed.'}
    Check-Record $active $pins
    Write-Host 'Original combo callouts verified.' -ForegroundColor Green
    return
}
if($Action -eq 'Install'){
    if($active){
        Check-Record $active $pins
        Write-Host 'Original combo callouts already restored.'
        return
    }
    if((Test-Path -LiteralPath $luaTarget) -or (Test-Path -LiteralPath $textTarget)){
        throw 'Untracked original combo mod files exist.'
    }
    $stamp=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)
    $record=Join-Path $backups ('AOTC-Combo-Production-'+$stamp)
    $assets=@(
        [pscustomobject]@{Source=$luaSource;Target=$luaTarget;Sha=$pins.LuaSha},
        [pscustomobject]@{Source=$textSource;Target=$textTarget;Sha=$pins.PatchSha}
    )
    $moved=New-Object 'System.Collections.Generic.List[object]'
    $copied=New-Object 'System.Collections.Generic.List[object]'
    try {
        [void](New-Item -ItemType Directory -Path $record -ErrorAction Stop)
        foreach($name in @('data02','saves_CC.json')){
            $path=Join-Path $game $name
            if(Test-Path -LiteralPath $path){
                $dest=Join-Path $record ('Before\'+$name)
                Move-Safely $path $dest $moved
            }
        }
        foreach($item in $assets){
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $item.Target) -Force -ErrorAction Stop)
            Copy-Item -LiteralPath $item.Source -Destination $item.Target -ErrorAction Stop
            [void]$copied.Add($item)
            if((Hash $item.Target) -cne $item.Sha){throw 'Combo overlay failed installation SHA256 verification.'}
        }
        $rows=@($assets | ForEach-Object {[pscustomobject]@{target=$_.Target;sha256=$_.Sha}})
        $rows | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $record 'installed-files.json') -Encoding UTF8
        [IO.File]::WriteAllText((Join-Path $record 'INSTALLED.txt'),(Get-Date -Format 'o'),[Text.Encoding]::UTF8)
    }catch{
        $failure=$_
        foreach($item in $copied){
            if(Test-Path -LiteralPath $item.Target){
                if((Hash $item.Target) -cne $item.Sha){throw "Manual recovery required: modified $($item.Target)"}
                Remove-Item -LiteralPath $item.Target -Force
            }
        }
        Undo-Steps $moved
        throw $failure
    }
    Write-Host 'Original 16, 17 and 18 hit combo messages restored.' -ForegroundColor Green
    return
}
if($Action -eq 'Rollback'){
    if(-not $active){
        if((Test-Path -LiteralPath $luaTarget) -or (Test-Path -LiteralPath $textTarget)){
            throw 'Untracked combo files cannot be safely reset.'
        }
        Write-Host 'No combo overlay to remove.'
        return
    }
    Check-Record $active $pins
    if(-not $ConfirmedByReset){
        $answer=Read-Host 'Type ROLLBACK to remove the original combo callouts'
        if($answer -cne 'ROLLBACK'){throw 'Combo rollback cancelled.'}
    }
    $moves=New-Object 'System.Collections.Generic.List[object]'
    try {
        foreach($name in @('data02','saves_CC.json')){
            $p=Join-Path $game $name
            if(Test-Path -LiteralPath $p){
                Move-Safely $p (Join-Path $active ('After\'+$name)) $moves
            }
        }
        Move-Safely $luaTarget (Join-Path $active ('Removed\'+$mod+'.lua')) $moves
        Move-Safely $textTarget (Join-Path $active 'Removed\en_loc.json') $moves
        foreach($name in @('data02','saves_CC.json')){
            $before=Join-Path $active ('Before\'+$name)
            if(Test-Path -LiteralPath $before){Move-Safely $before (Join-Path $game $name) $moves}
        }
        [IO.File]::WriteAllText((Join-Path $active 'UNINSTALLED.txt'),(Get-Date -Format 'o'),[Text.Encoding]::UTF8)
    }catch{
        $failure=$_
        Undo-Steps $moves
        throw $failure
    }
    $folder=Join-Path $game ('mods\'+$mod)
    if(Test-Path -LiteralPath $folder -PathType Container){
        if(@(Get-ChildItem -LiteralPath $folder -Force).Count -eq 0){
            Remove-Item -LiteralPath $folder -Force
        }
    }
    Write-Host 'Original combo callouts removed; previous loader state restored.' -ForegroundColor Green
    return
}
