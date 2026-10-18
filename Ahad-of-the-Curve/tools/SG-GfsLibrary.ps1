function Get-SGHash([string]$path) {
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Get-SGByteHash([byte[]]$bytes) {
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hasher.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
}
function Read-SGUInt32([IO.BinaryReader]$r) {
    $bytes = $r.ReadBytes(4)
    if ($bytes.Length -ne 4) { throw 'Truncated GFS integer.' }
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($bytes) }
    return [BitConverter]::ToUInt32($bytes,0)
}
function Read-SGUInt64([IO.BinaryReader]$r) {
    $bytes = $r.ReadBytes(8)
    if ($bytes.Length -ne 8) { throw 'Truncated GFS integer.' }
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($bytes) }
    [uint64]$n = [BitConverter]::ToUInt64($bytes,0)
    if ($n -gt [long]::MaxValue) { throw 'Invalid GFS integer.' }
    return [long]$n
}
function Read-SGText([IO.BinaryReader]$r) {
    [long]$n = Read-SGUInt64 $r
    if ($n -gt 16384) { throw 'Invalid GFS string length.' }
    $bytes = $r.ReadBytes([int]$n)
    if ($bytes.Length -ne $n) { throw 'Truncated GFS text.' }
    return [Text.Encoding]::UTF8.GetString($bytes)
}
function Get-SGIndex([string]$archive) {
    $fs = [IO.File]::OpenRead($archive)
    $r = New-Object System.IO.BinaryReader($fs)
    try {
        [long]$dataOffset = Read-SGUInt32 $r
        $identifier = Read-SGText $r
        $version = Read-SGText $r
        [long]$count = Read-SGUInt64 $r
        if ($identifier -ne 'Reverge Package File' -or $version -ne '1.1') {
            throw "Unsupported GFS format: $archive"
        }
        if ($count -lt 1 -or $count -gt 500000 -or $dataOffset -gt $fs.Length) { throw 'Invalid GFS header.' }
        $index = @{}
        [long]$offset = $dataOffset
        for ([long]$i = 0; $i -lt $count; $i++) {
            $path = Read-SGText $r
            [long]$size = Read-SGUInt64 $r
            [long]$align = Read-SGUInt32 $r
            if (-not $path -or $index.ContainsKey($path)) { throw "Duplicate/blank GFS path: $path" }
            if ($align -lt 1 -or $align -gt 1048576) { throw "Invalid alignment: $path" }
            $offset += ($align - ($offset % $align)) % $align
            if ($offset -gt $fs.Length -or $size -gt ($fs.Length - $offset)) { throw "Invalid GFS bounds: $path" }
            $index.Add($path, [pscustomobject]@{ Offset=$offset; Size=$size })
            $offset += $size
        }
        if ($r.BaseStream.Position -gt $dataOffset) { throw 'GFS file list overlaps data.' }
        return ,$index
    } finally { $r.Dispose(); $fs.Dispose() }
}
function Read-SGEntry([IO.FileStream]$stream,[object]$entry) {
    if ($entry.Size -gt 10000000) { throw 'Unexpectedly large individual art entry.' }
    $bytes = New-Object byte[] ([int]$entry.Size)
    [void]$stream.Seek([long]$entry.Offset,[IO.SeekOrigin]::Begin)
    $read = 0
    while ($read -lt $bytes.Length) {
        $n = $stream.Read($bytes,$read,$bytes.Length-$read)
        if ($n -le 0) { throw 'Unexpected end of GFS entry.' }
        $read += $n
    }
    return ,$bytes
}
function Find-SGHistory([string]$folder) {
    if (-not $folder) { return $null }
    $path = Join-Path $folder 'data01\ui-storyart.gfs'
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    return $null
}
