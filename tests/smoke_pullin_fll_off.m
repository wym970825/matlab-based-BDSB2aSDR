function report = smoke_pullin_fll_off(varargin)
%SMOKE_PULLIN_FLL_OFF Serial (no parfor) 5s track of problem PRNs, FLL on vs off.
%
%   report = smoke_pullin_fll_off()
%   report = smoke_pullin_fll_off('msToProcess', 5000, 'prnList', [25 27 32 23])
%
% Uses mexBaseFast path (MEX correlator if present) on current branch with
% useParfor=false. Compares FLL fully off vs default FLL on.

    setupPaths();

    p = inputParser;
    addParameter(p, 'prnList', [25 27 32 23], @(x)isnumeric(x));
    addParameter(p, 'msToProcess', 5000, @(x)isnumeric(x)&&isscalar(x));
    parse(p, varargin{:});
    prnList = p.Results.prnList(:)';
    ms = p.Results.msToProcess;

    stamp = string(datetime('now'), 'yyMMdd_HHmmss');
    outDir = fullfile('results', 'smoke', sprintf('pullin_fll_%s', stamp));
    if ~exist(outDir, 'dir'), mkdir(outDir); end

    fprintf('=== Pull-in smoke (serial, fast path) ===\n');
    fprintf('PRNs: %s  ms=%d  useParfor=false\n', mat2str(prnList), ms);
    fprintf('outDir: %s\n', outDir);

    modes = { ...
        struct('tag', 'FLLoff', 'enable', false, 'aid', false), ...
        struct('tag', 'FLLon',  'enable', true,  'aid', true) ...
        };

    report = struct();
    report.outDir = outDir;
    report.prnList = prnList;
    report.msToProcess = ms;
    report.modes = {};

    for mi = 1:numel(modes)
        m = modes{mi};
        fprintf('\n---------- mode %s (enable=%d aid=%d) ----------\n', ...
            m.tag, m.enable, m.aid);

        settings = initSettings( ...
            'acqSatelliteList', prnList, ...
            'msToProcess', ms, ...
            'numberOfChannels', max(4, numel(prnList)), ...
            'plotTracking', 0, ...
            'EnablePB', true, ...
            'useParfor', false, ...
            'parMaxWorkers', 1);
        settings.FLL.enable = m.enable;
        settings.FLL.aidingEnable = m.aid;
        % Keep force-init window harmless when FLL off (aiding already gated)
        if ~m.enable
            settings.FLLinitT = 0;
        end

        [fid, dataAdaptCoeff] = openIfFile(settings);
        cleaner = onCleanup(@() local_fclose(fid)); %#ok<NASGU>

        tAcq = tic;
        acqResults = runAcquisition(fid, settings, dataAdaptCoeff);
        acqElapsed = toc(tAcq);

        % Print acq → track handoff params
        fprintf('--- acq handoff ---\n');
        for k = 1:numel(prnList)
            cf = acqResults.carrFreq(k);
            if ~(isfinite(cf) && cf ~= 0)
                fprintf('PRN%02d NOT ACQUIRED\n', prnList(k));
                continue;
            end
            fprintf(['PRN%02d carrFreq=%+.1f codePhase=%d weil=%d pol=%+d ' ...
                'peak=%.3f CN0p=%.1f\n'], ...
                prnList(k), cf, acqResults.codePhase(k), ...
                acqResults.weilPhase(k), acqResults.polarityRef(k), ...
                acqResults.peakMetric(k), acqResults.CN0_pilot(k));
        end

        channel = preRun2(acqResults, settings);
        showChannelStatus(channel, settings);

        tTrk = tic;
        [trackResults, channel] = tracking2_v6_fix2(fid, channel, settings);
        trkElapsed = toc(tTrk);
        fprintf('track wall %.1f s (serial)\n', trkElapsed);

        rows = [];
        for c = 1:numel(trackResults)
            tr = trackResults(c);
            if tr.PRN == 0, continue; end
            rows = [rows; summarizeSv(tr, ms)]; %#ok<AGROW>
            r = rows(end);
            if isnan(r.firstWeak_ms)
                fwStr = 'none';
            else
                fwStr = sprintf('%d', r.firstWeak_ms);
            end
            fprintf(['  PRN%02d LONG%%=%.1f meanCNo=%.1f P0=%.3g P200=%.3g ' ...
                'P1s=%.3g dCarr200=%+.1f firstWeak=%s |dll|=%.3f dCode=%.2f status=%s\n'], ...
                r.PRN, r.longPct, r.meanCNo, r.P0, r.P200, r.P1s, ...
                r.dCarr200, fwStr, r.meanAbsDll, r.meanCodeDf, r.status);
        end

        modeOut = struct();
        modeOut.tag = m.tag;
        modeOut.settings = settings;
        modeOut.acqResults = acqResults;
        modeOut.trackResults = trackResults;
        modeOut.channel = channel;
        modeOut.rows = rows;
        modeOut.acqElapsed_s = acqElapsed;
        modeOut.trkElapsed_s = trkElapsed;
        report.modes{end+1} = modeOut; %#ok<AGROW>

        save(fullfile(outDir, sprintf('smoke_%s.mat', m.tag)), ...
            'modeOut', 'settings', '-v7.3');
    end

    writeCompareMd(fullfile(outDir, 'pullin_compare.md'), report);
    save(fullfile(outDir, 'pullin_report.mat'), 'report', '-v7.3');
    fprintf('\nCompare: %s\n', fullfile(outDir, 'pullin_compare.md'));
