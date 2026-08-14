function report = run_fullsky_lock_diag(varargin)
%RUN_FULLSKY_LOCK_DIAG Acquire PRN 1:60, track all acquired, diagnose lock loss.
%
%   report = run_fullsky_lock_diag()
%   report = run_fullsky_lock_diag('msToProcess', 40000, 'parMaxWorkers', 6)
%
% Focus: SVs that acquire OK but interrupt / re-enter REACQ repeatedly.

    setupPaths();

    p = inputParser;
    p.KeepUnmatched = true;
    addParameter(p, 'prnList', 1:60, @(x)isnumeric(x));
    addParameter(p, 'msToProcess', 40000, @(x)isnumeric(x)&&isscalar(x));
    addParameter(p, 'useParfor', true, @islogical);
    addParameter(p, 'parMaxWorkers', 6, @(x)isnumeric(x)&&isscalar(x));
    addParameter(p, 'doPlot', true, @islogical);
    parse(p, varargin{:});
    unmatched = namedargs2cell(p.Unmatched);

    stamp = string(datetime('now'), 'yyMMdd_HHmmss');
    outDir = fullfile(fileparts(mfilename('fullpath')), '..', 'results', 'smoke', ...
        sprintf('fullsky_lock_%s', stamp));
    outDir = char(java.io.File(outDir).getCanonicalPath());
    figDir = fullfile(outDir, 'figures');
    if ~exist(figDir, 'dir'), mkdir(figDir); end

    prnList = p.Results.prnList(:)';
    ms = p.Results.msToProcess;

    fprintf('=== Full-sky lock diagnostic ===\n');
    fprintf('PRN list: %d..%d (%d)  msToProcess=%d  parMaxWorkers=%d\n', ...
        min(prnList), max(prnList), numel(prnList), ms, p.Results.parMaxWorkers);
    fprintf('outDir: %s\n', outDir);

    %% --- Stage 1: acquisition ------------------------------------------------
    settingsAcq = initSettings(unmatched{:}, ...
        'acqSatelliteList', prnList, ...
        'msToProcess', max(ms, 10), ...
        'numberOfChannels', max(4, numel(prnList)), ...
        'plotTracking', 0, ...
        'EnablePB', true, ...
        'useParfor', p.Results.useParfor, ...
        'parMaxWorkers', min(6, p.Results.parMaxWorkers));

    [fid, dataAdaptCoeff] = openIfFile(settingsAcq);
    cleaner = onCleanup(@() local_fclose(fid)); %#ok<NASGU>

    tAcq = tic;
    acqResults = runAcquisition(fid, settingsAcq, dataAdaptCoeff);
    acqElapsed = toc(tAcq);

    satList = settingsAcq.acqSatelliteList(:)';
    cf = acqResults.carrFreq(:);
    pm = acqResults.peakMetric(:);
    if numel(cf) < numel(satList)
        % pad defensively
        cf(end+1:numel(satList)) = NaN;
        pm(end+1:numel(satList)) = NaN;
    end
    acquiredMask = isfinite(cf(1:numel(satList))) & (cf(1:numel(satList)) ~= 0);
    acquiredPrn = satList(acquiredMask);
    nAcq = numel(acquiredPrn);

    fprintf('\n--- Acquisition (%.1f s) ---\n', acqElapsed);
    fprintf('Searched %d PRNs, acquired %d\n', numel(satList), nAcq);
    fprintf('%-5s %10s %10s %10s %8s %8s\n', ...
        'PRN', 'carrHz', 'peakMet', 'codePh', 'weil', 'pol');
    for k = 1:numel(satList)
        if ~acquiredMask(k), continue; end
        wp = 0; pol = 1;
        if isfield(acqResults, 'weilPhase'), wp = acqResults.weilPhase(k); end
        if isfield(acqResults, 'polarityRef'), pol = acqResults.polarityRef(k); end
        fprintf('%-5d %10.1f %10.3f %10.0f %8d %8d\n', ...
            satList(k), cf(k), pm(k), acqResults.codePhase(k), wp, pol);
    end

    if nAcq == 0
        error('run_fullsky_lock_diag:NoAcq', 'No PRN acquired in 1:60 search.');
    end

    %% --- Stage 2: track all acquired -----------------------------------------
    % Channel slots must cover every acquired SV
    nCh = max(nAcq, 4);
    settings = initSettings(unmatched{:}, ...
        'acqSatelliteList', acquiredPrn, ...
        'msToProcess', ms, ...
        'numberOfChannels', nCh, ...
        'plotTracking', 0, ...
        'EnablePB', true, ...
        'useParfor', p.Results.useParfor, ...
        'parMaxWorkers', min(6, p.Results.parMaxWorkers));
    % Keep same temp path for this run
    settings.tempdataSvPth = settingsAcq.tempdataSvPth;
    settings.resultRoot = settingsAcq.resultRoot;

    % Rebuild channel from full acqResults but only acquired PRNs mapping
    % preRun2 expects acqResults indexed by acqSatelliteList
    acqTrack = sliceAcqResults(acqResults, satList, acquiredPrn);
    channel = preRun2(acqTrack, settings);
    showChannelStatus(channel, settings);

    tTrk = tic;
    [trackResults, channel] = tracking2_v6_fix2(fid, channel, settings);
    trkElapsed = toc(tTrk);
    fprintf('Tracking wall %.1f s for %d SV x %d ms\n', trkElapsed, nAcq, ms);

    %% --- Stage 3: per-SV lock diagnostics ------------------------------------
    stateNames = containers.Map( ...
        {uint8(0),uint8(1),uint8(2),uint8(3),uint8(4),uint8(9)}, ...
        {'UNK','INIT','INIT_FLL','LONG','LONG_FLL','REACQ'});

    rows = [];
    problemPrns = [];
    for c = 1:numel(trackResults)
        tr = trackResults(c);
        if isempty(tr) || tr.PRN == 0
            continue;
        end
        d = diagnoseOneSv(tr, settings, stateNames);
        d.channel = c;
        d.peakMetric = NaN;
        idxAcq = find(satList == tr.PRN, 1);
        if ~isempty(idxAcq)
            d.peakMetric = pm(idxAcq);
            d.acqCarrHz = cf(idxAcq);
        else
            d.acqCarrHz = NaN;
        end
        rows = [rows; d]; %#ok<AGROW>
        if d.isProblem
            problemPrns(end+1) = tr.PRN; %#ok<AGROW>
        end
    end

    %% --- Stage 4: report + figures -------------------------------------------
    mdPath = fullfile(outDir, 'lock_diag_report.md');
    writeMarkdownReport(mdPath, rows, acquiredPrn, problemPrns, ...
        acqElapsed, trkElapsed, ms, settings, outDir);

    if p.Results.doPlot
        plotProblemSvs(rows, trackResults, figDir, ms);
        plotOverviewBar(rows, figDir);
    end

    report = struct();
    report.outDir = outDir;
    report.settings = settings;
    report.acqResults = acqResults;
    report.acquiredPrn = acquiredPrn;
    report.trackResults = trackResults;
    report.channel = channel;
    report.diag = rows;
    report.problemPrns = problemPrns;
    report.acqElapsed_s = acqElapsed;
    report.trkElapsed_s = trkElapsed;

    save(fullfile(outDir, 'fullsky_lock.mat'), 'report', '-v7.3');
    fprintf('\n=== Done ===\n');
    fprintf('Acquired: %s\n', mat2str(acquiredPrn'));
    fprintf('Problem (interrupt / re-lock): %s\n', mat2str(problemPrns));
    fprintf('Report: %s\n', mdPath);
end

%% ===== helpers ==============================================================

function acqOut = sliceAcqResults(acqIn, fullList, keepPrn)
    % Build acqResults arrays ordered as keepPrn (for preRun2).
    n = numel(keepPrn);
    acqOut = struct();
    acqOut.carrFreq = zeros(1, n);
    acqOut.codePhase = zeros(1, n);
    acqOut.codePhaseAbs = zeros(1, n);
    acqOut.peakMetric = zeros(1, n);
    acqOut.weilPhase = zeros(1, n);
    acqOut.polarityRef = ones(1, n);
    fns = fieldnames(acqIn);
    for i = 1:n
        k = find(fullList == keepPrn(i), 1);
        if isempty(k), continue; end
        acqOut.carrFreq(i) = acqIn.carrFreq(k);
        acqOut.codePhase(i) = acqIn.codePhase(k);
        if isfield(acqIn, 'codePhaseAbs')
            acqOut.codePhaseAbs(i) = acqIn.codePhaseAbs(k);
        else
            acqOut.codePhaseAbs(i) = acqIn.codePhase(k);
        end
        acqOut.peakMetric(i) = acqIn.peakMetric(k);
        if isfield(acqIn, 'weilPhase')
            acqOut.weilPhase(i) = acqIn.weilPhase(k);
        end
        if isfield(acqIn, 'polarityRef')
            acqOut.polarityRef(i) = acqIn.polarityRef(k);
        end
        % copy any extra vector fields if same length as fullList
        for f = 1:numel(fns)
            name = fns{f};
            if ismember(name, {'carrFreq','codePhase','codePhaseAbs','peakMetric','weilPhase','polarityRef'})
                continue;
            end
            v = acqIn.(name);
            if isnumeric(v) && numel(v) >= max(fullList)*0+numel(fullList) && numel(v) == numel(fullList)
                if ~isfield(acqOut, name)
                    acqOut.(name) = zeros(1, n);
                end
                acqOut.(name)(i) = v(k);
            end
        end
    end
end

function d = diagnoseOneSv(tr, settings, stateNames)
    N = min([numel(tr.I_P), numel(tr.cur_state), numel(tr.trk_state), settings.msToProcess]);
    cs = logical(tr.cur_state(1:N));
    ts = tr.trk_state(1:N);
    cno = tr.B2a_CNo;
    cno = cno(isfinite(cno));

    longMask = cs;  % cur_state true ~ LONG*
    longPct = 100 * mean(longMask);

    % REACQ samples
    reacqMask = (ts == 9);
    reacqPct = 100 * mean(reacqMask);
    nReacqSamples = nnz(reacqMask);

    % Transitions into REACQ (rising edges)
    reacqEnter = find(diff([false, reacqMask]) == 1);
    nReacqEpisodes = numel(reacqEnter);

    % Transitions out of / into LONG (cur_state)
    lm = double(longMask(:)');
    unlockEdges = find(diff([0, lm]) == -1);
    lockEdges   = find(diff([0, lm]) == 1);
    nUnlock = numel(unlockEdges);
    nRelock = numel(lockEdges);

    % First time in LONG and first unlock after that
    firstLong = find(longMask, 1, 'first');
    if isempty(firstLong), firstLong = NaN; end
    firstUnlock = NaN;
    if ~isnan(firstLong)
        ue = unlockEdges(unlockEdges > firstLong);
        if ~isempty(ue), firstUnlock = ue(1); end
    end

    % Longest continuous LONG run (ms)
    maxLongRun = 0;
    if any(longMask)
        dlm = diff([false, longMask, false]);
        starts = find(dlm == 1);
        ends = find(dlm == -1) - 1;
        maxLongRun = max(ends - starts + 1);
    end

    % C/N0 stats
    if isempty(cno)
        meanCNo = NaN; minCNo = NaN; maxCNo = NaN; p10CNo = NaN;
    else
        meanCNo = mean(cno); minCNo = min(cno); maxCNo = max(cno);
        p10CNo = prctile(cno, 10);
    end

    % Finite correlator coverage
    finiteIp = nnz(isfinite(tr.I_P(1:N)));
    fillPct = 100 * finiteIp / N;

    % CarrFreq jumps (possible cycle slips / reacq handover)
    carr = tr.carrFreq(1:N);
    carr = carr(isfinite(carr));
    if numel(carr) > 10
        dc = abs(diff(carr));
        nBigJump = nnz(dc > 50);  % >50 Hz step between 1ms epochs (unusual unless REACQ)
        maxJump = max(dc);
    else
        nBigJump = 0; maxJump = NaN;
    end

    % State histogram
    ids = unique(ts);
    histStr = '';
    for i = 1:numel(ids)
        id = ids(i);
        if isKey(stateNames, id)
            nm = stateNames(id);
        else
            nm = sprintf('ID%d', id);
        end
        histStr = sprintf('%s %s:%.1f%%', histStr, nm, 100*mean(ts==id));
    end
    histStr = strtrim(histStr);

    % Problem score: acquired but unstable tracking
    % Criteria (any):
    %  - >=2 REACQ episodes
    %  - >=2 unlock events after first lock
    %  - LONG% < 70 after having been in LONG
    %  - REACQ sample share > 5%
    isProblem = false;
    reasons = {};
    if nReacqEpisodes >= 2
        isProblem = true; reasons{end+1} = sprintf('REACQ_episodes=%d', nReacqEpisodes); %#ok<AGROW>
    end
    if nUnlock >= 2
        isProblem = true; reasons{end+1} = sprintf('unlocks=%d', nUnlock); %#ok<AGROW>
    end
    if ~isnan(firstLong) && longPct < 70 && N >= 5000
        isProblem = true; reasons{end+1} = sprintf('LONG%%=%.1f', longPct); %#ok<AGROW>
    end
    if reacqPct > 5
        isProblem = true; reasons{end+1} = sprintf('REACQ%%=%.1f', reacqPct); %#ok<AGROW>
    end
    if isnan(firstLong) && N >= 5000
        isProblem = true; reasons{end+1} = 'never_LONG'; %#ok<AGROW>
    end
    if ~isempty(cno) && meanCNo < settings.TrkCN0Th + 3 && nUnlock >= 1
        isProblem = true; reasons{end+1} = sprintf('weak_CNo=%.1f', meanCNo); %#ok<AGROW>
    end

    d = struct();
    d.PRN = tr.PRN;
    d.status = tr.status;
    d.N = N;
    d.longPct = longPct;
    d.reacqPct = reacqPct;
    d.nReacqEpisodes = nReacqEpisodes;
    d.nReacqSamples = nReacqSamples;
    d.nUnlock = nUnlock;
    d.nRelock = nRelock;
    d.firstLong_ms = firstLong;
    d.firstUnlock_ms = firstUnlock;
    d.maxLongRun_ms = maxLongRun;
    d.meanCNo = meanCNo;
    d.minCNo = minCNo;
    d.maxCNo = maxCNo;
    d.p10CNo = p10CNo;
    d.fillPct = fillPct;
    d.nBigCarrJump = nBigJump;
    d.maxCarrJumpHz = maxJump;
    d.stateHist = histStr;
    d.isProblem = isProblem;
    d.reasons = strjoin(reasons, '; ');
    d.reacqEnter_ms = reacqEnter;
    d.unlock_ms = unlockEdges;
end

function writeMarkdownReport(mdPath, rows, acquiredPrn, problemPrns, ...
        acqElapsed, trkElapsed, ms, settings, outDir)
    fid = fopen(mdPath, 'w');
    if fid < 0, warning('Cannot write %s', mdPath); return; end
    cleaner = onCleanup(@() fclose(fid)); %#ok<NASGU>

    fprintf(fid, '# Full-sky lock diagnostic report\n\n');
    fprintf(fid, '**Date:** %s  \n', string(datetime('now')));
    fprintf(fid, '**Branch focus:** par-fast-matlab multi-SV track  \n');
    fprintf(fid, '**Search list:** PRN 1:60  \n');
    fprintf(fid, '**Track length:** %d ms  \n', ms);
    fprintf(fid, '**Acq wall:** %.1f s  |  **Track wall:** %.1f s  \n', acqElapsed, trkElapsed);
    fprintf(fid, '**useParfor:** %d  **parMaxWorkers:** %d  \n', ...
        settings.useParfor, settings.parMaxWorkers);
    fprintf(fid, '**Output:** `%s`\n\n', outDir);

    fprintf(fid, '## 1. Acquisition summary\n\n');
    fprintf(fid, 'Acquired **%d** PRNs: `%s`\n\n', numel(acquiredPrn), mat2str(acquiredPrn'));
    fprintf(fid, '| PRN | peakMetric | acq Doppler (Hz) | mean C/N0 | LONG%% | REACQ eps | unlocks | problem |\n');
    fprintf(fid, '|----:|----------:|---------------:|----------:|------:|----------:|--------:|:-------:|\n');
    % sort: problems first, then by LONG%
    if isempty(rows)
        fprintf(fid, '\n_No track rows._\n');
        return;
    end
    score = -[rows.isProblem]' * 1000 + [rows.longPct]';
    [~, ord] = sort(score, 'ascend');  % problems first (low score)
    for i = 1:numel(ord)
        r = rows(ord(i));
        flag = ' ';
        if r.isProblem, flag = '**YES**'; end
        fprintf(fid, '| %d | %.3f | %.1f | %.1f | %.1f | %d | %d | %s |\n', ...
            r.PRN, r.peakMetric, r.acqCarrHz, r.meanCNo, r.longPct, ...
            r.nReacqEpisodes, r.nUnlock, flag);
    end

    fprintf(fid, '\n## 2. Problem satellites (focus)\n\n');
    if isempty(problemPrns)
        fprintf(fid, '_No SV met the unstable-lock criteria on this run._\n\n');
    else
        fprintf(fid, 'Flagged PRNs: **%s**\n\n', mat2str(problemPrns));
        fprintf(fid, 'Criteria (any): ≥2 REACQ episodes; ≥2 unlocks; LONG%%<70 after lock; ');
        fprintf(fid, 'REACQ sample share>5%%; never LONG; weak C/N0 near TrkCN0Th with unlock.\n\n');
        for i = 1:numel(ord)
            r = rows(ord(i));
            if ~r.isProblem, continue; end
            fprintf(fid, '### PRN %d\n\n', r.PRN);
            fprintf(fid, '| metric | value |\n|---|---:|\n');
            fprintf(fid, '| status | %s |\n', r.status);
            fprintf(fid, '| peakMetric (acq) | %.3f |\n', r.peakMetric);
            fprintf(fid, '| acq carrFreq | %.1f Hz |\n', r.acqCarrHz);
            fprintf(fid, '| mean/min/p10/max C/N0 | %.1f / %.1f / %.1f / %.1f |\n', ...
                r.meanCNo, r.minCNo, r.p10CNo, r.maxCNo);
            fprintf(fid, '| LONG%% | %.1f |\n', r.longPct);
            fprintf(fid, '| max continuous LONG | %d ms |\n', r.maxLongRun_ms);
            fprintf(fid, '| first LONG / first unlock | %s / %s ms |\n', ...
                num2str(r.firstLong_ms), num2str(r.firstUnlock_ms));
            fprintf(fid, '| REACQ episodes / sample%% | %d / %.1f%% |\n', ...
                r.nReacqEpisodes, r.reacqPct);
            fprintf(fid, '| unlock / relock edges | %d / %d |\n', r.nUnlock, r.nRelock);
            fprintf(fid, '| |carrFreq| jumps >50 Hz | %d (max %.1f Hz) |\n', ...
                r.nBigCarrJump, r.maxCarrJumpHz);
            fprintf(fid, '| fill%% (finite I_P) | %.1f |\n', r.fillPct);
            fprintf(fid, '| state hist | %s |\n', r.stateHist);
            fprintf(fid, '| reasons | %s |\n', r.reasons);
            if ~isempty(r.reacqEnter_ms)
                ent = r.reacqEnter_ms;
                if numel(ent) > 20, ent = ent(1:20); end
                fprintf(fid, '| REACQ enter times (ms) | %s |\n', mat2str(ent));
            end
            fprintf(fid, '\n**Likely causes (heuristic):**\n\n');
            fprintf(fid, '%s\n\n', suggestCauses(r, settings));
        end
    end

    fprintf(fid, '## 3. Stable satellites (reference)\n\n');
    for i = 1:numel(ord)
        r = rows(ord(i));
        if r.isProblem, continue; end
        fprintf(fid, '- PRN **%d**: LONG=%.1f%% meanCNo=%.1f unlocks=%d REACQ_eps=%d peak=%.2f\n', ...
            r.PRN, r.longPct, r.meanCNo, r.nUnlock, r.nReacqEpisodes, r.peakMetric);
    end

    fprintf(fid, '\n## 4. System-level notes\n\n');
    fprintf(fid, '- `TrkCN0Th` = %.1f dB-Hz (REACQ trigger threshold in NH SM).\n', settings.TrkCN0Th);
    fprintf(fid, '- `CNo_Th` = %.1f dB-Hz.\n', settings.CNo_Th);
    fprintf(fid, '- `REACQ_max` = %d attempts before give-up.\n', settings.REACQ_max);
    fprintf(fid, '- Pulse blanker EnablePB = %d.\n', settings.EnablePB);
    fprintf(fid, '- Parallel track: private IF fopen per SV; max workers 6.\n');
    fprintf(fid, '- Figures under `figures/` for problem PRNs (state/CNo/Doppler).\n');
end

function txt = suggestCauses(r, settings)
    lines = {};
    if ~isnan(r.meanCNo) && r.meanCNo < settings.TrkCN0Th + 5
        lines{end+1} = sprintf( ...
            '- **Weak signal**: mean C/N0 (%.1f) near TrkCN0Th (%.1f) → NH SM trips REACQ often.', ...
            r.meanCNo, settings.TrkCN0Th); %#ok<AGROW>
    end
    if r.peakMetric < 3.0
        lines{end+1} = sprintf( ...
            '- **Marginal acquisition**: peakMetric=%.2f close to threshold → possible false peak / poor code-phase.', ...
            r.peakMetric); %#ok<AGROW>
    end
    if r.nReacqEpisodes >= 2 && r.nBigCarrJump > 0
        lines{end+1} = '- **REACQ handover churn**: multiple REACQ + large carrFreq jumps → check REACQ fseek/codePhase alignment and fineNoncoh buffer.'; %#ok<AGROW>
    end
    if r.nUnlock >= 2 && r.reacqPct < 1 && r.meanCNo > 40
        lines{end+1} = '- **Strong C/N0 but unlocks**: suspect NH/Weil phase slip, Costas half-cycle, or FLL aiding glitch rather than pure power fade.'; %#ok<AGROW>
    end
    if ~isnan(r.p10CNo) && ~isnan(r.meanCNo) && (r.meanCNo - r.p10CNo) > 8
        lines{end+1} = sprintf( ...
            '- **Deep fades**: mean-p10 C/N0 gap = %.1f dB → scintillation / RFI / PB over-blanking; check S4 and blanker duty.', ...
            r.meanCNo - r.p10CNo); %#ok<AGROW>
    end
    if strcmpi(strtrim(r.reasons), 'never_LONG')
        lines{end+1} = '- **Never reached LONG**: INIT/Weil estimate failed or CN0 invalid during pull-in; inspect INIT duration and polarity/Weil from acq.'; %#ok<AGROW>
    end
    if r.fillPct < 95
        lines{end+1} = sprintf( ...
            '- **Incomplete log fill (%.1f%%)**: early exit / EOF / chunk merge issue — verify TrackResults2 path.', ...
            r.fillPct); %#ok<AGROW>
    end
    if isempty(lines)
        lines{end+1} = '- Review state timeline figure; compare unlock times with C/N0 and Doppler.';
    end
    txt = strjoin(lines, '\n');
end

function plotProblemSvs(rows, trackResults, figDir, ms)
    for i = 1:numel(rows)
        r = rows(i);
        if ~r.isProblem, continue; end
        tr = [];
        for c = 1:numel(trackResults)
            if trackResults(c).PRN == r.PRN
                tr = trackResults(c); break;
            end
        end
        if isempty(tr), continue; end
        N = min([numel(tr.I_P), r.N, ms]);
        t = (1:N) / 1000;
        f = figure('Visible', 'off', 'Color', 'w', 'Position', [80 80 1100 800]);
        subplot(4,1,1);
        plot(t, tr.Pilot_I_P(1:N).^2 + tr.Pilot_Q_P(1:N).^2); grid on;
        title(sprintf('PRN %d problem timeline', r.PRN));
        ylabel('Pilot |P|^2');
        subplot(4,1,2);
        plot(t, double(tr.cur_state(1:N)), 'g'); hold on;
        plot(t, double(tr.trk_state(1:N)), 'm');
        legend('cur\_state','trk\_state'); ylabel('state'); grid on;
        ylim([-0.5 10]);
        subplot(4,1,3);
        plot(t, tr.carrFreq(1:N)); grid on; ylabel('carrFreq Hz');
        subplot(4,1,4);
        cno = tr.B2a_CNo;
        if ~isempty(cno)
            tc = (1:numel(cno)) * (200/1000);  % default interval; ok for viz
            plot(tc, cno); grid on; ylabel('B2a C/N0'); xlabel('t (s)');
        else
            plot(t, nan(size(t))); ylabel('C/N0 n/a');
        end
        exportgraphics(f, fullfile(figDir, sprintf('prn%02d_timeline.png', r.PRN)), 'Resolution', 140);
        close(f);
    end
end

function plotOverviewBar(rows, figDir)
    if isempty(rows), return; end
    prn = [rows.PRN];
    lp = [rows.longPct];
    rp = [rows.reacqPct];
    f = figure('Visible', 'off', 'Color', 'w', 'Position', [80 80 900 400]);
    bar([lp(:), rp(:)]);
    set(gca, 'XTick', 1:numel(prn), 'XTickLabel', string(prn));
    legend('LONG%%', 'REACQ%%'); ylabel('%'); xlabel('PRN');
    title('Lock / REACQ share by PRN'); grid on;
    exportgraphics(f, fullfile(figDir, 'overview_long_reacq.png'), 'Resolution', 140);
    close(f);
end

function local_fclose(fid)
    if ~isempty(fid) && fid > 0
        try, fclose(fid); catch, end %#ok<CTCH>
    end
end
