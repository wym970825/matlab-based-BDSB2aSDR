function job = start_five_semiphysical(caseIndices, outputRoot, options)
%START_FIVE_SEMIPHYSICAL Start a long run after the short MCP call returns.
% The MATLAB session must stay open. Monitor recompute_summary.csv and the
% per-case report.json/matlab.log files from another process while it runs.
    arguments
        caseIndices (1,:) double = 1:5
        outputRoot (1,1) string = ""
        options.ContinueOnFailure (1,1) logical = false
    end
    assert(~isempty(caseIndices) && all(ismember(caseIndices, 1:5)) && ...
        numel(unique(caseIndices)) == numel(caseIndices), 'Invalid case indices.');
    existing = timerfindall('Tag', 'B2aSemiphysicalRecompute');
    assert(isempty(existing), 'A semiphysical timer already exists in this MATLAB session.');
    if strlength(outputRoot) == 0
        pkg = fileparts(mfilename('fullpath'));
        manifest = jsondecode(fileread(fullfile(pkg, 'five_cases.json')));
        outputRoot = fullfile(string(manifest.defaultOutputBase), ...
            string(datetime('now', 'Format', 'yyyyMMdd_HHmmss_SSS')));
    end
    assert(~isfolder(outputRoot) && ~isfile(outputRoot), 'Output folder already exists.');
    worker = timer('Tag', 'B2aSemiphysicalRecompute', ...
        'ExecutionMode', 'singleShot', 'StartDelay', 2, ...
        'TimerFcn', @(obj, event) localRun(obj, caseIndices, outputRoot, options));
    job = struct('outputRoot', outputRoot, 'caseIndices', caseIndices, ...
        'status', 'scheduled', 'timerName', string(worker.Name));
    start(worker);
    fprintf('Scheduled five-case recompute: %s\n', outputRoot);
end

function localRun(worker, caseIndices, outputRoot, options)
    cleanup = onCleanup(@() delete(worker));
    try
        run_five_semiphysical(caseIndices, true, outputRoot, ...
            'ContinueOnFailure', options.ContinueOnFailure);
    catch ME
        if ~isfolder(outputRoot), mkdir(outputRoot); end
        fid = fopen(fullfile(outputRoot, 'launcher_error.txt'), 'w', 'n', 'UTF-8');
        if fid >= 0
            fprintf(fid, '%s\n', getReport(ME, 'extended', 'hyperlinks', 'off'));
            fclose(fid);
        end
        warning('semiphysical:AsyncRun', '%s', ME.message);
    end
end
