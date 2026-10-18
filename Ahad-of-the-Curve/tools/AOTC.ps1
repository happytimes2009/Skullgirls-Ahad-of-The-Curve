param([string]$GamePath,[ValidateSet('1','2','Q')][string]$MenuChoice)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
. (Join-Path $PSScriptRoot 'SG-Banner.ps1')
Show-SGBanner -ProjectRoot $root
Write-Host 'What would you like to do?' -ForegroundColor Cyan
Write-Host '  [1] Restore censored content' -ForegroundColor Cyan
Write-Host '  [2] Re-censor the game (return to vanilla)' -ForegroundColor Cyan
Write-Host '  [Q] Exit' -ForegroundColor Cyan
Write-Host ''
$choice=$MenuChoice
while($choice -notin @('1','2','Q')){
    $entered=Read-Host 'Choose 1, 2, or Q'
    if($null -eq $entered){throw 'No menu selection was received.'}
    $choice=$entered.Trim().ToUpperInvariant()
    if($choice -notin @('1','2','Q')){Write-Host 'Enter 1, 2, or Q.'}
}
if($choice -eq 'Q'){
    Write-Host 'Cancelled. No game files changed.'
    return
}
if(-not $GamePath){$GamePath=Read-Host 'Path to your Skullgirls game directory'}
if([string]::IsNullOrWhiteSpace($GamePath)){throw 'No Skullgirls game directory provided.'}
$game=[IO.Path]::GetFullPath($GamePath.Trim().Trim('"')).TrimEnd('\','/')
if(-not(Test-Path -LiteralPath (Join-Path $game 'SkullGirls.exe') -PathType Leaf)){
    throw "Not a Skullgirls game directory: $game"
}
if(Get-Process -Name SkullGirls -ErrorAction SilentlyContinue){
    throw 'Close Skullgirls before changing the game.'
}
if($choice -eq '1'){
    & (Join-Path $PSScriptRoot 'Restore-Complete-AOTC.ps1') -GamePath $game -SkipBanner
}else{
    & (Join-Path $PSScriptRoot 'Reset-Complete-AOTC.ps1') -GamePath $game -SkipBanner
}
