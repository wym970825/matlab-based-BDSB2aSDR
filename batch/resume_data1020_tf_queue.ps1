param([int]$PrepareProcessId = 0)
$ErrorActionPreference = 'Stop'
$projectRoot = 'F:\matlab-GNSSsdr\BDS\B2a'
$resultRoot = Join-Path $projectRoot 'results\data1020\20261009_pb_tf_comparison'
$manifestPath = Join-Path $resultRoot 'manifest.json'
$matlabExecutable = 'C:\Program Files\MATLAB\R2024b\bin\matlab.exe'
Set-Location -LiteralPath $projectRoot
$runnerLog = Join-Path $resultRoot 'recovery_runner.log'
function Invoke-RecoveryMatlab([string]$Expression, [string]$LogName) {
    $record = @{expression=$Expression; log=$LogName; startedAtLocal=(Get-Date).ToString('o')}
    $record | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $resultRoot 'recovery_current_stage.json') -Encoding UTF8
    & $matlabExecutable -wait -singleCompThread -batch $Expression -logfile (Join-Path $resultRoot $LogName)
    if ($LASTEXITCODE -ne 0) { throw "MATLAB stage failed ($LASTEXITCODE): $Expression" }
}
try {
    if ($PrepareProcessId -gt 0) {
        $prepare = Get-Process -Id $PrepareProcessId -ErrorAction SilentlyContinue
        if ($null -ne $prepare) { Wait-Process -InputObject $prepare }
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $matlabManifest = $manifestPath.Replace('\','/')
    foreach ($index in @(5,6)) {
        $entry = $manifest.entries[$index - 1]
        $validationPath = Join-Path $entry.tfDir 'validation.json'
        if (Test-Path -LiteralPath $validationPath) {
            $existing = Get-Content -LiteralPath $validationPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($existing.pipelineOk) { continue }
        }
        $planPath = Join-Path $entry.tfDir 'recovery_plan.json'
        if (-not (Test-Path -LiteralPath $planPath)) {
            Invoke-RecoveryMatlab "cd('F:/matlab-GNSSsdr/BDS/B2a'); setupPaths; run_data1020_recovery_stage('$matlabManifest',$index,'prepare');" ("recovery_prepare_{0:D2}.log" -f $index)
        }
        $plan = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($prn in @($plan.missingPrns)) {
            Invoke-RecoveryMatlab "cd('F:/matlab-GNSSsdr/BDS/B2a'); setupPaths; run_data1020_recovery_stage('$matlabManifest',$index,'track',$prn);" ("recovery_track_{0:D2}_prn{1:D2}.log" -f $index,[int]$prn)
        }
        Invoke-RecoveryMatlab "cd('F:/matlab-GNSSsdr/BDS/B2a'); setupPaths; run_data1020_recovery_stage('$matlabManifest',$index,'finish');" ("recovery_finish_{0:D2}.log" -f $index)
    }
    $status = @()
    foreach ($entry in $manifest.entries) {
        $validation = Get-Content -LiteralPath (Join-Path $entry.tfDir 'validation.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not ($validation.pipelineOk -and $validation.allAcquiredTracked -and $validation.thresholdMatchesBaseline)) {
            throw "Experiment $($entry.experimentNumber) did not pass receiver validation."
        }
        $status += @{experimentNumber=$entry.experimentNumber; sourceId=$entry.sourceId; path=$entry.tfDir; ok=$true; acquired=$validation.nAcquired; fixes=$validation.nFixes; elapsedSeconds=$validation.elapsedSeconds}
    }
    $status | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $resultRoot 'tf_full_status.json') -Encoding UTF8
    @{indices=@(1,2,3,4,5,6); completedAtUtc=(Get-Date).ToUniversalTime().ToString('o'); recoveredAfterCrash=$true} |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $resultRoot 'tf_full_completion.json') -Encoding UTF8
    & python 'batch\record_data1020_recovery.py' $resultRoot --verify *> $runnerLog
    if ($LASTEXITCODE -ne 0) { throw 'Preserved final-file verification failed.' }
    Invoke-RecoveryMatlab "run('F:/matlab-GNSSsdr/BDS/B2a/batch/launch_data1020_recovery_postprocess.m');" 'recovery_postprocess.log'
    Invoke-RecoveryMatlab "run('F:/matlab-GNSSsdr/BDS/B2a/batch/launch_data1020_tf_finalize.m');" 'finalize_launch.log'
    & python 'batch\finalize_data1020_provenance.py' $resultRoot *>> $runnerLog
    if ($LASTEXITCODE -ne 0) { throw 'Final source provenance verification failed.' }
    & python 'batch\verify_data1020_comparison.py' (Join-Path $resultRoot 'comparison') *>> $runnerLog
    if ($LASTEXITCODE -ne 0) { throw 'Independent comparison verification failed.' }
    & python 'batch\report_data1020_pb_tf.py' $resultRoot *>> $runnerLog
    if ($LASTEXITCODE -ne 0) { throw 'Report/link verification failed.' }
    & python 'batch\validate_data1020_pb_tf.py' $resultRoot *>> $runnerLog
    if ($LASTEXITCODE -ne 0) { throw 'Final package verification failed.' }
    @{ok=$true; completedAtLocal=(Get-Date).ToString('o')} | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $resultRoot 'recovery_runner_result.json') -Encoding UTF8
} catch {
    @{ok=$false; completedAtLocal=(Get-Date).ToString('o'); error=$_.Exception.Message} | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $resultRoot 'recovery_runner_result.json') -Encoding UTF8
    throw
}
