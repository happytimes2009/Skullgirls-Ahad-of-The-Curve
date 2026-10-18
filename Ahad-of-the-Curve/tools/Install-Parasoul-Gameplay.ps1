param(
    [ValidateSet('Preflight','Install','Verify','Rollback')][string]$Action='Preflight',
    [Parameter(Mandatory=$true)][string]$GamePath,
    [switch]$Runtime,
    [switch]$ConfirmedByReset
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
. (Join-Path $PSScriptRoot 'SG-Parasoul-Palettes.ps1')
$game=[IO.Path]::GetFullPath($GamePath.Trim().Trim('"')).TrimEnd('\','/')
$backupRoot=Join-Path $game 'Restoration Backups'
$egretMod=Join-Path $game 'mods\AOTC_BlackEgret_Combat_Test\parasoul.foit'
$egretArt=Join-Path $game 'mods\AOTC_BlackEgret_Combat_Test\parasoul.art'
$selectName='AOTC_Parasoul_Select_Historical'
$selectLua=Join-Path $game ('mods\'+$selectName+'.lua')
$selectDir=Join-Path $game ('mods\'+$selectName)
$luaSource=Join-Path $root ('assets\egret\'+$selectName+'.lua')
$ledgerId='aotc-production-parasoul-combat-select-v1'
$baselineHash='d8b4fb3cd9ed199a2e3b13a643b00139caf409f05eae07ddfe2c5a18f37d2b36'
$artHash='345bdeabf617dec8adbe32da17e92afb18eb50ec5f09543f40f1e55fe0cd9f34'
function Closed {
    if(-not(Test-Path -LiteralPath (Join-Path $game 'SkullGirls.exe') -PathType Leaf)){
        throw "Skullgirls executable not found in: $game"
    }
    if(Get-Process -Name SkullGirls -ErrorAction SilentlyContinue){
        throw 'Close Skullgirls before changing or verifying assets.'
    }
}
function HashFile([string]$p) {
    if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "File missing: $p"}
    $item=Get-Item -LiteralPath $p
    if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){
        throw "Refusing linked file: $p"
    }
    return (Get-SGHash $p)
}
function StageFile([byte[]]$bytes,[string]$to,[string]$hash) {
    if(Test-Path -LiteralPath $to){throw "Installation target exists: $to"}
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $to) -Force -ErrorAction Stop)
    [IO.File]::WriteAllBytes($to,$bytes)
    if((HashFile $to) -cne $hash){throw "Copied asset does not match pinned SHA256: $to"}
}
function GetRecords {
    if(-not(Test-Path -LiteralPath $backupRoot -PathType Container)){return @()}
    return @(Get-ChildItem -LiteralPath $backupRoot -Directory -Filter 'AOTC-Parasoul-Gameplay-Production-*' -ErrorAction Stop)
}
function ActiveRecord {
    $active=@(GetRecords | Where-Object{
        (Test-Path -LiteralPath (Join-Path $_.FullName 'INSTALLED.txt') -PathType Leaf) -and
        -not(Test-Path -LiteralPath (Join-Path $_.FullName 'UNINSTALLED.txt') -PathType Leaf)
    })
    $pending=@(GetRecords | Where-Object{
        (Test-Path -LiteralPath (Join-Path $_.FullName 'STARTED.txt') -PathType Leaf) -and
        -not(Test-Path -LiteralPath (Join-Path $_.FullName 'INSTALLED.txt') -PathType Leaf) -and
        -not(Test-Path -LiteralPath (Join-Path $_.FullName 'FAILED_ROLLED_BACK.txt') -PathType Leaf)
    })
    if($pending.Count){throw "Incomplete Parasoul production operation: $($pending[0].FullName)"}
    if($active.Count -gt 1){throw 'Multiple active Parasoul gameplay production ledgers.'}
    if($active.Count -eq 1){return $active[0].FullName}
    return $null
}
function ExpectedTargets([object]$build,[string]$record){
    $out=New-Object 'System.Collections.Generic.List[object]'
    $out.Add([pscustomobject]@{Path=$egretMod;Hash=[string]$build.FoitHash})
    $out.Add([pscustomobject]@{Path=$selectLua;Hash=(HashFile $luaSource)})
    foreach($item in @($build.Select)){
        $out.Add([pscustomobject]@{
            Path=(Join-Path $selectDir $item.Name);Hash=[string]$item.Hash
        })
    }
    if($out.Count -ne 15){throw 'Expected one FOIT, one loader, thirteen DDS sources.'}
    return @($out.ToArray())
}
function OtherModsSnapshot {
    $mods=@(Get-ChildItem -LiteralPath (Join-Path $game 'mods') -File -Recurse -Force)
    if($mods.Count -ne 23){throw "Expected 23 existing AOTC mod files, found $($mods.Count)"}
    $items=@($mods|Where-Object{$_.FullName -ine $egretMod})
    $items+=@(Get-Item -LiteralPath (Join-Path $game 'CoreMessaging.dll'))
    if($items.Count -ne 23){throw 'Expected 22 untouched mods and loader DLL.'}
    return @($items|ForEach-Object{
        [pscustomobject]@{Path=$_.FullName;Hash=(HashFile $_.FullName)}
    })
}
function ValidateOtherMods([object]$m){
    if(@($m.otherFiles).Count -ne 23){throw 'Incomplete installed baseline inventory.'}
    $seen=@{}
    $prefix=$game+'\'
    foreach($f in @($m.otherFiles)){
        $p=[string]$f.Path
        if(-not $p.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or
           $seen.ContainsKey($p) -or $p -ieq $egretMod -or
           $p.StartsWith(($selectDir+'\'),[StringComparison]::OrdinalIgnoreCase) -or
           $p -ieq $selectLua){throw "Unsafe/duplicate baseline: $p"}
        if((HashFile $p) -cne [string]$f.Hash){throw "Other AOTC mod changed: $p"}
        $seen[$p]=$true
    }
    return $seen
}
function AssertInstalled([string]$record,[object]$build,[switch]$CheckRuntime){
    $jsonPath=Join-Path $record 'state.json'
    if(-not(Test-Path -LiteralPath $jsonPath -PathType Leaf)){throw 'Missing Parasoul gameplay production ledger.'}
    $m=Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if([string]$m.id -cne $ledgerId -or [string]$m.foitSha256 -cne [string]$build.FoitHash -or
       @($m.targets).Count -ne 15){throw 'Parasoul gameplay production ledger metadata mismatch.'}
    $expected=@(ExpectedTargets $build $record)
    for($i=0;$i -lt $expected.Count;$i++){
        $a=$expected[$i];$b=$m.targets[$i]
        if([string]$a.Path -ine [string]$b.Path -or [string]$a.Hash -cne [string]$b.Hash){
            throw "Production ledger mismatch: $($a.Path)"
        }
        if((HashFile $a.Path) -cne [string]$a.Hash){
            throw "Wrong installed palette or FOIT: $($a.Path)"
        }
    }
    if((HashFile $egretArt) -cne $artHash){throw 'Egret ART has changed.'}
    $seen=ValidateOtherMods $m
    $seen[$egretMod]=$true
    $seen[$selectLua]=$true
    foreach($asset in @($build.Select)){$seen[(Join-Path $selectDir $asset.Name)]=$true}
    $sovietLua=Join-Path $game 'mods\AOTC_Soviet_Historical_Test.lua'
    $sovietBank=Join-Path $game 'mods\AOTC_Soviet_Historical_Test\hitspark_alt3.snd-wav'
    $sovietPresent=(Test-Path -LiteralPath $sovietLua -PathType Leaf) -or
        (Test-Path -LiteralPath $sovietBank -PathType Leaf)
    if($sovietPresent){
        & (Join-Path $PSScriptRoot 'Install-Soviet-Voice.ps1') -Action Verify -GamePath $game
        $seen[$sovietLua]=$true
        $seen[$sovietBank]=$true
    }
    $comboLua=Join-Path $game 'mods\AOTC_Combo_Original.lua'
    $comboText=Join-Path $game 'mods\AOTC_Combo_Original\en_loc.json'
    $comboPresent=(Test-Path -LiteralPath $comboLua -PathType Leaf) -or
        (Test-Path -LiteralPath $comboText -PathType Leaf)
    if($comboPresent){
        & (Join-Path $PSScriptRoot 'Install-Combo-Callouts.ps1') -Action Verify -GamePath $game
        $seen[$comboLua]=$true
        $seen[$comboText]=$true
    }
    $actual=@(Get-ChildItem -LiteralPath (Join-Path $game 'mods') -File -Recurse -Force)
    $expectedCount=37
    if($sovietPresent){$expectedCount+=2}
    if($comboPresent){$expectedCount+=2}
    if($actual.Count -ne $expectedCount){
        throw "Expected $expectedCount mod files, found $($actual.Count)"
    }
    foreach($file in $actual){
        if(-not $seen.ContainsKey($file.FullName)){
            throw "Unknown installed mod: $($file.FullName)"
        }
    }
    $before=Join-Path $record 'Before\parasoul.foit'
    if((HashFile $before) -cne $baselineHash){
        throw 'Original 65-frame Egret FOIT backup missing or changed.'
    }
    if($CheckRuntime){
        $derived=Get-AOTCGfsEntry (Join-Path $game 'data02\characters-foits.gfs') 'characters/parasoul.foit'
        if((Get-SGByteHash $derived) -cne [string]$build.FoitHash){throw 'Combat FOIT not loaded into data02.'}
        $art=Get-AOTCGfsEntry (Join-Path $game 'data02\characters-art.gfs') 'characters/parasoul.art'
        if((Get-SGByteHash $art) -cne $artHash){throw 'Black Egret ART missing from data02.'}
        foreach($asset in @($build.Select)){
            $dds=Get-AOTCGfsEntry (Join-Path $game 'data02\sprites.gfs') ('sprites/'+$asset.Name)
            if((Get-SGByteHash $dds) -cne $asset.Hash){
                throw "Character-select palette missing in data02: $($asset.Name)"
            }
        }
        Write-Host 'RUNTIME VERIFIED: combined combat FOIT and all 13 select DDS entries.' -ForegroundColor Green
    }
    return $m
}
function DoMove([string]$from,[string]$to,[object]$moves){
    if(-not(Test-Path -LiteralPath $from)){throw "Required file absent: $from"}
    if(Test-Path -LiteralPath $to){throw "Destination unexpectedly occupied: $to"}
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $to) -Force -ErrorAction Stop)
    Move-Item -LiteralPath $from -Destination $to -ErrorAction Stop
    [void]$moves.Add([pscustomobject]@{From=$from;To=$to})
}
function UndoMoves([object]$moves){
    $ok=$true
    for($i=$moves.Count-1;$i -ge 0;$i--){
        $step=$moves[$i]
        if(Test-Path -LiteralPath $step.From){$ok=$false;continue}
        try{Move-Item -LiteralPath $step.To -Destination $step.From -ErrorAction Stop}
        catch{$ok=$false}
    }
    return $ok
}

Closed
$build=Get-AOTCCombinedPalettes -Root $root -GamePath $game
$active=ActiveRecord
if($Action -eq 'Preflight'){
    if($active){throw 'Parasoul gameplay production already installed.'}
    foreach($relative in @('mods\AOTC_Parasoul_Select_Historical.lua',
            'mods\AOTC_Parasoul_Select_Historical')){
        if(Test-Path -LiteralPath (Join-Path $game $relative)){throw "Existing incompatible select mod: $relative"}
    }
    if(-not(Test-Path -LiteralPath $luaSource -PathType Leaf)){
        throw 'Bundled production Lua missing.'
    }
    Write-Host 'Parasoul 13-palette production preflight passed; complete source data bundled.' -ForegroundColor Green
    return
}
if($Action -eq 'Install'){
    if($active){
        [void](AssertInstalled $active $build)
        Write-Host 'Parasoul combat and selection are already restored.' -ForegroundColor Green
        return
    }
    $legacy=Join-Path $PSScriptRoot 'Test-Existing-Restoration.ps1'
    if(-not (& $legacy -GamePath $game)){
        throw 'Install the verified seven-section AOTC production baseline first.'
    }
    if((HashFile $egretMod) -cne $baselineHash -or
       (HashFile $egretArt) -cne $artHash){
        throw 'Egret production baseline has changed.'
    }
    if((Test-Path -LiteralPath $selectLua) -or
       (Test-Path -LiteralPath $selectDir)){throw 'Select palette overlay already exists.'}
    $snapshot=@(OtherModsSnapshot)
    $targets=@(ExpectedTargets $build '')
    $stamp=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)
    $record=Join-Path $backupRoot ('AOTC-Parasoul-Gameplay-Production-'+$stamp)
    [void](New-Item -ItemType Directory -Path (Join-Path $record 'Before') -Force -ErrorAction Stop)
    $caches=@()
    foreach($name in @('data02','saves_CC.json')){
        $caches+=([bool](Test-Path -LiteralPath (Join-Path $game $name)))
    }
    $m=[pscustomobject]@{
        id=$ledgerId;foitSha256=[string]$build.FoitHash;
        targets=$targets;otherFiles=$snapshot;hadData02=$caches[0];hadSavesCC=$caches[1]
    }
    [IO.File]::WriteAllText((Join-Path $record 'state.json'),
        (ConvertTo-Json -InputObject $m -Depth 8),[Text.Encoding]::UTF8)
    [IO.File]::WriteAllText((Join-Path $record 'STARTED.txt'),(Get-Date -Format o),[Text.Encoding]::UTF8)
    $moves=New-Object 'System.Collections.Generic.List[object]'
    $created=New-Object 'System.Collections.Generic.List[object]'
    try{
        DoMove $egretMod (Join-Path $record 'Before\parasoul.foit') $moves
        foreach($name in @('data02','saves_CC.json')){
            $original=Join-Path $game $name
            if(Test-Path -LiteralPath $original){
                DoMove $original (Join-Path $record ('Before\'+$name)) $moves
            }
        }
        StageFile $build.FoitBytes $egretMod ([string]$build.FoitHash)
        [void]$created.Add([pscustomobject]@{Path=$egretMod;Hash=[string]$build.FoitHash})
        [byte[]]$luaBytes=[IO.File]::ReadAllBytes($luaSource)
        StageFile $luaBytes $selectLua (HashFile $luaSource)
        [void]$created.Add([pscustomobject]@{Path=$selectLua;Hash=(HashFile $luaSource)})
        foreach($item in @($build.Select)){
            $p=Join-Path $selectDir $item.Name
            StageFile $item.Bytes $p ([string]$item.Hash)
            [void]$created.Add([pscustomobject]@{Path=$p;Hash=[string]$item.Hash})
        }
        [IO.File]::WriteAllText((Join-Path $record 'INSTALLED.txt'),(Get-Date -Format o),[Text.Encoding]::UTF8)
        Remove-Item -LiteralPath (Join-Path $record 'STARTED.txt') -Force -ErrorAction Stop
    }catch{
        $why=$_.Exception.Message
        $ok=$true
        $failed=Join-Path $record 'Failed'
        [void](New-Item -ItemType Directory -Path $failed -Force)
        foreach($item in $created){
            if(Test-Path -LiteralPath $item.Path -PathType Leaf){
                if((HashFile $item.Path) -cne $item.Hash){$ok=$false;continue}
                try{Move-Item -LiteralPath $item.Path -Destination (Join-Path $failed ([IO.Path]::GetFileName($item.Path))) -ErrorAction Stop}
                catch{$ok=$false}
            }
        }
        if(-not(UndoMoves $moves)){$ok=$false}
        if($ok){
            if(Test-Path -LiteralPath (Join-Path $record 'INSTALLED.txt')){
                Remove-Item -LiteralPath (Join-Path $record 'INSTALLED.txt') -Force
            }
            [IO.File]::WriteAllText((Join-Path $record 'FAILED_ROLLED_BACK.txt'),$why,[Text.Encoding]::UTF8)
            throw "Installation failed; original AOTC state restored: $why"
        }
        throw "INCOMPLETE INSTALL: do not launch the game; inspect $record : $why"
    }
    Write-Host 'Parasoul production combat + character select: 13 historically altered palettes installed.' -ForegroundColor Green
    Write-Host ('Restoration record: '+$record)
    return
}
if(-not $active){throw 'No active Parasoul gameplay production ledger.'}
$m=AssertInstalled $active $build -CheckRuntime:$Runtime
if($Action -eq 'Verify'){
    Write-Host 'Production Parasoul gameplay asset hashes and restoration ledger verified.' -ForegroundColor Green
    return
}
if($Action -eq 'Rollback'){
    if(-not $ConfirmedByReset){
        $answer=Read-Host 'Type ROLLBACK to restore original 65-frame Egret payload and caches'
        if($answer -cne 'ROLLBACK'){throw 'Parasoul gameplay rollback cancelled.'}
    }
    $after=Join-Path $active 'After'
    if(Test-Path -LiteralPath $after){throw 'Rollback destination already occupied.'}
    [void](New-Item -ItemType Directory -Path $after -ErrorAction Stop)
    $moves=New-Object 'System.Collections.Generic.List[object]'
    try{
        DoMove $egretMod (Join-Path $after 'historical-parasoul.foit') $moves
        DoMove $selectLua (Join-Path $after ($selectName+'.lua')) $moves
        foreach($item in @($build.Select)){
            DoMove (Join-Path $selectDir $item.Name) (Join-Path $after $item.Name) $moves
        }
        foreach($name in @('data02','saves_CC.json')){
            $p=Join-Path $game $name
            if(Test-Path -LiteralPath $p){DoMove $p (Join-Path $after $name) $moves}
        }
        DoMove (Join-Path $active 'Before\parasoul.foit') $egretMod $moves
        if([bool]$m.hadData02){
            DoMove (Join-Path $active 'Before\data02') (Join-Path $game 'data02') $moves
        }
        if([bool]$m.hadSavesCC){
            DoMove (Join-Path $active 'Before\saves_CC.json') (Join-Path $game 'saves_CC.json') $moves
        }
        if(-not (& (Join-Path $PSScriptRoot 'Test-Existing-Restoration.ps1') -GamePath $game)){
            throw 'Original AOTC seven-section verification failed after rollback.'
        }
        [IO.File]::WriteAllText((Join-Path $active 'UNINSTALLED.txt'),(Get-Date -Format o),[Text.Encoding]::UTF8)
    }catch{
        $why=$_.Exception.Message
        if(UndoMoves $moves){throw "Rollback aborted; installed gameplay restored: $why"}
        throw "ROLLBACK INCOMPLETE. Stop and inspect $active : $why"
    }
    if(Test-Path -LiteralPath $selectDir -PathType Container){
        $remainders=@(Get-ChildItem -LiteralPath $selectDir -Force -ErrorAction Stop)
        if($remainders.Count -eq 0){
            Remove-Item -LiteralPath $selectDir -Force -ErrorAction Stop
        }
    }
    Write-Host 'Historical Parasoul gameplay removed; original Egret production restored.' -ForegroundColor Green
}
