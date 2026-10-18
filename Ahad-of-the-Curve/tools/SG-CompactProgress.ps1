function Show-AOTCStageStart {
    param([int]$Index,[int]$Total,[string]$Title)
    Write-Host ''
    Write-Host ("[{0}/{1}] {2}" -f $Index,$Total,$Title) -ForegroundColor Cyan
}
function Show-AOTCStageDone {
    Write-Host ('['+('█'*20)+']') -ForegroundColor Cyan
}
