param([string]$GamePath,[switch]$DryRun,[switch]$SkipBanner)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
. (Join-Path $PSScriptRoot 'SG-Banner.ps1')
. (Join-Path $PSScriptRoot 'SG-CompactProgress.ps1')
if(-not $SkipBanner){Show-SGBanner -ProjectRoot $root}
if(-not $GamePath){$GamePath=Read-Host 'Path to your Skullgirls game directory'}
$game=[IO.Path]::GetFullPath($GamePath.Trim().Trim('"')).TrimEnd('\','/')
if(-not(Test-Path -LiteralPath (Join-Path $game 'SkullGirls.exe') -PathType Leaf)){
    throw "Not a Skullgirls game directory: $game"
}
if(Get-Process -Name SkullGirls -ErrorAction SilentlyContinue){
    throw 'Close Skullgirls before resetting.'
}
$worker=Join-Path $PSScriptRoot 'Reset-AOTC-Targeted.ps1'
if($DryRun){
    $preview=& $worker -GamePath $game -DryRun 6>$null
    Write-Host ''
    Write-Host ("DRY RUN: {0} original-file or AOTC-component operations would be performed." -f $preview.Planned) -ForegroundColor Cyan
    foreach($target in @($preview.TestTargets)){
        Write-Host ('EXPERIMENTAL AOTC FILE TO ARCHIVE: '+$target) -ForegroundColor Cyan
    }
    if($preview.ExpectedOtherMods -gt 0){
        Write-Host ("Other mods left untouched: "+$preview.ExpectedOtherMods) -ForegroundColor Yellow
    }
    foreach($message in @($preview.Warnings)){
        Write-Host ('NOT RESTORABLE: '+$message) -ForegroundColor Yellow
    }
    return
}
$answer=''
while($answer -notin @('Y','N')){
    $answer=(Read-Host 'Reset AOTC changes and restore the original game files? (Y/N)').Trim().ToUpperInvariant()
    if($answer -notin @('Y','N')){Write-Host 'Enter Y or N.'}
}
if($answer -eq 'N'){
    Write-Host 'Reset cancelled. No game files changed.'
    return
}
$voiceLua=Join-Path $game 'mods\AOTC_Soviet_Historical_Test.lua'
$voiceFolder=Join-Path $game 'mods\AOTC_Soviet_Historical_Test'
$hadVoice=(Test-Path -LiteralPath $voiceLua) -or (Test-Path -LiteralPath $voiceFolder)
$result=& $worker -GamePath $game 6>$null
if($null -eq $result){throw 'Targeted reset returned no completion report.'}
$names=New-Object 'System.Collections.Generic.List[string]'
[void]$names.Add('ORIGINAL COMBO CALLOUTS')
if($hadVoice){[void]$names.Add('MIKE Z SOVIET VOICE')}
foreach($name in @('PARASOUL GAMEPLAY','FILIA','DIGITAL ART COMPENDIUM',
    'BIG BAND','DOUBLE','BEOWULF','PARASOUL STORY','BLACK EGRETS')){
    [void]$names.Add($name)
}
for($i=0;$i -lt $names.Count;$i++){
    Show-AOTCStageStart -Index ($i+1) -Total $names.Count -Title $names[$i]
    Show-AOTCStageDone
}
Write-Host ''
if($result.Complete){
    Write-Host 'VANILLA RESTORED' -ForegroundColor Green
}elseif($result.OriginalsRestored){
    Write-Host 'AOTC RESTORATIONS REMOVED — OTHER MOD FILES REMAIN' -ForegroundColor Yellow
}else{
    Write-Host 'PARTIAL RESET — SOME ORIGINAL FILES COULD NOT BE RESTORED' -ForegroundColor Yellow
    foreach($message in @($result.Warnings)){
        Write-Host ('NOT RESTORED: '+$message) -ForegroundColor Yellow
    }
}
$residual=@($result.ResidualMods)
if($residual.Count -gt 0){
    Write-Host 'ACTIVE NON-VANILLA COMPONENTS:' -ForegroundColor Yellow
    foreach($name in @($residual | Select-Object -First 12)){
        Write-Host ('  '+$name) -ForegroundColor Yellow
    }
    if($residual.Count -gt 12){
        Write-Host ("  ...and $($residual.Count-12) more. These were preserved, not removed.") -ForegroundColor Yellow
    }
}
foreach($message in @($result.Notices)){
    Write-Host ('NOTE: '+$message) -ForegroundColor Yellow
}
if($result.Backup){
    Write-Host 'Replaced originals and AOTC files were preserved under Restoration Backups.'
}
if(-not $result.OriginalsRestored){
    Write-Host 'Unrestored original assets require verified backups or Steam integrity verification.'
}
