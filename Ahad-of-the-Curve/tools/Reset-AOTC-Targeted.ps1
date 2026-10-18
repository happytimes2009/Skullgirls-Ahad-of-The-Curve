param(
    [Parameter(Mandatory=$true)][string]$GamePath,
    [switch]$DryRun
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
$game=[IO.Path]::GetFullPath($GamePath.Trim().Trim('"')).TrimEnd('\','/')
$backupRoot=Join-Path $game 'Restoration Backups'
$job=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
$resetFolder=Join-Path $backupRoot ('Vanilla-Targeted-'+$job)
$stageFolder=Join-Path $resetFolder 'Staging'
$utf8=[Text.UTF8Encoding]::new($false)
$ops=New-Object 'System.Collections.Generic.List[object]'
$missing=New-Object 'System.Collections.Generic.List[string]'
$notices=New-Object 'System.Collections.Generic.List[string]'
$known=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$counts=[ordered]@{OriginalArchives=0;Compendium=0;AotcMods=0;LoaderCaches=0;LegacyGallery=0}
function Hash([string]$path){
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}
function Under([string]$base,[string]$relative){
    if([string]::IsNullOrWhiteSpace($relative) -or
       $relative.StartsWith('/') -or $relative.StartsWith('\') -or
       $relative.Contains(':') -or $relative.Contains([char]0)){
        throw "Unsafe reset path: $relative"
    }
    $pieces=$relative.Replace('\','/').Split('/')
    foreach($piece in $pieces){
        if(-not $piece -or $piece -eq '.' -or $piece -eq '..'){
            throw "Unsafe reset path: $relative"
        }
    }
    $parent=[IO.Path]::GetFullPath($base).TrimEnd('\','/')+'\'
    $target=[IO.Path]::GetFullPath((Join-Path $base ($relative.Replace('/','\'))))
    if(-not $target.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase)){
        throw "Reset path escaped its parent: $relative"
    }
    return $target
}
function Valid-Path([string]$path,[bool]$directory){
    $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){
        throw "Linked game files cannot be moved by reset: $path"
    }
    if($directory -and -not $item.PSIsContainer){throw "Expected folder: $path"}
    if(-not $directory -and $item.PSIsContainer){throw "Expected file: $path"}
}
function Add-Move([string]$target,[string]$relative,[string]$kind){
    $isDir=Test-Path -LiteralPath $target -PathType Container
    if(-not $isDir -and -not (Test-Path -LiteralPath $target -PathType Leaf)){return}
    Valid-Path $target $isDir
    if(-not $known.Add($target)){throw "Duplicate reset target: $target"}
    $to=Under $resetFolder ('Removed/'+$relative)
    [void]$ops.Add([pscustomobject]@{
        Mode='Move';Kind=$kind;Target=$target;From=$null;Preserved=$to;
        Staged=$null;Directory=$isDir;Size=0;Sha=$null
    })
    $counts[$kind]++
}
function Add-Restore([string]$target,[string]$source,[string]$sha,[string]$relative,[string]$kind){
    if(-not(Test-Path -LiteralPath $source -PathType Leaf)){
        [void]$missing.Add("Original backup unavailable: $relative")
        return
    }
    if((Hash $source) -cne $sha){
        [void]$missing.Add("Original backup failed checksum: $relative")
        return
    }
    $exists=Test-Path -LiteralPath $target -PathType Leaf
    if(-not $exists -and (Test-Path -LiteralPath $target)){
        [void]$missing.Add("Original target is not a file: $relative")
        return
    }
    if($exists){
        Valid-Path $target $false
        if((Hash $target) -ceq $sha){return}
    }
    if(-not $known.Add($target)){throw "Duplicate reset target: $target"}
    [void]$ops.Add([pscustomobject]@{
        Mode=$(if($exists){'Replace'}else{'Create'});Kind=$kind;Target=$target;
        From=$source;Preserved=$(if($exists){Under $resetFolder ('Changed/'+$relative)}else{$null});
        Staged=(Under $stageFolder $relative);Directory=$false;
        Size=(Get-Item -LiteralPath $source).Length;Sha=$sha
    })
    $counts[$kind]++
}
function Find-Pinned([string]$filter,[string]$relative,[string]$sha){
    if(-not(Test-Path -LiteralPath $backupRoot -PathType Container)){return $null}
    $candidates=@(Get-ChildItem -LiteralPath $backupRoot -Directory -Filter $filter -ErrorAction Stop |
        Sort-Object LastWriteTimeUtc -Descending)
    foreach($folder in $candidates){
        $candidate=Under $folder.FullName $relative
        if((Test-Path -LiteralPath $candidate -PathType Leaf) -and (Hash $candidate) -ceq $sha){
            return $candidate
        }
    }
    return $null
}
function Move-Exact([string]$from,[string]$to,[bool]$isDirectory){
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $to) -Force -ErrorAction Stop)
    if(Test-Path -LiteralPath $to){throw "Reset destination unexpectedly exists: $to"}
    if($isDirectory){[IO.Directory]::Move($from,$to)}
    else{[IO.File]::Move($from,$to)}
}
if(-not(Test-Path -LiteralPath (Join-Path $game 'SkullGirls.exe') -PathType Leaf)){
    throw 'SkullGirls.exe missing from selected game.'
}
if(Get-Process -Name SkullGirls -ErrorAction SilentlyContinue){
    throw 'Close Skullgirls before restoring original files.'
}
$filiaManifest=Get-Content -LiteralPath (Join-Path $root 'patches\filia-storyart-v1.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$archives=@(
    [pscustomobject]@{Name='ui-win.gfs';Sha='7b96719c880bf8cdf4dc3f98f15adaf26a63aacf8ced48ca7f61229951d64a6c'},
    [pscustomobject]@{Name='story_art.gfs';Sha=([string]$filiaManifest.modern.sha256).ToLowerInvariant()}
)
foreach($a in $archives){
    $target=Under $game ('data01/'+$a.Name)
    $relative='data01/'+$a.Name
    if(-not(Test-Path -LiteralPath $target -PathType Leaf)){
        [void]$missing.Add("Game archive missing: $relative")
        continue
    }
    if((Hash $target) -ceq $a.Sha){continue}
    $source=Find-Pinned 'Filia-*' $a.Name $a.Sha
    if(-not $source){
        [void]$missing.Add("Verified Filia vanilla backup not found: $relative")
        continue
    }
    Add-Restore $target $source $a.Sha $relative 'OriginalArchives'
}

$compManifest=Get-Content -LiteralPath (Join-Path $root 'patches\compendium-approved-v1.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$compRoot=Join-Path $game 'Digital Art Compendium'
if(@($compManifest.assets).Count -ne 56){throw 'Unsupported Compendium manifest.'}
if(Test-Path -LiteralPath $compRoot -PathType Container){
    foreach($item in @($compManifest.assets)){
        $rel=[string]$item.path
        $target=Under $compRoot $rel
        if([string]$item.status -ceq 'Removed'){
            if(Test-Path -LiteralPath $target -PathType Leaf){
                if((Hash $target) -ceq ([string]$item.historicalSHA256).ToLowerInvariant()){
                    Add-Move $target ('CompendiumRemoved/'+$rel) 'Compendium'
                }else{
                    [void]$missing.Add("Non-original Compendium file retained: $rel")
                }
            }
        }elseif([string]$item.status -ceq 'Modified'){
            $sha=([string]$item.currentSHA256).ToLowerInvariant()
            if((Test-Path -LiteralPath $target -PathType Leaf) -and (Hash $target) -ceq $sha){continue}
            $source=Find-Pinned 'Compendium-*' $rel $sha
            if($source){Add-Restore $target $source $sha ('Digital Art Compendium/'+$rel) 'Compendium'}
            else{[void]$missing.Add("Verified Compendium backup unavailable: $rel")}
        }else{throw "Unsupported Compendium item status: $rel"}
    }
}else{
    [void]$missing.Add('Digital Art Compendium folder is missing; artwork could not be checked.')
}
$legacyGallery=Join-Path $game 'censored art\Filia'
foreach($img in @($filiaManifest.images)){
    $name=[string]$img.name
    $target=Under $legacyGallery $name
    if(Test-Path -LiteralPath $target -PathType Leaf){
        if((Hash $target) -ceq ([string]$img.sha256).ToLowerInvariant()){
            Add-Move $target ('LegacyFiliaGallery/'+$name) 'LegacyGallery'
        }else{
            [void]$missing.Add("Changed legacy gallery image left untouched: $name")
        }
    }
}
$modNames=@(
    'AOTC_BigBand_2023','AOTC_Double_2023','AOTC_Beowulf_2023',
    'AOTC_Parasoul_Historical','AOTC_BlackEgret_Combat_Test',
    'AOTC_Parasoul_Select_Historical','AOTC_Soviet_Historical_Test',
    'AOTC_Combo_Original',
    'AOTC_Combo_Original_Test',
    'AOTC_Parasoul_1P_Red_Test',
    'AOTC_Parasoul_8P_Historical_Test',
    'AOTC_Parasoul_Palette_Test',
    'AOTC_Parasoul_Select_Historical_Test'
)
$modsDir=Join-Path $game 'mods'
foreach($name in $modNames){
    $lua=Under $modsDir ($name+'.lua')
    $folder=Under $modsDir $name
    Add-Move $lua ('AOTCMods/'+$name+'.lua') 'AotcMods'
    Add-Move $folder ('AOTCMods/'+$name) 'AotcMods'
}
$remaining=@()
if(Test-Path -LiteralPath $modsDir -PathType Container){
    $movedDirs=@($ops | Where-Object {$_.Kind -eq 'AotcMods' -and $_.Directory} |
        ForEach-Object {$_.Target})
    $movedFiles=@($ops | Where-Object {$_.Kind -eq 'AotcMods' -and -not $_.Directory} |
        ForEach-Object {$_.Target})
    $remaining=@(Get-ChildItem -LiteralPath $modsDir -File -Recurse -Force | Where-Object {
        $file=$_.FullName
        if($movedFiles -contains $file){return $false}
        foreach($dir in $movedDirs){
            if($file.StartsWith(($dir.TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)){return $false}
        }
        return $true
    })
}
$loader=Join-Path $game 'CoreMessaging.dll'
$loaderPin=(Get-Content -LiteralPath (Join-Path $root 'assets\bigband\loader-sha256.txt') -Raw -Encoding UTF8).Trim().ToLowerInvariant()
if(Test-Path -LiteralPath $loader -PathType Leaf){
    if($remaining.Count -eq 0 -and (Hash $loader) -ceq $loaderPin){
        Add-Move $loader 'AOTCMods/CoreMessaging.dll' 'AotcMods'
    }else{
        [void]$notices.Add('Shared SkullLoader DLL left in place because it may belong to other mods.')
    }
}
$needCacheRefresh=(@($ops | Where-Object {$_.Kind -ne 'LegacyGallery'}).Count -gt 0)
if($needCacheRefresh){
    if($remaining.Count -gt 0){
        [void]$notices.Add('Other mods were kept. Their generated data02 cache was archived and may rebuild at next launch.')
    }
    foreach($name in @('data02','saves_CC.json')){
        $path=Under $game $name
        Add-Move $path ('LoaderState/'+$name) 'LoaderCaches'
    }
}
function Get-ActiveOverlayFiles {
    $live=New-Object 'System.Collections.Generic.List[string]'
    if(Test-Path -LiteralPath $modsDir -PathType Container){
        foreach($file in @(Get-ChildItem -LiteralPath $modsDir -Recurse -File -Force -ErrorAction Stop)){
            [void]$live.Add(('mods/'+$file.FullName.Substring($modsDir.TrimEnd('\','/').Length+1)).Replace('\','/'))
        }
    }
    foreach($rel in @('CoreMessaging.dll','d3d9.dll','dbghelp.dll','data02','saves_CC.json')){
        if(Test-Path -LiteralPath (Join-Path $game $rel)){
            [void]$live.Add($rel)
        }
    }
    return $live.ToArray()
}
if($DryRun){
    $testTargets=@($ops | Where-Object {
        $_.Kind -eq 'AotcMods' -and $_.Target -match '_Test(?:\.lua)?$'
    } | ForEach-Object {$_.Target})
    return [pscustomobject]@{
        Complete=($missing.Count -eq 0);Planned=$ops.Count
        Warnings=$missing.ToArray();Notices=$notices.ToArray();Backup=$resetFolder;DryRun=$true
        ExpectedOtherMods=$remaining.Count;TestTargets=$testTargets
        Breakdown=$counts
    }
}
if($ops.Count -eq 0){
    $residual=@(Get-ActiveOverlayFiles)
    return [pscustomobject]@{
        Complete=($missing.Count -eq 0 -and $residual.Count -eq 0);OriginalsRestored=($missing.Count -eq 0)
        Planned=0;ResidualMods=$residual
        Warnings=$missing.ToArray();Notices=$notices.ToArray();Backup=$null;DryRun=$false
        Breakdown=$counts
    }
}
$completed=New-Object 'System.Collections.Generic.List[object]'
$staged=New-Object 'System.Collections.Generic.List[string]'
$marked=New-Object 'System.Collections.Generic.List[string]'
$committed=$false
try{
    [void](New-Item -ItemType Directory -Path $resetFolder -Force -ErrorAction Stop)
    foreach($op in $ops){
        if($op.Mode -in @('Replace','Create')){
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $op.Staged) -Force -ErrorAction Stop)
            Copy-Item -LiteralPath $op.From -Destination $op.Staged -ErrorAction Stop
            if((Hash $op.Staged) -cne $op.Sha){throw "Original file staging hash mismatch: $($op.From)"}
            [void]$staged.Add($op.Staged)
        }
    }
    if(Get-Process -Name SkullGirls -ErrorAction SilentlyContinue){throw 'Close Skullgirls before applying originals.'}
    foreach($op in $ops){
        if($op.Mode -eq 'Create'){
            if(Test-Path -LiteralPath $op.Target){throw "Game file appeared during staging: $($op.Target)"}
        }else{
            Valid-Path $op.Target $op.Directory
        }
    }
    foreach($op in $ops){
        if($op.Mode -ne 'Create'){
            Move-Exact $op.Target $op.Preserved $op.Directory
        }
        [void]$completed.Add($op)
        if($op.Mode -in @('Replace','Create')){
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $op.Target) -Force -ErrorAction Stop)
            Move-Exact $op.Staged $op.Target $false
        }
    }
    $ledgerRows=@($ops | ForEach-Object {
        [pscustomobject]@{mode=$_.Mode;category=$_.Kind;target=$_.Target;original=$_.From;preserved=$_.Preserved}
    })
    $record=Join-Path $resetFolder 'reset-record.json'
    [IO.File]::WriteAllText($record,(ConvertTo-Json -InputObject $ledgerRows -Depth 5),$utf8)
    foreach($pattern in @('AOTC-BigBand-Production-*','AOTC-Double-Production-*',
        'AOTC-Beowulf-Production-*','AOTC-Parasoul-Production-*',
        'AOTC-Egret-Production-*','AOTC-Parasoul-Gameplay-Production-*',
        'AOTC-Soviet-Production-*','AOTC-Combo-Production-*',
        'AOTC-Combo-Original-Test-*','AOTC-Soviet-Runtime-Test-*')){
        foreach($folder in @(Get-ChildItem -LiteralPath $backupRoot -Directory -Filter $pattern)){
            $ledger=Join-Path $folder.FullName 'installed-files.json'
            $state=Join-Path $folder.FullName 'state.json'
            $installed=Join-Path $folder.FullName 'INSTALLED.txt'
            if(-not(Test-Path -LiteralPath $ledger -PathType Leaf) -and
               -not(Test-Path -LiteralPath $state -PathType Leaf) -and
               -not(Test-Path -LiteralPath $installed -PathType Leaf)){continue}
            $marker=Join-Path $folder.FullName 'UNINSTALLED.txt'
            if(Test-Path -LiteralPath $marker){continue}
            [IO.File]::WriteAllText($marker,('AOTC targeted reset '+(Get-Date -Format 'o')),$utf8)
            [void]$marked.Add($marker)
        }
    }
    $committed=$true
}catch{
    $failure=$_
    foreach($m in $marked){if(Test-Path -LiteralPath $m){Remove-Item -LiteralPath $m -Force}}
    for($i=$completed.Count-1;$i -ge 0;$i--){
        $op=$completed[$i]
        try{
            if($op.Mode -in @('Replace','Create') -and (Test-Path -LiteralPath $op.Target -PathType Leaf)){
                [IO.File]::Move($op.Target,$op.Staged)
            }
            if($op.Mode -ne 'Create' -and (Test-Path -LiteralPath $op.Preserved)){
                [void](New-Item -ItemType Directory -Path (Split-Path -Parent $op.Target) -Force)
                Move-Item -LiteralPath $op.Preserved -Destination $op.Target -ErrorAction Stop
            }
        }catch{
            Write-Host "MANUAL RECOVERY NEEDED: $($op.Target) : $_" -ForegroundColor Red
        }
    }
    throw $failure
}finally{
    if($committed -and (Test-Path -LiteralPath $stageFolder -PathType Container)){
        Remove-Item -LiteralPath $stageFolder -Force -Recurse
    }
}
$residual=@(Get-ActiveOverlayFiles)
return [pscustomobject]@{
    Complete=($missing.Count -eq 0 -and $residual.Count -eq 0);OriginalsRestored=($missing.Count -eq 0)
    Planned=$ops.Count;ResidualMods=$residual
    Warnings=$missing.ToArray();Notices=$notices.ToArray();Backup=$resetFolder;DryRun=$false
    Breakdown=$counts
}
