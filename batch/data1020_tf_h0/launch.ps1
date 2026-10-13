param([ValidateSet('prepare','check','run')][string]$Stage='prepare')
$ErrorActionPreference='Stop'
$root='F:\matlab-GNSSsdr\BDS\B2a'
$out=Join-Path $root 'results\data1020\20261010_tf_h0_20s'
New-Item -ItemType Directory -Path $out -Force | Out-Null
$log=Join-Path $out ($Stage+'_console.md')
$cmd="addpath('F:/matlab-GNSSsdr/BDS/B2a/batch/data1020_tf_h0'); tf_h0_$Stage;"
$p=Start-Process -FilePath 'C:\Program Files\MATLAB\R2024b\bin\matlab.exe' -ArgumentList ('-wait -singleCompThread -logfile "'+$log+'" -batch "'+$cmd+'"') -WorkingDirectory $root -WindowStyle Hidden -PassThru
if ($Stage -ne 'run') {$p.WaitForExit();$p.Refresh();exit $p.ExitCode}
"# Launch`n`nPID: $($p.Id)`n`nLog: $log" | Set-Content -LiteralPath (Join-Path $out 'launch.md') -Encoding UTF8
while (-not(Test-Path -LiteralPath (Join-Path $out 'started.md'))) {
    if ($p.HasExited) {throw 'MATLAB exited before entry'}
    Start-Sleep -Seconds 1;$p.Refresh()
}
Get-Content -LiteralPath (Join-Path $out 'started.md') -Encoding UTF8
