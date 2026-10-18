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
$mod='AOTC_Soviet_Historical_Test'
$relativeBank='characters/hitspark_alt3.snd-wav'
$assets=Join-Path $root 'assets\soviet'
$manifestPath=Join-Path $root 'patches\soviet-voice-v1.json'
$luaSource=Join-Path $assets ($mod+'.lua')
$bankSource=Join-Path $assets 'hitspark_alt3.snd-wav'
$luaTarget=Join-Path $game ('mods\'+$mod+'.lua')
$bankTarget=Join-Path $game ('mods\'+$mod+'\hitspark_alt3.snd-wav')
$backupRoot=Join-Path $game 'Restoration Backups'
$originalArchive=Join-Path $game 'data01\characters-win.gfs'
$loader=Join-Path $game 'CoreMessaging.dll'
$expectedModName='soviet-mikez-2023-v1'
$modernPin='41dd85ab641de943da47fce17c2225025069a1c0a8ca351f7a751d5510b6939f'

function Need-File([string]$path){
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Missing required file: $path"}
}
function Hash-File([string]$path){
    Need-File $path
    $file=Get-Item -LiteralPath $path
    if(($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw "Refusing linked asset: $path"}
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Current-Bank-Hash {
    Need-File $originalArchive
    $index=Get-SGIndex $originalArchive
    if(-not $index.ContainsKey($relativeBank)){throw "Modern sound bank entry missing: $relativeBank"}
    $entry=$index[$relativeBank]
    if([long]$entry.Size -ne 12547380){throw 'Unsupported modern sound bank length.'}
    $stream=[IO.File]::OpenRead($originalArchive)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{
        [void]$stream.Seek([long]$entry.Offset,[IO.SeekOrigin]::Begin)
        [byte[]]$buffer=[byte[]]::new(1048576)
        [long]$remaining=[long]$entry.Size
        while($remaining -gt 0){
            $take=[int][Math]::Min($remaining,[long]$buffer.Length)
            $count=$stream.Read($buffer,0,$take)
            if($count -le 0){throw 'Truncated original sound bank.'}
            [void]$sha.TransformBlock($buffer,0,$count,$buffer,0)
            $remaining-=$count
        }
        [void]$sha.TransformFinalBlock([byte[]]::new(0),0,0)
        return ([BitConverter]::ToString($sha.Hash)).Replace('-','').ToLowerInvariant()
    }finally{$sha.Dispose();$stream.Dispose()}
}
function Active-Ledger {
    if(-not(Test-Path -LiteralPath $backupRoot -PathType Container)){return $null}
    $active=@(Get-ChildItem -LiteralPath $backupRoot -Directory -Filter 'AOTC-Soviet-Production-*' |
        Where-Object {
            (Test-Path -LiteralPath (Join-Path $_.FullName 'installed-files.json') -PathType Leaf) -and
            -not (Test-Path -LiteralPath (Join-Path $_.FullName 'UNINSTALLED.txt') -PathType Leaf)
        })
    if($active.Count -gt 1){throw 'Multiple active Soviet production installation records.'}
    if($active.Count -eq 1){return $active[0].FullName}
    return $null
}
function Verify-Ledger([string]$folder,[object]$spec){
    $records=@(Get-Content -LiteralPath (Join-Path $folder 'installed-files.json') -Raw -Encoding UTF8 |
        ConvertFrom-Json | ForEach-Object {$_})
    if($records.Count -ne 2){throw 'Unexpected Soviet installation ledger size.'}
    $expect=@(
        [pscustomobject]@{target=$luaTarget;sha256=([string]$spec.luaSHA256).ToLowerInvariant()},
        [pscustomobject]@{target=$bankTarget;sha256=([string]$spec.hybridSHA256).ToLowerInvariant()}
    )
    foreach($item in $expect){
        $hit=@($records | Where-Object {
            [string]$_.target -ieq $item.target -and [string]$_.sha256 -ceq $item.sha256
        })
        if($hit.Count -ne 1){throw "Invalid Soviet installation ledger: $($item.target)"}
        if((Hash-File $item.target) -cne $item.sha256){
            throw "Installed Soviet file altered: $($item.target)"
        }
    }
    return $true
}
function Verify-OtherAotc {
    Need-File $loader
    $pinPath=Join-Path $root 'assets\bigband\loader-sha256.txt'
    Need-File $pinPath
    $pin=(Get-Content -LiteralPath $pinPath -Raw -Encoding UTF8).Trim().ToLowerInvariant()
    if((Hash-File $loader) -cne $pin){throw 'The installed SkullLoader DLL is not the AOTC pinned version.'}
    foreach($name in @('AOTC_BigBand_2023.lua','AOTC_BlackEgret_Combat_Test.lua',
        'AOTC_Parasoul_Select_Historical.lua')){
        Need-File (Join-Path $game ('mods\'+$name))
    }
    foreach($name in @('d3d9.dll','dbghelp.dll')){
        if(Test-Path -LiteralPath (Join-Path $game $name)){throw "Conflicting loader $name"}
    }
}
function Validate-Payload {
    Need-File $manifestPath
    $spec=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if([string]$spec.patchId -cne $expectedModName -or
       [string]$spec.targetEntry -cne $relativeBank -or
       [string]$spec.modName -cne $mod -or
       [int]$spec.modernClips -ne 337 -or [int]$spec.historicalClips -ne 198 -or
       [string]$spec.modernSHA256 -cne $modernPin){
        throw 'Unsupported Soviet production manifest.'
    }
    foreach($pin in @([string]$spec.luaSHA256,[string]$spec.hybridSHA256)){
        if($pin -cnotmatch '^[a-f0-9]{64}$'){throw 'Invalid Soviet asset pin.'}
    }
    if((Hash-File $luaSource) -cne ([string]$spec.luaSHA256).ToLowerInvariant()){
        throw 'Bundled Soviet Lua does not match pinned SHA256.'
    }
    if((Get-Item -LiteralPath $bankSource).Length -ne [long]$spec.hybridBytes -or
       [long]$spec.hybridBytes -lt 11000000 -or [long]$spec.hybridBytes -gt 16000000 -or
       (Hash-File $bankSource) -cne ([string]$spec.hybridSHA256).ToLowerInvariant()){
        throw 'Bundled Soviet sound bank is missing or corrupt.'
    }
    if((Current-Bank-Hash) -cne $modernPin){
        throw 'Unsupported current Skullgirls audio archive. Nothing changed.'
    }
    return $spec
}
if(-not(Test-Path -LiteralPath (Join-Path $game 'SkullGirls.exe') -PathType Leaf)){
    throw "Not a Skullgirls game directory: $game"
}
if(Get-Process -Name SkullGirls -ErrorAction SilentlyContinue){throw 'Close Skullgirls first.'}
$spec=Validate-Payload
$record=Active-Ledger
if($Action -eq 'Preflight'){
    if($record){
        [void](Verify-Ledger $record $spec)
        Write-Host 'Soviet voice already installed; matching production ledger found.'
    }elseif((Test-Path -LiteralPath $luaTarget) -or (Test-Path -LiteralPath $bankTarget)){
        throw 'An untracked Soviet voice mod is present. Refusing to overwrite it.'
    }
    Write-Host 'Optional Mike Z Soviet voice preflight passed.' -ForegroundColor Cyan
    return
}
if($Action -eq 'Verify'){
    if(-not $record){throw 'Soviet voice is not installed; there is no active ledger.'}
    [void](Verify-Ledger $record $spec)
    Verify-OtherAotc
    Write-Host 'Optional Soviet production audio, Lua and rollback record verified.' -ForegroundColor Green
    return
}
if($Action -eq 'Install'){
    Verify-OtherAotc
    if($record){
        [void](Verify-Ledger $record $spec)
        Write-Host 'Mike Z Soviet voice is already installed and verified.' -ForegroundColor Green
        return
    }
    if((Test-Path -LiteralPath $luaTarget) -or (Test-Path -LiteralPath $bankTarget)){
        throw 'Untracked Soviet mod files exist. Nothing changed.'
    }
    $stamp=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)
    $record=Join-Path $backupRoot ('AOTC-Soviet-Production-'+$stamp)
    $assetsToInstall=@(
        [pscustomobject]@{Source=$luaSource;Target=$luaTarget;Hash=([string]$spec.luaSHA256)},
        [pscustomobject]@{Source=$bankSource;Target=$bankTarget;Hash=([string]$spec.hybridSHA256)}
    )
    $moved=New-Object 'System.Collections.Generic.List[object]'
    $copied=New-Object 'System.Collections.Generic.List[object]'
    try{
        [void](New-Item -Path $record -ItemType Directory -ErrorAction Stop)
        foreach($name in @('data02','saves_CC.json')){
            $src=Join-Path $game $name
            if(Test-Path -LiteralPath $src){
                $dest=Join-Path $record ('Before\'+$name)
                [void](New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force -ErrorAction Stop)
                Move-Item -LiteralPath $src -Destination $dest -ErrorAction Stop
                [void]$moved.Add([pscustomobject]@{From=$src;To=$dest})
            }
        }
        foreach($asset in $assetsToInstall){
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $asset.Target) -Force -ErrorAction Stop)
            Copy-Item -LiteralPath $asset.Source -Destination $asset.Target -ErrorAction Stop
            [void]$copied.Add($asset)
            if((Hash-File $asset.Target) -cne $asset.Hash){
                throw "Soviet test copy failed SHA256 verification: $($asset.Target)"
            }
        }
        $ledger=@($assetsToInstall|ForEach-Object {
            [pscustomobject]@{target=$_.Target;sha256=$_.Hash}
        })
        $ledger|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $record 'installed-files.json') -Encoding UTF8
        [IO.File]::WriteAllText((Join-Path $record 'INSTALLED.txt'),(Get-Date -Format 'o'),[Text.Encoding]::UTF8)
    }catch{
        $failure=$_
        foreach($item in $copied){
            if((Test-Path -LiteralPath $item.Target -PathType Leaf) -and
               (Hash-File $item.Target) -ceq $item.Hash){Remove-Item -LiteralPath $item.Target -Force}
        }
        for($j=$moved.Count-1;$j -ge 0;$j--){
            if(Test-Path -LiteralPath $moved[$j].To){
                Move-Item -LiteralPath $moved[$j].To -Destination $moved[$j].From -ErrorAction Stop
            }
        }
        throw $failure
    }
    Write-Host 'COMPLETE: historical Mike Z Soviet voice enabled (337-slot compatible bank).' -ForegroundColor Green
    Write-Host ('Soviet production restore ledger: '+$record)
    return
}
if($Action -eq 'Rollback'){
    if(-not $record){
        if((Test-Path -LiteralPath $luaTarget) -or (Test-Path -LiteralPath $bankTarget)){
            throw 'Soviet voice files present without installation record. Refusing untracked removal.'
        }
        Write-Host 'Optional Soviet voice was not installed; nothing to reverse.'
        return
    }
    [void](Verify-Ledger $record $spec)
    foreach($name in @('data02','saves_CC.json')){
        $before=Join-Path $record ('Before\'+$name)
        if((Test-Path -LiteralPath $before) -and (Test-Path -LiteralPath (Join-Path $record ('After\'+$name)))){
            throw "Preexisting Soviet rollback destination for $name."
        }
    }
    Write-Host 'Optional Soviet voice rollback will preserve the two mod files and return the pre-voice loader state.'
    if(-not $ConfirmedByReset){
        $confirmation=Read-Host 'Type ROLLBACK to remove the original Soviet voice overlay'
        if($confirmation -cne 'ROLLBACK'){throw 'Soviet voice rollback cancelled.'}
    }
    $moves=New-Object 'System.Collections.Generic.List[object]'
    function Move-Tracked([string]$from,[string]$to){
        if(-not(Test-Path -LiteralPath $from)){throw "Missing source for rollback: $from"}
        if(Test-Path -LiteralPath $to){throw "Rollback destination occupied: $to"}
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $to) -Force -ErrorAction Stop)
        Move-Item -LiteralPath $from -Destination $to -ErrorAction Stop
        [void]$moves.Add([pscustomobject]@{From=$from;To=$to})
    }
    try{
        foreach($name in @('data02','saves_CC.json')){
            $current=Join-Path $game $name
            if(Test-Path -LiteralPath $current){
                Move-Tracked $current (Join-Path $record ('After\'+$name))
            }
        }
        Move-Tracked $luaTarget (Join-Path $record ('Removed\'+$mod+'.lua'))
        Move-Tracked $bankTarget (Join-Path $record 'Removed\hitspark_alt3.snd-wav')
        foreach($name in @('data02','saves_CC.json')){
            $before=Join-Path $record ('Before\'+$name)
            if(Test-Path -LiteralPath $before){
                Move-Tracked $before (Join-Path $game $name)
            }
        }
        [IO.File]::WriteAllText((Join-Path $record 'UNINSTALLED.txt'),(Get-Date -Format 'o'),[Text.Encoding]::UTF8)
    }catch{
        $failure=$_
        for($j=$moves.Count-1;$j -ge 0;$j--){
            if(Test-Path -LiteralPath $moves[$j].To){
                Move-Item -LiteralPath $moves[$j].To -Destination $moves[$j].From -ErrorAction Stop
            }
        }
        throw $failure
    }
    $modFolder=Join-Path $game ('mods\'+$mod)
    if(Test-Path -LiteralPath $modFolder -PathType Container){
        if(@(Get-ChildItem -LiteralPath $modFolder -Force).Count -eq 0){
            Remove-Item -LiteralPath $modFolder -Force
        }
    }
    Write-Host 'Optional Soviet voice removed; original modern announcer bank and pre-voice loader state restored.' -ForegroundColor Green
    return
}
