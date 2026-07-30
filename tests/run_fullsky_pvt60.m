function report = run_fullsky_pvt60(varargin)
%RUN_FULLSKY_PVT60 Acquire PRN 1:60, track all acquired 60 s (parfor), PVT focus.
%
%   report = run_fullsky_pvt60()
%   report = run_fullsky_pvt60('msToProcess', 60000, 'parMaxWorkers', 6)

    setupPaths();

    p = inputParser;
    p.KeepUnmatched = true;
    addParameter(p, 'prnList', 1:60, @(x)isnumeric(x));
    addParameter(p, 'msToProcess', 60000, @(x)isnumeric(x)&&isscalar(x)&&x>=24000);
    addParameter(p, 'useParfor', true, @islogical);
    addParameter(p, 'parMaxWorkers', 6, @(x)isnumeric(x)&&isscalar(x));
    addParameter(p, 'doPlot', true, @islogical);
    parse(p, varargin{:});
    unmatched = namedargs2cell(p.Unmatched);

    prnList = p.Results.prnList(:)';
    ms = p.Results.msToProcess;
    stamp = string(datetime('now'), 'yyMMdd_HHmmss');
    outDir = fullfile('results', 'smoke', sprintf('fullsky_pvt60_%s', stamp));
    figDir = fullfile(outDir, 'figures');
    if ~exist(figDir, 'dir'), mkdir(figDir); end

    fprintf('=== Full-sky PVT %d ms ===\n', ms);
    fprintf('PRN search: %d..%d  parfor=%d workers<=%d\n', ...
        min(prnList), max(prnList), p.Results.useParfor, p.Results.parMaxWorkers);
    fprintf('outDir: %s\n', outDir);

    settings = initSettings(unmatched{:}, ...
        'acqSatelliteList', prnList, ...
        'msToProcess', ms, ...
        'numberOfChannels', max(16, numel(prnList)), ...
        'plotTracking', 0, ...
        'EnablePB', true, ...
        'useParfor', p.Results.useParfor, ...
        'parMaxWorkers', min(6, p.Results.parMaxWorkers));

    set(0, 'DefaultFigureVisible', 'off');

    tAll = tic;
    stage = struct();

    [fid, dataAdaptCoeff] = openIfFile(settings);
    cleaner = onCleanup(@() local_fclose(fid)); %#ok<NASGU>

    t0 = tic;
    acqResults = runAcquisition(fid, settings, dataAdaptCoeff);
    stage.acq_s = toc(t0);

    satList = settings.acqSatelliteList(:)';
    cf = acqResults.carrFreq(:);
    pm = acqResults.peakMetric(:);
    n = min(numel(satList), numel(cf));
    acqMask = isfinite(cf(1:n)) & (cf(1:n) ~= 0);
    acquiredPrn = satList(acqMask);
    fprintf('Acq %.1f s: %d / %d PRNs\n', stage.acq_s, numel(acquiredPrn), n);
    for k = find(acqMask).'
        fprintf('  PRN%02d peak=%.3f carr=%+.1f\n', satList(k), pm(k), cf(k));
    end
    if numel(acquiredPrn) < 4
        error('run_fullsky_pvt60:Need4', 'Need >=4 acquired (got %d).', numel(acquiredPrn));
    end

    % Re-init channel slots for acquired only (stable preRun mapping)
    settings.acqSatelliteList = acquiredPrn;
    settings.numberOfChannels = max(4, numel(acquiredPrn));
    acqTrack = sliceAcq(acqResults, satList, acquiredPrn);
    channel = preRun2(acqTrack, settings);
    showChannelStatus(channel, settings);

    t0 = tic;
    [trackResults, channel] = tracking2_v6_fix2(fid, channel, settings);
    stage.track_s = toc(t0);
    fprintf('Track wall %.1f s for %d SV x %d ms\n', stage.track_s, numel(acquiredPrn), ms);

    t0 = tic;
    [navSolutions, eph] = runNavigation(trackResults, settings);
    stage.nav_s = toc(t0);
    fprintf('Nav %.1f s\n', stage.nav_s);

    stage.total_s = toc(tAll);

    trkSummary = [];
    for k = 1:numel(trackResults)
        if trackResults(k).PRN == 0, continue; end
        tr = trackResults(k);
        N = min(numel(tr.cur_state), ms);
        cno = tr.B2a_CNo; cno = cno(isfinite(cno));
        row = struct();
        row.PRN = tr.PRN;
        row.status = char(string(tr.status));
        row.meanCNo = ifelse(~isempty(cno), mean(cno), NaN);
        row.maxCNo = ifelse(~isempty(cno), max(cno), NaN);
        row.pctLong = 100 * mean(logical(tr.cur_state(1:N)));
        trkSummary = [trkSummary; row]; %#ok<AGROW>
        fprintf('TRK PRN%02d LONG%%=%.1f meanCNo=%.1f status=%s\n', ...
            row.PRN, row.pctLong, row.meanCNo, row.status);
    end

    navSummary = summarizeNav(navSolutions, eph);

    if p.Results.doPlot
        try
            exportQuickFigs(trackResults, navSolutions, settings, figDir, ms);
        catch ME
            warning('run_fullsky_pvt60:Plot', '%s', ME.message);
        end
    end

    report = struct();
    report.outDir = outDir;
    report.settings = settings;
    report.acqResults = acqResults;
    report.acquiredPrn = acquiredPrn;
    report.channel = channel;
    report.trackResults = trackResults;
    report.navSolutions = navSolutions;
    report.eph = eph;
    report.stage = stage;
    report.trkSummary = trkSummary;
    report.navSummary = navSummary;

    save(fullfile(outDir, 'results.mat'), 'report', '-v7.3');
    writeReport(fullfile(outDir, 'report_pvt60.md'), report);

    fprintf('\n=== PVT focus ===\n');
    fprintf('fixes=%d ephOk=%d meanENU_rms=%.2f\n', ...
        navSummary.nFixes, navSummary.nEphOk, navSummary.enuRms);
    if navSummary.nFixes > 0
        fprintf('mean lat/lon/h = %.6f / %.6f / %.1f\n', ...
            navSummary.meanLat, navSummary.meanLon, navSummary.meanH);
        fprintf('FULLSKY_PVT60=PASS\n');
    else
        fprintf('FULLSKY_PVT60=PARTIAL (track ok, no/few fixes)\n');
    end
    fprintf('Report: %s\n', fullfile(outDir, 'report_pvt60.md'));
