param(
    [string]$GamePath,
    [string]$HistoricalDepotPath,
    [switch]$InternalRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$project = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
. (Join-Path $PSScriptRoot 'SG-GfsLibrary.ps1')
. (Join-Path $PSScriptRoot 'SG-Banner.ps1')

$manifest = Get-Content -LiteralPath (Join-Path $project 'patches\filia-storyart-v1.json') -Raw | ConvertFrom-Json
$targetUI = 'ui/Win/CutsceneCommon.gbs'
$oldUI = 'temp/UI/Win/CutsceneCommon.gbs'
$viewName = 'Filia_Legacy_Intro'

function Little-U32([byte[]]$data,[int]$offset) {
    if ($offset -lt 0 -or $offset + 4 -gt $data.Length) { throw 'GBS integer outside bounds.' }
    return [BitConverter]::ToUInt32($data,$offset)
}
function Put-Little-U32([byte[]]$data,[int]$offset,[uint32]$value) {
    [Array]::Copy([BitConverter]::GetBytes($value),0,$data,$offset,4)
}
function Get-FiliaView([byte[]]$gbs) {
    if ($gbs.Length -lt 128 -or
        [Text.Encoding]::ASCII.GetString($gbs,0,4) -cne 'CSGG' -or
        (Little-U32 $gbs 4) -ne $gbs.Length) {
        throw 'Unsupported GBS top-level structure or size.'
    }
    $text = [Text.Encoding]::GetEncoding(28591).GetString($gbs)
    $nameAt = $text.IndexOf($viewName,[StringComparison]::Ordinal)
    if ($nameAt -lt 12 -or $text.IndexOf($viewName,$nameAt+1,[StringComparison]::Ordinal) -ge 0) {
        throw 'Filia legacy scene name missing or ambiguous.'
    }
    $start = $nameAt - 12
    $length = Little-U32 $gbs ($start+4)
    if ($start + $length -gt $gbs.Length -or $length -lt 20000 -or $length -gt 80000 -or
        [Text.Encoding]::ASCII.GetString($gbs,$start,4) -cne 'WVGG') {
        throw 'Unsupported Filia WVGG scene record.'
    }
    $bytes = New-Object byte[] ([int]$length)
    [Array]::Copy($gbs,$start,$bytes,0,[int]$length)
    return [pscustomobject]@{Offset=$start;Length=[int]$length;Bytes=$bytes}
}
function Check-ViewCompatibility([byte[]]$historical,[byte[]]$modern) {
    if ($historical.Length -lt 4128 -or $modern.Length -lt 4128) {
        throw 'Filia view preamble truncated.'
    }
    foreach ($view in @($historical,$modern)) {
        if ([Text.Encoding]::ASCII.GetString($view,0,4) -cne 'WVGG' -or
            [Text.Encoding]::ASCII.GetString($view,2132,4) -cne 'LAGG') {
            throw 'Filia view or animation section tag is incorrect.'
        }
        if ((Little-U32 $view 4) -ne $view.Length -or
            (Little-U32 $view 2136) -ne ($view.Length - 2132)) {
            throw 'Filia WVGG or LAGG section length is inconsistent.'
        }
    }
    $delta = $historical.Length - $modern.Length
    if ($delta -ne 96 -or
        ((Little-U32 $historical 2136) - (Little-U32 $modern 2136)) -ne $delta) {
        throw 'Filia historical animation length difference is unsupported.'
    }
    for ($i=0; $i -lt 4128; $i++) {
        if (($i -ge 4 -and $i -lt 8) -or ($i -ge 2136 -and $i -lt 2140)) { continue }
        if ($historical[$i] -ne $modern[$i]) {
            throw "Filia's sprite definitions or UI layout changed at offset $i; refusing historical transplant."
        }
    }
}
function New-SceneWith2023View([byte[]]$modern,[byte[]]$historicalView,[object]$modernView) {
    [long]$delta = $historicalView.Length - $modernView.Length
    if ($delta -lt -100000 -or $delta -gt 100000) { throw 'Unexpected scene size change.' }
    $newLength = $modern.Length + $delta
    if ($newLength -lt 10000 -or $newLength -gt [int]::MaxValue) { throw 'GBS would be invalidly sized.' }
    $result = New-Object byte[] ([int]$newLength)
    [Array]::Copy($modern,0,$result,0,$modernView.Offset)
    [Array]::Copy($historicalView,0,$result,$modernView.Offset,$historicalView.Length)
    $remaining = $modern.Length - $modernView.Offset - $modernView.Length
    [Array]::Copy($modern,$modernView.Offset+$modernView.Length,$result,
        $modernView.Offset+$historicalView.Length,$remaining)

    $oldMessages = Little-U32 $modern 52
    Put-Little-U32 $result 4 ([uint32]$newLength)
    Put-Little-U32 $result 52 ([uint32]($oldMessages+$delta))
    if ((Little-U32 $result 4) -ne $result.Length) { throw 'New GBS length verification failed.' }
    if ([BitConverter]::ToUInt32($result,$result.Length-4) -ne 0x12344321) {
        throw 'GBS end marker is missing.'
    }
    $newView = Get-FiliaView $result
    if ($newView.Length -ne $historicalView.Length -or
        (Get-SGByteHash $newView.Bytes) -ne (Get-SGByteHash $historicalView)) {
        throw 'Historical Filia view did not survive scene assembly.'
    }

    $views = Little-U32 $result 28
    if ($views -lt 1 -or $views -gt 200) { throw 'GBS has invalid view count.' }
    [long]$start = 56 + (Little-U32 $result 48)
    [long]$end = 56 + (Little-U32 $result 52)
    for ($i=0; $i -lt $views; $i++) {
        if ($start + 12 -gt $result.Length -or
            [Text.Encoding]::ASCII.GetString($result,[int]$start,4) -cne 'WVGG') {
            throw "Unexpected GBS view record $i after transplant."
        }
        $viewLength = Little-U32 $result ([int]$start+4)
        if ($viewLength -lt 100 -or $start+$viewLength -gt $end) {
            throw "GBS view $i has an invalid size."
        }
        $start += $viewLength
    }
    if ($start -ne $end) { throw 'GBS views no longer end at message section.' }
    return ,$result
}
function Get-GfsStructure([string]$path) {
    $fs = [IO.File]::OpenRead($path)
    $r = New-Object System.IO.BinaryReader($fs)
    try {
        [long]$dataStart = Read-SGUInt32 $r
        $id = Read-SGText $r
        $version = Read-SGText $r
        [long]$count = Read-SGUInt64 $r
        if ($id -ne 'Reverge Package File' -or $version -ne '1.1' -or
            $count -lt 1 -or $count -gt 500000 -or $dataStart -gt $fs.Length) {
            throw 'Unsupported GFS archive structure.'
        }
        $entries = New-Object 'System.Collections.Generic.List[object]'
        [long]$offset = $dataStart
        for ([long]$i=0; $i -lt $count; $i++) {
            $name = Read-SGText $r
            [long]$sizeField = $fs.Position
            [long]$size = Read-SGUInt64 $r
            [long]$align = Read-SGUInt32 $r
            if ($align -lt 1 -or $align -gt 1048576) { throw "Invalid alignment for $name" }
            $offset += ($align - ($offset % $align)) % $align
            if ($size -lt 0 -or $offset -gt $fs.Length -or $size -gt ($fs.Length-$offset)) {
                throw "GFS entry out of bounds: $name"
            }
            $entries.Add([pscustomobject]@{
                Name=$name;Offset=$offset;Size=$size;Alignment=$align;SizeField=$sizeField
            })
            $offset += $size
        }
        if ($fs.Position -gt $dataStart) { throw 'GFS index overlaps the data section.' }
        return [pscustomobject]@{
            DataStart=$dataStart;Entries=$entries.ToArray();End=$offset;Length=$fs.Length
        }
    } finally { $r.Dispose(); $fs.Dispose() }
}
function Copy-Range([IO.FileStream]$source,[IO.FileStream]$dest,[long]$offset,[long]$length) {
    [void]$source.Seek($offset,[IO.SeekOrigin]::Begin)
    $buffer = New-Object byte[] (1024*1024)
    while ($length -gt 0) {
        $n = [int][Math]::Min([long]$buffer.Length,$length)
        $got = $source.Read($buffer,0,$n)
        if ($got -le 0) { throw 'Unexpected EOF copying GFS content.' }
        $dest.Write($buffer,0,$got)
        $length -= $got
    }
}
function Write-Big-U64([IO.FileStream]$stream,[long]$field,[long]$value) {
    [byte[]]$bytes=[BitConverter]::GetBytes([uint64]$value)
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($bytes) }
    [void]$stream.Seek($field,[IO.SeekOrigin]::Begin)
    $stream.Write($bytes,0,8)
}
function Rebuild-GfsWithReplacement(
    [string]$sourcePath,[string]$outputPath,[string]$entryPath,[byte[]]$replacement
) {
    $index=Get-GfsStructure $sourcePath
    $targets=@($index.Entries | Where-Object { $_.Name -ceq $entryPath })
    if ($targets.Count -ne 1) { throw "Missing or ambiguous GFS entry: $entryPath" }
    $target=$targets[0]
    $source=[IO.File]::OpenRead($sourcePath)
    $out=[IO.File]::Open($outputPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        Copy-Range $source $out 0 $index.DataStart
        Write-Big-U64 $out $target.SizeField $replacement.Length
        [void]$out.Seek($index.DataStart,[IO.SeekOrigin]::Begin)
        foreach($entry in $index.Entries) {
            [long]$alignment = $entry.Alignment
            [long]$padding = ($alignment - ($out.Position % $alignment)) % $alignment
            if ($padding -gt 0) { $out.Write((New-Object byte[] ([int]$padding)),0,[int]$padding) }
            if ($entry.Name -ceq $entryPath) {
                $out.Write($replacement,0,$replacement.Length)
            } else {
                Copy-Range $source $out $entry.Offset $entry.Size
            }
        }
        if ($index.Length -gt $index.End) {
            Copy-Range $source $out $index.End ($index.Length-$index.End)
        }
        $out.Flush()
    } finally { $out.Dispose(); $source.Dispose() }

    $newIndex=Get-GfsStructure $outputPath
    if ($newIndex.Entries.Count -ne $index.Entries.Count) {
        throw 'Archive entry count changed during rebuild.'
    }
    for ($i=0; $i -lt $index.Entries.Count; $i++) {
        if ($newIndex.Entries[$i].Name -cne $index.Entries[$i].Name) {
            throw 'Archive entry order changed during rebuild.'
        }
        $expected=if ($index.Entries[$i].Name -ceq $entryPath) {
            $replacement.Length
        } else { $index.Entries[$i].Size }
        if ($newIndex.Entries[$i].Size -ne $expected) {
            throw 'Archive entry size mismatch after rebuild.'
        }
    }
    $verify=Get-SGIndex $outputPath
    $stream=[IO.File]::OpenRead($outputPath)
    try {
        [byte[]]$actual=Read-SGEntry $stream $verify[$entryPath]
    } finally { $stream.Dispose() }
    if ((Get-SGByteHash $actual) -ne (Get-SGByteHash $replacement)) {
        throw 'GBS asset failed verification after repacking the archive.'
    }
}
function Read-GfsAsset([string]$archive,[string]$name) {
    $idx=Get-SGIndex $archive
    if (-not $idx.ContainsKey($name)) { throw "Missing $name in $archive" }
    $fs=[IO.File]::OpenRead($archive)
    try { return ,(Read-SGEntry $fs $idx[$name]) }
    finally { $fs.Dispose() }
}
function Get-HistoricalGbs {
    $bundled=Join-Path $project 'assets\game\filia\cutscene\april-2023\CutsceneCommon.gbs'
    if (-not (Test-Path -LiteralPath $bundled -PathType Leaf)) {
        throw "Missing bundled 2023 cutscene file: $bundled. Rebuild the portable ZIP."
    }
    return ,([IO.File]::ReadAllBytes($bundled))
}
function Get-HistoricalTexture([object]$img) {
    $bundled=Join-Path (Join-Path $project 'assets\game\filia\story-art\april-2023') ([string]$img.name)
    if (-not (Test-Path -LiteralPath $bundled -PathType Leaf)) {
        throw "Missing bundled original art: $($img.name). Rebuild the portable ZIP."
    }
    return ,([IO.File]::ReadAllBytes($bundled))
}

