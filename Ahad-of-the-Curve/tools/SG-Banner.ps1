. (Join-Path $PSScriptRoot 'SG-UnicodeConsole.ps1')

function Show-SGBanner {
    param([Parameter(Mandatory=$true)][string]$ProjectRoot)

    $bannerPath = Join-Path $ProjectRoot 'assets\banner.txt'
    if (-not (Test-Path -LiteralPath $bannerPath -PathType Leaf)) {
        throw "Console banner is missing: $bannerPath"
    }

    Initialize-SGUnicodeConsole

    $banner = [IO.File]::ReadAllText($bannerPath, [Text.Encoding]::UTF8)
    $maxWidth = 0
    foreach ($line in @($banner.Replace([string][char]13, '').Split([char]10))) {
        $maxWidth = [Math]::Max($maxWidth, $line.TrimEnd().Length)
    }
    $requiredWidth = [Math]::Max(100, $maxWidth + 2)

    try {
        if ([Console]::BufferWidth -lt $requiredWidth) {
            [Console]::BufferWidth = $requiredWidth
        }
        if ([Console]::WindowWidth -lt $requiredWidth) {
            [Console]::WindowWidth = $requiredWidth
        }
    } catch {
        Write-Host "For correct alignment, widen this window to at least $requiredWidth columns."
    }

    Write-Host ''
    $toPrint = $banner + [Environment]::NewLine
    $nativeReady = $null -ne ([System.Management.Automation.PSTypeName]'SGConsoleNative').Type
    if (-not $nativeReady -or -not [SGConsoleNative]::WriteUnicode($toPrint)) {
        Write-Host $banner
    }
    Write-Host ''
}