end

function acqOut = sliceAcq(acqIn, fullList, keepPrn)
    n = numel(keepPrn);
    acqOut = struct();
    acqOut.carrFreq = zeros(1, n);
    acqOut.codePhase = zeros(1, n);
    acqOut.codePhaseAbs = zeros(1, n);
    acqOut.peakMetric = zeros(1, n);
    acqOut.weilPhase = zeros(1, n);
    acqOut.polarityRef = ones(1, n);
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
        if isfield(acqIn, 'weilPhase'), acqOut.weilPhase(i) = acqIn.weilPhase(k); end
        if isfield(acqIn, 'polarityRef'), acqOut.polarityRef(i) = acqIn.polarityRef(k); end
    end
end

function s = summarizeNav(navSolutions, eph)
    s = struct('nFixes', 0, 'nEphOk', 0, 'meanLat', NaN, 'meanLon', NaN, ...
        'meanH', NaN, 'enuRms', NaN, 'meanDOP', NaN, 'nSol', 0);
    if isempty(navSolutions), return; end
    if ~isempty(eph)
        for k = 1:numel(eph)
            if isfield(eph(k), 'idValid') && ~isempty(eph(k).idValid)
                if eph(k).idValid(1) == 10 && eph(k).idValid(2) == 11
                    s.nEphOk = s.nEphOk + 1;
                end
            end
        end
    end
    if isfield(navSolutions, 'E')
        ok = isfinite(navSolutions.E) & isfinite(navSolutions.N) & isfinite(navSolutions.U);
        s.nFixes = nnz(ok);
        s.nSol = numel(navSolutions.E);
        if s.nFixes > 0
            s.enuRms = sqrt(mean(navSolutions.E(ok).^2 + navSolutions.N(ok).^2 + navSolutions.U(ok).^2));
        end
    end
    if isfield(navSolutions, 'latitude')
        lat = navSolutions.latitude; lon = navSolutions.longitude;
        if isfield(navSolutions, 'height'), h = navSolutions.height; else, h = nan(size(lat)); end
        okll = isfinite(lat) & isfinite(lon);
        if any(okll)
            s.meanLat = mean(lat(okll));
            s.meanLon = mean(lon(okll));
            if any(isfinite(h)), s.meanH = mean(h(isfinite(h))); end
        end
    end
    if isfield(navSolutions, 'DOP')
        d = navSolutions.DOP;
        if isnumeric(d), s.meanDOP = mean(d(isfinite(d))); end
    end
end