end

function r = summarizeSv(tr, ms)
    N = min([numel(tr.I_P), numel(tr.cur_state), ms]);
    pp = tr.Pilot_I_P(1:N).^2 + tr.Pilot_Q_P(1:N).^2;
    cf = tr.carrFreq(1:N);
    cno = tr.B2a_CNo; cno = cno(isfinite(cno));
    r = struct();
    r.PRN = tr.PRN;
    r.status = tr.status;
    r.longPct = 100 * mean(tr.cur_state(1:N));
    r.meanCNo = ifelse(~isempty(cno), mean(cno), NaN);
    r.P0 = pp(1);
    r.P200 = median(pp(max(1,min(N,150)):min(N,200)));
    r.P1s = median(pp(1:min(N,1000)));
    r.dCarr200 = cf(min(N,200)) - cf(1);
    r.dCarrAll = cf(N) - cf(1);
    w = find(pp < 1e7, 1, 'first');
    if isempty(w), r.firstWeak_ms = NaN; else, r.firstWeak_ms = w; end
    r.maxAbsDCarr = max(abs(diff(cf)));
    % state hist compact
    ts = tr.trk_state(1:N);
    r.pctINIT = 100*mean(ts==1 | ts==2);
    r.pctLONG = 100*mean(ts==3 | ts==4);
    r.pctREACQ = 100*mean(ts==9);
    % DLL / code-rate metrics (for carrier-aid comparison)
    dll = tr.dllDiscr(1:N);
    dll = dll(isfinite(dll));
    if isempty(dll)
        r.meanAbsDll = NaN;
    else
        r.meanAbsDll = mean(abs(dll));
    end
    cdf = tr.codeFreq(1:N);
    cdf = cdf(isfinite(cdf));
    f0 = 10.23e6;
    if isempty(cdf)
        r.meanCodeDf = NaN;
    else
        r.meanCodeDf = mean(cdf) - f0;
    end
    r.meanCarr = mean(cf(isfinite(cf)));
end

function y = ifelse(c, a, b)
    if c, y = a; else, y = b; end
end

function writeCompareMd(path, report)
    fid = fopen(path, 'w');
    fprintf(fid, '# Pull-in FLL on/off compare (serial, problem PRNs)\n\n');
    fprintf(fid, 'PRNs: %s  msToProcess: %d  useParfor: false\n\n', ...
        mat2str(report.prnList), report.msToProcess);
    for mi = 1:numel(report.modes)
        m = report.modes{mi};
        fprintf(fid, '## Mode `%s` (track %.1f s)\n\n', m.tag, m.trkElapsed_s);
        fprintf(fid, '| PRN | LONG%% | meanCNo | P0 | P200 | |dll| | dCode | dCarr200 | firstWeak | LONG_st%% |\n');
        fprintf(fid, '|----:|------:|--------:|---:|-----:|------:|------:|---------:|----------:|---------:|\n');
        for i = 1:numel(m.rows)
            r = m.rows(i);
            if isnan(r.firstWeak_ms)
                fwStr = 'none';
            else
                fwStr = sprintf('%d', r.firstWeak_ms);
            end
            fprintf(fid, '| %d | %.1f | %.1f | %.3g | %.3g | %.3f | %+.2f | %+.1f | %s | %.1f |\n', ...
                r.PRN, r.longPct, r.meanCNo, r.P0, r.P200, r.meanAbsDll, r.meanCodeDf, ...
                r.dCarr200, fwStr, r.pctLONG);
        end
        fprintf(fid, '\n');
    end
    % side-by-side if both present
    if numel(report.modes) >= 2
        fprintf(fid, '## Side-by-side LONG%%\n\n');
        fprintf(fid, '| PRN | FLLoff LONG%% | FLLon LONG%% | FLLoff CNo | FLLon CNo |\n');
        fprintf(fid, '|----:|-------------:|------------:|-----------:|----------:|\n');
        off = report.modes{1}.rows;
        on  = report.modes{2}.rows;
        for i = 1:numel(off)
            prn = off(i).PRN;
            j = find([on.PRN] == prn, 1);
            if isempty(j)
                fprintf(fid, '| %d | %.1f | — | %.1f | — |\n', prn, off(i).longPct, off(i).meanCNo);
            else
                fprintf(fid, '| %d | %.1f | %.1f | %.1f | %.1f |\n', ...
                    prn, off(i).longPct, on(j).longPct, off(i).meanCNo, on(j).meanCNo);
            end
        end
        fprintf(fid, '\n### Verdict hint\n\n');
        fprintf(fid, '- If FLLoff LONG%% >> FLLon: FLL pull-in is the culprit.\n');
        fprintf(fid, '- If both bad: inspect acq→trk handoff (carrFreq/codePhase/pol/weil).\n');
    end
    fclose(fid);
end

function local_fclose(fid)
    if ~isempty(fid) && fid > 0
        try, fclose(fid); catch, end %#ok<CTCH>
    end
end
