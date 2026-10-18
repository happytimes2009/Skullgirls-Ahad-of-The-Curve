. (Join-Path $PSScriptRoot 'SG-GfsLibrary.ps1')

function Get-AOTCPaletteManifest {
    param([string]$Root)
    $file=Join-Path $Root 'patches\parasoul-original-palettes-v1.gz.b64'
    if(-not(Test-Path -LiteralPath $file -PathType Leaf)){throw "Incomplete release: $file"}
    $raw=(Get-Content -LiteralPath $file -Raw -Encoding ASCII).Trim()
    if($raw -notmatch '^[A-Za-z0-9+/=]+$'){throw 'Invalid bundled palette patch encoding.'}
    [byte[]]$packed=[Convert]::FromBase64String($raw)
    $inputStream=[IO.MemoryStream]::new($packed)
    $zip=[IO.Compression.GZipStream]::new($inputStream,[IO.Compression.CompressionMode]::Decompress)
    $reader=[IO.StreamReader]::new($zip,[Text.Encoding]::UTF8)
    try {
        $json=$reader.ReadToEnd()
    }finally{$reader.Dispose();$zip.Dispose();$inputStream.Dispose()}
    $m=ConvertFrom-Json -InputObject $json
    $numbers=@(4,6,8,9,11,12,13,16,22,24,25,27,28)
    if([string]$m.id -cne 'aotc-parasoul-original-armbands-v1' -or
       [int]$m.schema -ne 1 -or
       @($m.palettes).Count -ne 13 -or
       [string]$m.baselineEgretFoitSha256 -cne 'd8b4fb3cd9ed199a2e3b13a643b00139caf409f05eae07ddfe2c5a18f37d2b36' -or
       (@($m.palettes | ForEach-Object {[int]$_.number}) -join ',') -cne ($numbers -join ',')){
        throw 'Unexpected historical palette patch package.'
    }
    return $m
}
function Convert-AOTCHex([string]$value,[int]$length){
    if($value.Length -ne ($length*2) -or $value -cnotmatch '^[0-9a-f]+$'){
        throw 'Corrupt historical color swatch data.'
    }
    [byte[]]$bytes=[byte[]]::new($length)
    for($i=0;$i -lt $length;$i++){
        $bytes[$i]=[Convert]::ToByte($value.Substring(2*$i,2),16)
    }
    return ,$bytes
}
function Get-AOTCGfsEntry([string]$archive,[string]$key){
    $index=Get-SGIndex $archive
    if(-not $index.ContainsKey($key)){throw "Unsupported archive: $key"}
    $stream=[IO.File]::OpenRead($archive)
    try{return ,(Read-SGEntry $stream $index[$key])}
    finally{$stream.Dispose()}
}
function Get-AOTCCombinedPalettes {
    param([string]$Root,[string]$GamePath)
    $m=Get-AOTCPaletteManifest $Root
    $src=Join-Path $Root 'assets\egret\parasoul.foit'
    $expected=[string]$m.baselineEgretFoitSha256
    if(-not(Test-Path -LiteralPath $src -PathType Leaf) -or
       (Get-SGHash $src) -cne $expected){throw 'Bundled 65-frame Egret FOIT missing/mismatched.'}
    [byte[]]$original=[IO.File]::ReadAllBytes($src)
    if($original.Length -ne 2740790){throw 'Unsupported Egret FOIT size.'}
    [byte[]]$newFoit=[byte[]]$original.Clone()
    $sprites=Join-Path $GamePath 'data01\sprites.gfs'
    if(-not(Test-Path -LiteralPath $sprites -PathType Leaf)){
        throw 'Vanilla data01/sprites.gfs not found.'
    }
    $assets=New-Object 'System.Collections.Generic.List[object]'
    $total=0
    foreach($p in @($m.palettes)){
        $n=[int]$p.number
        $offset=[int]$p.foitOffset
        $targetOffset=14404+($n-1)*988+544
        if($n -ge 26){$targetOffset+=39}
        if($offset -ne $targetOffset -or $offset+72 -gt $newFoit.Length){
            throw "Unsupported FOIT palette offset for $n P."
        }
        [byte[]]$before=Convert-AOTCHex ([string]$p.expectedFoItControlsHex) 72
        [byte[]]$after=Convert-AOTCHex ([string]$p.historicalFoItControlsHex) 72
        for($i=0;$i -lt 72;$i++){
            if($original[$offset+$i] -ne $before[$i]){throw "Unknown Egret FOIT $n P colors."}
            if(($i%4) -eq 3 -and $before[$i] -ne $after[$i]){
                throw "Historical palette would change transparency: $n P."
            }
            if($before[$i] -ne $after[$i]){$total++}
        }
        [Array]::Copy($after,0,$newFoit,$offset,72)
        [byte[]]$dds=Get-AOTCGfsEntry $sprites ("sprites/parasoul_$($n)p.dds")
        $modernHash=([string]$p.modernDDSsha256).ToLowerInvariant()
        if($dds.Length -ne 3136 -or (Get-SGByteHash $dds) -cne $modernHash){
            throw "Unsupported modern select palette $n P."
        }
        if([Text.Encoding]::ASCII.GetString($dds,0,4) -cne 'DDS ' -or
           [BitConverter]::ToUInt32($dds,12) -ne 47 -or
           [BitConverter]::ToUInt32($dds,16) -ne 16){
            throw "Unexpected select DDS dimensions for $n P."
        }
        [byte[]]$newDDS=[byte[]]$dds.Clone()
        [byte[]]$rows=Convert-AOTCHex ([string]$p.historicalDDSRowsHex) 192
        for($row=0;$row -lt 3;$row++){
            [Array]::Copy($rows,$row*64,$newDDS,128+(26+$row)*64,64)
        }
        $restoreHash=([string]$p.restoredDDSsha256).ToLowerInvariant()
        if((Get-SGByteHash $newDDS) -cne $restoreHash){
            throw "Restored select DDS hash mismatch: $n P."
        }
        $assets.Add([pscustomobject]@{
            Number=$n;Name=("parasoul_$($n)p.dds");
            Hash=$restoreHash;Bytes=$newDDS;Length=3136
        })
    }
    if($total -ne 374 -or $assets.Count -ne 13){
        throw "Historical FOIT patch scope differs: $total RGB bytes."
    }
    return [pscustomobject]@{
        FoitBytes=$newFoit;FoitHash=(Get-SGByteHash $newFoit);
        FoitLength=$newFoit.Length;Select=@($assets.ToArray());
        SourceFoitHash=$expected
    }
}