function exportQuickFigs(trackResults, navSolutions, settings, figDir, ms)
    % multi CNo
    f = figure('Visible', 'off', 'Color', 'w', 'Position', [80 80 1000 500]);
    hold on; grid on;
    leg = {};
    for k = 1:numel(trackResults)
        if trackResults(k).PRN == 0, continue; end
        cno = trackResults(k).B2a_CNo;
        if isempty(cno), continue; end
        tc = (1:numel(cno)) * (settings.CNoInterval/1000);
        plot(tc, cno);
        leg{end+1} = sprintf('PRN%d', trackResults(k).PRN); %#ok<AGROW>
    end
    if ~isempty(leg), legend(leg, 'Location', 'best'); end
    xlabel('t (s)'); ylabel('C/N0'); title('Full-sky 60s C/N0');
    exportgraphics(f, fullfile(figDir, 'trk_cno_multi.png'), 'Resolution', 140);
    close(f);

    if ~isempty(navSolutions) && isfield(navSolutions, 'E')
        ok = isfinite(navSolutions.E) & isfinite(navSolutions.N);
        if any(ok)
            f = figure('Visible', 'off', 'Color', 'w', 'Position', [80 80 900 700]);
            subplot(2,1,1);
            plot(navSolutions.E(ok), navSolutions.N(ok), '.'); grid on; axis equal;
            xlabel('E (m)'); ylabel('N (m)'); title('EN relative');
            subplot(2,1,2);
            if isfield(navSolutions, 'U')
                plot(find(ok), navSolutions.U(ok), '.'); grid on; ylabel('U (m)');
            end
            xlabel('epoch');
            exportgraphics(f, fullfile(figDir, 'nav_enu.png'), 'Resolution', 140);
            close(f);
        end
        if isfield(navSolutions, 'X') && isfield(navSolutions, 'Y')
            ok = isfinite(navSolutions.X);
            if any(ok)
                f = figure('Visible', 'off', 'Color', 'w');
                plot3(navSolutions.X(ok)-navSolutions.X(find(ok,1)), ...
                    navSolutions.Y(ok)-navSolutions.Y(find(ok,1)), ...
                    navSolutions.Z(ok)-navSolutions.Z(find(ok,1)), '.');
                grid on; title('ECEF relative');
                exportgraphics(f, fullfile(figDir, 'nav_ecef_relative.png'), 'Resolution', 120);
                close(f);
            end
        end
    end
    %#ok<*NASGU>
    ms;
end

function writeReport(path, report)
    fid = fopen(path, 'w');
    fprintf(fid, '# Full-sky 60 s PVT report\n\n');
    fprintf(fid, '**Branch:** par-fast-matlab (DLL pull-in 10 Hz)\n\n');
    fprintf(fid, '- msToProcess: %d\n', report.settings.msToProcess);
    fprintf(fid, '- useParfor: %d  parMaxWorkers: %d\n', ...
        report.settings.useParfor, report.settings.parMaxWorkers);
    fprintf(fid, '- Acquired: %s\n', mat2str(report.acquiredPrn'));
    fprintf(fid, '- Wall acq/track/nav/total: %.1f / %.1f / %.1f / %.1f s\n\n', ...
        report.stage.acq_s, report.stage.track_s, report.stage.nav_s, report.stage.total_s);

    fprintf(fid, '## Tracking\n\n');
    fprintf(fid, '| PRN | LONG%% | meanCNo | maxCNo | status |\n|----:|------:|--------:|-------:|:------:|\n');
    for i = 1:numel(report.trkSummary)
        r = report.trkSummary(i);
        fprintf(fid, '| %d | %.1f | %.1f | %.1f | %s |\n', ...
            r.PRN, r.pctLong, r.meanCNo, r.maxCNo, r.status);
    end

    ns = report.navSummary;
    fprintf(fid, '\n## PVT\n\n');
    fprintf(fid, '| metric | value |\n|---|---:|\n');
    fprintf(fid, '| nFixes | %d |\n', ns.nFixes);
    fprintf(fid, '| nEphOk | %d |\n', ns.nEphOk);
    fprintf(fid, '| mean lat | %.6f |\n', ns.meanLat);
    fprintf(fid, '| mean lon | %.6f |\n', ns.meanLon);
    fprintf(fid, '| mean height | %.1f |\n', ns.meanH);
    fprintf(fid, '| ENU RMS (rel) | %.2f m |\n', ns.enuRms);
    fprintf(fid, '| mean DOP | %.2f |\n', ns.meanDOP);
    if ns.nFixes > 0
        fprintf(fid, '\n**Verdict:** PVT produced fixes.\n');
    else
        fprintf(fid, '\n**Verdict:** No position fixes (check eph decode / SV set).\n');
    end
    fclose(fid);
end

function y = ifelse(c, a, b)
    if c, y = a; else, y = b; end
end

function local_fclose(fid)
    if ~isempty(fid) && fid > 0
        try, fclose(fid); catch, end %#ok<CTCH>
    end
end
