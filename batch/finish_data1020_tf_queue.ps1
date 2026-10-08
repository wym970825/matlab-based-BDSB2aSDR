param([Parameter(Mandatory=$true)][int]$ReceiverProcessId)
$ErrorActionPreference = 'Stop'
$projectRoot = 'F:\matlab-GNSSsdr\BDS\B2a'
$resultRoot = Join-Path $projectRoot 'results\data1020\20261009_pb_tf_comparison'
Set-Location -LiteralPath $projectRoot
$logPath = Join-Path $resultRoot 'postprocessing_runner.log'
try {
    $receiver = Get-Process -Id $ReceiverProcessId -ErrorAction SilentlyContinue
    if ($null -ne $receiver) { Wait-Process -InputObject $receiver }
    if (-not (Test-Path -LiteralPath (Join-Path $resultRoot 'tf_full_completion.json'))) {
        throw 'Receiver queue ended without its completion record.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $resultRoot 'comparison\comparison_report.json'))) {
        throw 'Receiver queue ended before maps and comparison completed.'
    }
    & 'C:\Program Files\MATLAB\R2024b\bin\matlab.exe' -wait -singleCompThread -batch "run('F:/matlab-GNSSsdr/BDS/B2a/batch/launch_data1020_tf_finalize.m')" -logfile (Join-Path $resultRoot 'finalize_launch.log')
    if ($LASTEXITCODE -ne 0) { throw "Saved-result MATLAB finalization failed: $LASTEXITCODE" }
    & python 'batch\verify_data1020_comparison.py' (Join-Path $resultRoot 'comparison') *> $logPath
    if ($LASTEXITCODE -ne 0) { throw 'Independent comparison verification failed.' }
    & python 'batch\report_data1020_pb_tf.py' $resultRoot *>> $logPath
    if ($LASTEXITCODE -ne 0) { throw 'HTML report generation or link verification failed.' }
    & python 'batch\validate_data1020_pb_tf.py' $resultRoot *>> $logPath
    if ($LASTEXITCODE -ne 0) { throw 'Final package verification failed.' }
    @{ ok=$true; completedAtLocal=(Get-Date).ToString('o'); receiverProcessId=$ReceiverProcessId } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $resultRoot 'postprocessing_runner_result.json') -Encoding UTF8
} catch {
    @{ ok=$false; completedAtLocal=(Get-Date).ToString('o'); receiverProcessId=$ReceiverProcessId; error=$_.Exception.Message } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $resultRoot 'postprocessing_runner_result.json') -Encoding UTF8
    throw
}
