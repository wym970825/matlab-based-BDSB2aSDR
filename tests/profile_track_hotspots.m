function rankT = profile_track_hotspots(varargin)
%PROFILE_TRACK_HOTSPOTS Short single-SV track under profiler for MEX ROI.
%
%   rankT = profile_track_hotspots()
%   rankT = profile_track_hotspots('msToProcess', 8000, 'acqSatelliteList', 41)

    setupPaths();
    p = inputParser;
    addParameter(p, 'msToProcess', 8000);
    addParameter(p, 'acqSatelliteList', 41);
    addParameter(p, 'outDir', '');
    parse(p, varargin{:});

    settings = initSettings( ...
        'msToProcess', p.Results.msToProcess, ...
        'acqSatelliteList', p.Results.acqSatelliteList, ...
        'numberOfChannels', 4, ...
        'plotTracking', 0, ...
        'EnablePB', true);

    if isempty(p.Results.outDir)
        outDir = fullfile(settings.resultRoot, 'smoke', ...
            ['prof_' char(string(datetime('now'), 'yyMMdd_HHmmss'))]);
    else
        outDir = p.Results.outDir;
    end
    if ~exist(outDir, 'dir'), mkdir(outDir); end

    [fid, dataAdaptCoeff] = openIfFile(settings);
    cleaner = onCleanup(@() safeClose(fid));

    profile('on', '-detail', 'mmex', '-history');
    t0 = tic;
    acqResults = runAcquisition(fid, settings, dataAdaptCoeff);
    channel = preRun2(acqResults, settings);
    [trackResults, channel] = tracking2_v6_fix2(fid, channel, settings); %#ok<ASGLU>
    wall = toc(t0);
    prof = profile('info');
    profile('off');

    [T, rankT] = analyzeProfileLocal(prof, outDir);
    writetable(T, fullfile(outDir, 'profile_all.csv'));
    writetable(rankT, fullfile(outDir, 'profile_mex_rank.csv'));
    save(fullfile(outDir, 'profile_stats.mat'), 'T', 'rankT', 'prof', 'wall', 'settings', '-v7.3');

    % Markdown summary
    fidr = fopen(fullfile(outDir, 'mex_roi_report.md'), 'w');
    fprintf(fidr, '# MEX ROI from profiled track (%d ms, PRN %s)\n\n', ...
        settings.msToProcess, mat2str(settings.acqSatelliteList));
    fprintf(fidr, 'Wall time (acq+track): **%.2f s**\n\n', wall);
    fprintf(fidr, '| Rank | Function | Self [s] | Total [s] | Calls | MexScore | File |\n');
    fprintf(fidr, '|-----:|----------|---------:|----------:|------:|---------:|------|\n');
    n = min(25, height(rankT));
    for i = 1:n
        r = rankT(i,:);
        fprintf(fidr, '| %d | `%s` | %.3f | %.3f | %d | %.2f | `%s` |\n', i, ...
            r.FunctionName{1}, r.SelfTime, r.TotalTime, r.NumCalls, r.MexScore, r.FileName{1});
    end
    fprintf(fidr, '\n## Recommendation\n\n');
    fprintf(fidr, '1. If `tracking2_v6_fix2` dominates **SelfTime**, extract 1-ms correlator/NCO kernel to MEX.\n');
    fprintf(fidr, '2. High-call helpers (`pulseBlanker`, `NH_stateMachine`, `Calc_CNo_PLD`) next.\n');
    fprintf(fidr, '3. Acquisition FFT path matters for full-sky search, less for tracking-only.\n');
    fclose(fidr);

    fprintf('Profile saved under %s (wall=%.1fs)\n', outDir, wall);
    fprintf('%-6s %-10s %-10s %-10s %s\n', 'Rank', 'Self_s', 'Total_s', 'Calls', 'Function');
    for i = 1:min(15, height(rankT))
        fprintf('%-6d %-10.3f %-10.3f %-10d %s\n', i, ...
            rankT.SelfTime(i), rankT.TotalTime(i), rankT.NumCalls(i), rankT.FunctionName{i});
    end
end

function safeClose(fid)
    if ~isempty(fid) && fid > 0
        try, fclose(fid); catch, end %#ok<CTCH>
    end
end

function [T, rankT] = analyzeProfileLocal(prof, outDir) %#ok<INUSD>
    if isempty(prof) || ~isfield(prof, 'FunctionTable') || isempty(prof.FunctionTable)
        T = table(); rankT = table(); return;
    end
    ft = prof.FunctionTable;
    n = numel(ft);
    FunctionName = cell(n,1); FileName = cell(n,1);
    NumCalls = zeros(n,1); TotalTime = zeros(n,1); SelfTime = zeros(n,1);
    IsMEX = false(n,1);
    for i = 1:n
        FunctionName{i} = char(string(ft(i).FunctionName));
        FileName{i} = char(string(ft(i).FileName));
        NumCalls(i) = ft(i).NumCalls;
        TotalTime(i) = ft(i).TotalTime;
        childTime = 0;
        if isfield(ft(i), 'Children') && ~isempty(ft(i).Children) && size(ft(i).Children,2) >= 3
            childTime = sum(ft(i).Children(:,3));
        end
        SelfTime(i) = max(0, TotalTime(i) - childTime);
    end
    T = table(FunctionName, FileName, NumCalls, TotalTime, SelfTime, IsMEX);
    T = sortrows(T, 'SelfTime', 'descend');
    keep = (T.SelfTime >= 0.005) | (T.NumCalls >= 500);
    rankT = T(keep,:);
    rankT.MexCandidate = true(height(rankT),1);
    for i = 1:height(rankT)
        inProject = contains(rankT.FileName{i}, 'matlab-GNSSsdr') || contains(rankT.FileName{i}, [filesep 'B2a']);
        inToolbox = contains(rankT.FileName{i}, [filesep 'toolbox' filesep]);
        if inToolbox && ~inProject
            rankT.MexCandidate(i) = false;
        end
        if inProject
            rankT.MexCandidate(i) = true;
        end
    end
    score = rankT.SelfTime .* log10(double(rankT.NumCalls)+1);
    score(~rankT.MexCandidate) = score(~rankT.MexCandidate)*0.15;
    rankT.MexScore = score;
    rankT = sortrows(rankT, 'MexScore', 'descend');
end