if (-not $InternalRun) { Show-SGBanner -ProjectRoot $project }
if (-not $GamePath) { $GamePath = Read-Host 'Path to your CURRENT Skullgirls game directory' }
$GamePath=[IO.Path]::GetFullPath($GamePath.Trim().Trim('"')).TrimEnd('\','/')
if (-not (Test-Path -LiteralPath (Join-Path $GamePath 'SkullGirls.exe') -PathType Leaf)) {
    throw 'Invalid Skullgirls directory. SkullGirls.exe was not found.'
}
if (Get-Process -Name SkullGirls -ErrorAction SilentlyContinue) {
    throw 'Close Skullgirls before running this installer.'
}
$sourceSnapshots = @{}
foreach ($checkPath in @(
    (Join-Path $GamePath 'data01\ui-win.gfs'),
    (Join-Path $GamePath 'data01\story_art.gfs')
)) {
    if (Test-Path -LiteralPath $checkPath -PathType Leaf) {
        $info=Get-Item -LiteralPath $checkPath
        $sourceSnapshots[$checkPath] = [pscustomobject]@{
            Length=$info.Length
            Modified=$info.LastWriteTimeUtc
        }
    }
}

[byte[]]$oldGbs=Get-HistoricalGbs
$oldView=Get-FiliaView $oldGbs
$uiArchive=Join-Path $GamePath 'data01\ui-win.gfs'
$storyArchive=Join-Path $GamePath 'data01\story_art.gfs'
if (-not (Test-Path -LiteralPath $uiArchive -PathType Leaf) -or
    -not (Test-Path -LiteralPath $storyArchive -PathType Leaf)) {
    throw 'Modern GFS file structure not found. Nothing changed.'
}
[byte[]]$currentGbs=Read-GfsAsset $uiArchive $targetUI
$modernView=Get-FiliaView $currentGbs
$viewInstalled=(Get-SGByteHash $oldView.Bytes) -eq (Get-SGByteHash $modernView.Bytes)
$newGbs=$null
if ($viewInstalled) {
} else {
    Check-ViewCompatibility $oldView.Bytes $modernView.Bytes
    [byte[]]$newGbs=New-SceneWith2023View $currentGbs $oldView.Bytes $modernView
}

$storyIndex=Get-SGIndex $storyArchive
$textures=@{}
$missing=New-Object 'System.Collections.Generic.List[object]'
foreach($img in @($manifest.images | Where-Object { $_.to })) {
    $path=[string]$img.to
    if (-not $storyIndex.ContainsKey($path)) { throw "Unsupported modern texture path $path" }
    $entry=$storyIndex[$path]
    if ($entry.Size -ne [long]$img.size) { throw "Unexpected modern image length: $path" }
    [byte[]]$src=Get-HistoricalTexture $img
    if ($src.Length -ne [long]$img.size -or (Get-SGByteHash $src) -ne [string]$img.sha256 -or
        [Text.Encoding]::ASCII.GetString($src,0,4) -cne 'DDS ') {
        throw "Historical source texture failed size, DDS or SHA-256 check: $($img.name)"
    }
    $textures[$path]=$src
    $stream=[IO.File]::OpenRead($storyArchive)
    try { [byte[]]$installed=Read-SGEntry $stream $entry }
    finally { $stream.Dispose() }
    $installedHash=Get-SGByteHash $installed
    if ($installedHash -eq [string]$img.sha256) {
    } elseif ($installedHash -eq [string]$img.expectedCurrentSha256) {
        $missing.Add($img)
    } else {
        throw "Unexpected current texture data: $path. Refusing to overwrite unknown changes."
    }
}
$modifyUI= -not $viewInstalled
$modifyTextures= $missing.Count -gt 0
if (-not $modifyUI -and -not $modifyTextures) {
    if (-not $InternalRun) {
        Write-Host ''
        Write-Host 'Restoration complete. Original Filia artwork and cutscene are already installed.' -ForegroundColor Green
    }
    return
}

$job=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)
$stage=Join-Path $GamePath ('.filia-2023-stage-'+$job)
$backup=Join-Path $GamePath ('Restoration Backups\Filia-2023-Scene-'+$job)
$changeList=New-Object 'System.Collections.Generic.List[object]'
try {
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    if ($modifyUI) {
        $staged=Join-Path $stage 'ui-win.gfs'
        Rebuild-GfsWithReplacement $uiArchive $staged $targetUI $newGbs
        $changeList.Add([pscustomobject]@{Original=$uiArchive;Stage=$staged;Backup=(Join-Path $backup 'ui-win.gfs')})
    }
    if ($modifyTextures) {
        $staged=Join-Path $stage 'story_art.gfs'
        Copy-Item -LiteralPath $storyArchive -Destination $staged -ErrorAction Stop
        $stagedIndex=Get-SGIndex $staged
        $fs=[IO.File]::Open($staged,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try {
            foreach($img in $missing) {
                $entry=$stagedIndex[[string]$img.to]
                [byte[]]$bytes=$textures[[string]$img.to]
                [void]$fs.Seek([long]$entry.Offset,[IO.SeekOrigin]::Begin)
                $fs.Write($bytes,0,$bytes.Length)
            }
            $fs.Flush()
            foreach($img in $missing) {
                [byte[]]$installed=Read-SGEntry $fs $stagedIndex[[string]$img.to]
                if ((Get-SGByteHash $installed) -ne [string]$img.sha256) {
                    throw "Staged texture verification failed: $($img.name)"
                }
            }
        } finally { $fs.Dispose() }
        $changeList.Add([pscustomobject]@{Original=$storyArchive;Stage=$staged;Backup=(Join-Path $backup 'story_art.gfs')})
    }

    if (Get-Process -Name SkullGirls -ErrorAction SilentlyContinue) {
        throw 'Close Skullgirls before installing.'
    }

    foreach($file in $changeList) {
        if (-not (Test-Path -LiteralPath $file.Original -PathType Leaf)) {
            throw 'A source archive disappeared during staging.'
        }
        $info=Get-Item -LiteralPath $file.Original
        $before=$sourceSnapshots[$file.Original]
        if ($null -eq $before -or $info.Length -ne $before.Length -or
            $info.LastWriteTimeUtc -ne $before.Modified) {
            throw 'A game archive changed while staging. Nothing was installed.'
        }
    }

    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    $swapped=New-Object 'System.Collections.Generic.List[object]'
    try {
        foreach($file in $changeList) {
            [IO.File]::Move($file.Original,$file.Backup)
            $swapped.Add($file)
            [IO.File]::Move($file.Stage,$file.Original)
        }
    } catch {
        foreach($file in @($swapped | Sort-Object Original -Descending)) {
            if (Test-Path -LiteralPath $file.Original) { Remove-Item -LiteralPath $file.Original -Force }
            if (Test-Path -LiteralPath $file.Backup) { [IO.File]::Move($file.Backup,$file.Original) }
        }
        throw
    }
    if (-not $InternalRun) {
        Write-Host ''
        Write-Host 'Restoration complete.' -ForegroundColor Green
        Write-Host 'The original 2023 Filia cutscene and images are installed.'
        Write-Host "Backup: $backup"
    }
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
