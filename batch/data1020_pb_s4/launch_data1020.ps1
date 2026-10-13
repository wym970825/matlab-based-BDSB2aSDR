param([ValidateSet('preflight','smoke','plotcheck','main')][string]$Stage = 'preflight')
$ErrorActionPreference = 'Stop'
$matlabExe = 'C:\Program Files\MATLAB\R2024b\bin\matlab.exe'
$batchDir = 'F:\matlab-GNSSsdr\BDS\B2a\batch\data1020_pb_s4'
$outputDir = 'F:\matlab-GNSSsdr\BDS\S4repair_basedOnSDR-v2\results\data1020_pb_02_04_05_s4'
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
$logPath = Join-Path $outputDir ($Stage + '_console.md')
$statement = "addpath('F:/matlab-GNSSsdr/BDS/B2a/batch/data1020_pb_s4'); data1020_$Stage;"
$argumentText = '-wait -singleCompThread -logfile "' + $logPath + '" -batch "' + $statement + '"'
$process = Start-Process -FilePath $matlabExe -ArgumentList $argumentText -WorkingDirectory $batchDir -WindowStyle Hidden -PassThru
if ($Stage -ne 'main') {
    $process.WaitForExit()
    $process.Refresh()
    Write-Output ('Preflight exit code: ' + $process.ExitCode)
    exit $process.ExitCode
}
$record = "# Main task launch`n`nStarted: $(Get-Date -Format o)`n`nLauncher PID: $($process.Id)`n`nEntry: $batchDir\data1020_main.m`n`nMATLAB: $matlabExe`n`nLog: $logPath`n`nOrder: 02, 04, 05; one satellite at a time.`n"
$record | Set-Content -LiteralPath (Join-Path $outputDir 'launch_record.md') -Encoding UTF8
Write-Output $record
$marker = Join-Path $outputDir 'main_started.md'
while (-not (Test-Path -LiteralPath $marker)) {
    if ($process.HasExited) { throw ('MATLAB exited before main entry: ' + $process.ExitCode) }
    Start-Sleep -Seconds 1
    $process.Refresh()
}
Get-Content -LiteralPath $marker -Encoding UTF8
