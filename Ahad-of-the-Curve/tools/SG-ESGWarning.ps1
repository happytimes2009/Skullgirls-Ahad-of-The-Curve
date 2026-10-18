function Show-AOTCESGWarning {
    $warningLines = @(
        'WARNING: THESE MODIFICATIONS ARE NOT APPROVED BY THE ESG ADVISORY COMMITTEE.'
        'PLEASE REPORT YOURSELF FOR REEDUCATION AT ONCE'
    )
    $width = [int](($warningLines | Measure-Object -Property Length -Maximum).Maximum)
    $border = '+' + ('-' * ($width + 2)) + '+'
    Write-Host ''
    Write-Host $border -ForegroundColor Red
    foreach ($line in $warningLines) {
        Write-Host ('| ' + $line.PadRight($width) + ' |') -ForegroundColor Red
    }
    Write-Host $border -ForegroundColor Red
}