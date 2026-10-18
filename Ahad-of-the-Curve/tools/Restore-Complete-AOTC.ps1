param([string]$GamePath,[switch]$SkipBanner)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
. (Join-Path $PSScriptRoot 'SG-Banner.ps1')
. (Join-Path $PSScriptRoot 'SG-CompactProgress.ps1')
. (Join-Path $PSScriptRoot 'SG-ESGWarning.ps1')
if(-not $SkipBanner){Show-SGBanner -ProjectRoot $root}
if(-not $GamePath){$GamePath=Read-Host 'Path to your Skullgirls game directory'}
$game=[IO.Path]::GetFullPath($GamePath.Trim().Trim('"')).TrimEnd('\','/')
if(-not(Test-Path -LiteralPath (Join-Path $game 'SkullGirls.exe') -PathType Leaf)){
    throw "Not a Skullgirls game directory: $game"
}
if(Get-Process -Name SkullGirls -ErrorAction SilentlyContinue){throw 'Close Skullgirls first.'}
$choice=''
while($choice -notin @('Y','N')){
    $choice=(Read-Host "Would you like to restore Mike Z's Soviet voice? (Y/N)").Trim().ToUpperInvariant()
    if($choice -notin @('Y','N')){Write-Host 'Enter Y or N.'}
}
$restoreSoviet=$choice -eq 'Y'
$total=if($restoreSoviet){10}else{9}
$soviet=Join-Path $PSScriptRoot 'Install-Soviet-Voice.ps1'
$palette=Join-Path $PSScriptRoot 'Install-Parasoul-Gameplay.ps1'
$combo=Join-Path $PSScriptRoot 'Install-Combo-Callouts.ps1'
& (Join-Path $PSScriptRoot 'Verify-Production-Payload.ps1') 6>$null | Out-Null
if($restoreSoviet){& $soviet -Action Preflight -GamePath $game 6>$null | Out-Null}
$active=@()
$backups=Join-Path $game 'Restoration Backups'
if(Test-Path -LiteralPath $backups -PathType Container){
    $active=@(Get-ChildItem -LiteralPath $backups -Directory -Filter 'AOTC-Parasoul-Gameplay-Production-*' |
        Where-Object{
            (Test-Path -LiteralPath (Join-Path $_.FullName 'INSTALLED.txt')) -and
            -not(Test-Path -LiteralPath (Join-Path $_.FullName 'UNINSTALLED.txt'))
        })
}
if($active.Count -gt 1){throw 'More than one active Parasoul production ledger.'}
if($active.Count -eq 1){
    & $palette -Action Verify -GamePath $game 6>$null | Out-Null
    $titles=@('FILIA','DIGITAL ART COMPENDIUM','BIG BAND','DOUBLE','BEOWULF','PARASOUL STORY','BLACK EGRETS')
    for($i=0;$i -lt $titles.Count;$i++){
        Show-AOTCStageStart -Index ($i+1) -Total $total -Title $titles[$i]
        Show-AOTCStageDone
    }
    Show-AOTCStageStart -Index 8 -Total $total -Title 'PARASOUL GAMEPLAY'
    Show-AOTCStageDone
}else{
    & $palette -Action Preflight -GamePath $game 6>$null | Out-Null
    & (Join-Path $PSScriptRoot 'Restore-AOTC.ps1') -GamePath $game -SkipBanner -CompactProgress -TotalStages $total
    Show-AOTCStageStart -Index 8 -Total $total -Title 'PARASOUL GAMEPLAY'
    & $palette -Action Install -GamePath $game 6>$null | Out-Null
    & $palette -Action Verify -GamePath $game 6>$null | Out-Null
    Show-AOTCStageDone
}
if($restoreSoviet){
    Show-AOTCStageStart -Index 9 -Total $total -Title 'MIKE Z SOVIET VOICE'
    & $soviet -Action Install -GamePath $game 6>$null | Out-Null
    & $soviet -Action Verify -GamePath $game 6>$null | Out-Null
    Show-AOTCStageDone
}
$comboStage=if($restoreSoviet){10}else{9}
Show-AOTCStageStart -Index $comboStage -Total $total -Title 'ORIGINAL COMBO CALLOUTS'
& $combo -Action Install -GamePath $game 6>$null | Out-Null
& $combo -Action Verify -GamePath $game 6>$null | Out-Null
Show-AOTCStageDone
Write-Host ''
Write-Host 'RESTORATION COMPLETE' -ForegroundColor Green
Write-Host ''
Show-AOTCESGWarning
