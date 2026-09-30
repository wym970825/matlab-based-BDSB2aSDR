% One experiment per MATLAB process; invoked by supervise_recompute.py.
root = fileparts(fileparts(fileparts(mfilename('fullpath'))));
cd(root); setupPaths;
addpath(fullfile(root, 'docs', 'semiphysical_recompute'));
caseIndex = str2double(getenv('B2A_CASE_INDEX'));
caseRoot = getenv('B2A_CASE_ROOT');
jobDir = getenv('B2A_JOB_DIR');
completionPath = getenv('B2A_COMPLETION_PATH');
try
    assert(ismember(caseIndex, 1:5) && ~isempty(caseRoot));
    c = parcluster('local');
    if ~isfolder(jobDir), mkdir(jobDir); end
    c.JobStorageLocation = jobDir;
    p = parpool(c, 4);
    assert(p.NumWorkers == 4);
    batch = run_five_semiphysical(caseIndex, true, caseRoot);
    completion = struct('finished', true, 'ok', all(batch.plan.OK == 1), ...
        'caseIndex', caseIndex, 'outputDir', batch.plan.OutputDir(1), ...
        'matlabVersion', version, 'finishedAt', char(datetime('now')));
    delete(p);
catch ME
    completion = struct('finished', true, 'ok', false, ...
        'caseIndex', caseIndex, 'errorIdentifier', ME.identifier, ...
        'error', getReport(ME, 'extended', 'hyperlinks', 'off'));
    disp(completion.error);
end
fid = fopen(completionPath, 'w', 'n', 'UTF-8');
assert(fid >= 0, 'Cannot write completion record.');
fprintf(fid, '%s\n', jsonencode(completion, 'PrettyPrint', true)); fclose(fid);
if completion.ok, exit(0); else, exit(1); end
