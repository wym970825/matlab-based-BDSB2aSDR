function smoke = smoke_pvt(varargin)
%SMOKE_PVT Four-SV tracking (>=38 s) + PVT + figures + profiler report.
%
%   smoke = smoke_pvt()
%   smoke = smoke_pvt('msToProcess', 38000, 'acqSatelliteList', [41 39 38 25])
%
% Outputs under results/smoke/pvt_<tag>/ :
%   results.mat, profile_stats.mat/csv, figures/*.png, report_pvt.md

    setupPaths();

    p = inputParser;
    p.KeepUnmatched = true;
    addParameter(p, 'msToProcess', 38000, @(x)isnumeric(x)&&isscalar(x)&&x>=24000);
    addParameter(p, 'acqSatelliteList', [41 39 38 25], @(x)isnumeric(x)&&numel(x)>=4);
    addParameter(p, 'EnablePB', true, @islogical);
    addParameter(p, 'tag', string(datetime('now'), 'yyMMdd_HHmmss'), @(x)ischar(x)||isstring(x));
    parse(p, varargin{:});

    unmatched = namedargs2cell(p.Unmatched);
    prnList = p.Results.acqSatelliteList(:).';
    msProc  = p.Results.msToProcess;
    tag     = char(p.Results.tag);

    settings = initSettings(unmatched{:}, ...
        'msToProcess', msProc, ...
        'acqSatelliteList', prnList, ...
        'numberOfChannels', max(12, numel(prnList)), ...
        'plotTracking', 0, ...
        'EnablePB', p.Results.EnablePB);

    outDir = fullfile(settings.resultRoot, 'smoke', ['pvt_' tag]);
    figDir = fullfile(outDir, 'figures');
    if ~exist(figDir, 'dir'), mkdir(figDir); end

    % Headless-friendly figures
    set(0, 'DefaultFigureVisible', 'off');
    set(0, 'DefaultFigureCreateFcn', @(fig,~) set(fig, 'Visible', 'off'));

    fprintf('\n========== PVT smoke: %d SV x %d ms ==========\n', numel(prnList), msProc);
    fprintf('PRN list: %s\n', mat2str(prnList));
    fprintf('Output:   %s\n', outDir);

    stage = struct();
    tWall0 = tic;

    %% --- Acquisition ----------------------------------------------------
    profile('on', '-detail', 'mmex', '-history');
    t0 = tic;
    [fid, dataAdaptCoeff] = openIfFile(settings);
    cleaner = onCleanup(@() safeClose(fid));
    acqResults = runAcquisition(fid, settings, dataAdaptCoeff);
    stage.acq_s = toc(t0);
    fprintf('Stage acq: %.1f s\n', stage.acq_s);

    acquiredMask = isfinite(acqResults.carrFreq(:)) & (acqResults.carrFreq(:) ~= 0);
    nAcq = nnz(acquiredMask);
    fprintf('Acquired %d / %d requested PRNs\n', nAcq, numel(prnList));
    if nAcq < 4
        profile('off');
        error('smoke_pvt:Need4SV', 'Need >=4 acquired SVs for PVT (got %d).', nAcq);
    end

    channel = preRun2(acqResults, settings);
    showChannelStatus(channel, settings);
    activeCh = find([channel.PRN] ~= 0);
    fprintf('Tracking channels: %s\n', mat2str([channel(activeCh).PRN]));

    %% --- Tracking -------------------------------------------------------
    t0 = tic;
    [trackResults, channel] = tracking2_v6_fix2(fid, channel, settings);
    stage.track_s = toc(t0);
    fprintf('Stage track: %.1f s (wall)\n', stage.track_s);

    %% --- Navigation -----------------------------------------------------
    t0 = tic;
    [navSolutions, eph] = runNavigation(trackResults, settings);
    stage.nav_s = toc(t0);
    fprintf('Stage nav: %.1f s\n', stage.nav_s);

    prof = profile('info');
    profile('off');
    stage.total_s = toc(tWall0);
    fprintf('Total wall: %.1f s\n', stage.total_s);

    %% --- Summaries ------------------------------------------------------
    trkSummary = summarizeTrack(trackResults);
    navSummary = summarizeNav(navSolutions, eph, trackResults);

    %% --- Visualizations -------------------------------------------------
    t0 = tic;
    figFiles = exportPvtFigures(trackResults, navSolutions, settings, figDir);
    stage.plot_s = toc(t0);
    fprintf('Stage plot/export: %.1f s (%d figures)\n', stage.plot_s, numel(figFiles));

    %% --- Profiler analysis / MEX ranking --------------------------------
    [profTable, mexRank] = analyzeProfile(prof, outDir);

    %% --- Assemble & save ------------------------------------------------
    smoke = struct();
    smoke.tag = tag;
    smoke.settings = settings;
    smoke.acqResults = acqResults;
    smoke.channel = channel;
    smoke.trackResults = trackResults;
    smoke.navSolutions = navSolutions;
    smoke.eph = eph;
    smoke.stage = stage;
    smoke.trkSummary = trkSummary;
    smoke.navSummary = navSummary;
    smoke.profTable = profTable;
    smoke.mexRank = mexRank;
    smoke.figFiles = figFiles;
    smoke.outDir = outDir;

    save(fullfile(outDir, 'results.mat'), 'smoke', '-v7.3');
    writePvtReport(smoke, fullfile(outDir, 'report_pvt.md'));
    fprintf('Saved: %s\n', fullfile(outDir, 'results.mat'));
    fprintf('Report: %s\n', fullfile(outDir, 'report_pvt.md'));

    % Console MEX top-10
    fprintf('\n=== Top self-time candidates (MEX ROI) ===\n');
    fprintf('%-6s %-10s %-10s %-10s %s\n', 'Rank', 'Self_s', 'Total_s', 'Calls', 'Function');
    nShow = min(15, height(mexRank));
    for i = 1:nShow
        fprintf('%-6d %-10.3f %-10.3f %-10d %s\n', i, ...
            mexRank.SelfTime(i), mexRank.TotalTime(i), mexRank.NumCalls(i), ...
            mexRank.FunctionName{i});
    end

    if navSummary.nFixes > 0
        fprintf('\nPVT_SMOKE=PASS fixes=%d meanENU_rms=%.2f m\n', ...
            navSummary.nFixes, navSummary.enuRms);
    else
        fprintf('\nPVT_SMOKE=PARTIAL track_ok but no position fixes\n');
    end
end

%% ========================================================================
function safeClose(fid)
    if ~isempty(fid) && fid > 0
        try, fclose(fid); catch, end %#ok<CTCH>
    end
end

function s = summarizeTrack(trackResults)
    s = struct('PRN', {}, 'status', {}, 'meanCNo', {}, 'maxCNo', {}, ...
        'meanPilotPwr', {}, 'pctLong', {});
    for k = 1:numel(trackResults)
        if isempty(trackResults(k).PRN) || trackResults(k).PRN == 0
            continue;
        end
        row.PRN = trackResults(k).PRN;
        row.status = char(string(trackResults(k).status));
        cno = trackResults(k).B2a_CNo;
        cno = cno(isfinite(cno));
        if isempty(cno)
            row.meanCNo = NaN; row.maxCNo = NaN;
        else
            row.meanCNo = mean(cno); row.maxCNo = max(cno);
        end
        ip = trackResults(k).Pilot_I_P;
        ip = ip(isfinite(ip));
        if isempty(ip)
            row.meanPilotPwr = NaN;
        else
            row.meanPilotPwr = mean(abs(ip).^2);
        end
        if isprop(trackResults(k), 'cur_state') || isfield(trackResults(k), 'cur_state')
            st = trackResults(k).cur_state;
            st = st(isfinite(double(st)) | islogical(st));
            row.pctLong = 100 * mean(logical(st));
        else
            row.pctLong = NaN;
        end
        s(end+1) = row; %#ok<AGROW>
        fprintf('TRK PRN%02d status=%s CNo mean/max=%.1f/%.1f LONG%%=%.1f\n', ...
            row.PRN, row.status, row.meanCNo, row.maxCNo, row.pctLong);
    end
end

function s = summarizeNav(navSolutions, eph, trackResults)
    s = struct('nFixes', 0, 'nEphOk', 0, 'meanLat', NaN, 'meanLon', NaN, ...
        'meanH', NaN, 'enuRms', NaN, 'meanDOP', NaN);
    if isempty(navSolutions)
        return;
    end
    if ~isempty(eph)
        for k = 1:numel(eph)
            if isfield(eph(k), 'idValid') && ~isempty(eph(k).idValid)
                if eph(k).idValid(1) == 10 && eph(k).idValid(2) == 11 ...
                        && any(ismember(eph(k).idValid(3:min(7,end)), 30:34))
                    s.nEphOk = s.nEphOk + 1;
                end
            end
        end
    end
    if isfield(navSolutions, 'E')
        ok = isfinite(navSolutions.E) & isfinite(navSolutions.N) & isfinite(navSolutions.U);
        s.nFixes = nnz(ok);
        if s.nFixes > 0
            E = navSolutions.E(ok); N = navSolutions.N(ok); U = navSolutions.U(ok);
            dE = E - mean(E); dN = N - mean(N); dU = U - mean(U);
            s.enuRms = sqrt(mean(dE.^2 + dN.^2 + dU.^2));
            if isfield(navSolutions, 'latitude')
                s.meanLat = mean(navSolutions.latitude(ok));
                s.meanLon = mean(navSolutions.longitude(ok));
                s.meanH   = mean(navSolutions.height(ok));
            end
            if isfield(navSolutions, 'DOP')
                dop = navSolutions.DOP(1, ok);
                s.meanDOP = mean(dop(isfinite(dop)));
            end
        end
    end
    fprintf('NAV fixes=%d ephOK=%d ENU_rms=%.2f m lat/lon/h=%.6f/%.6f/%.1f\n', ...
        s.nFixes, s.nEphOk, s.enuRms, s.meanLat, s.meanLon, s.meanH);
    %#ok<INUSD>
end

function figFiles = exportPvtFigures(trackResults, navSolutions, settings, figDir)
    figFiles = {};
    % Per-channel tracking overview
    for ch = 1:numel(trackResults)
        if isempty(trackResults(ch).PRN) || trackResults(ch).PRN == 0
            continue;
        end
        if isfield(trackResults(ch), 'status') || isprop(trackResults(ch), 'status')
            st = char(string(trackResults(ch).status));
            if ~isempty(st) && st(1) == '-', continue; end
        end
        prn = trackResults(ch).PRN;
        try
            f = figure('Visible', 'off', 'Color', 'w', ...
                'Name', sprintf('PRN%02d track', prn), 'Position', [50 50 1200 900]);
            N = min(settings.msToProcess, numel(trackResults(ch).I_P));
            t = (1:N) * 1e-3;
            % Pilot power E/P/L
            subplot(3,2,1);
            plot(t, trackResults(ch).Pilot_I_P(1:N).^2 + trackResults(ch).Pilot_Q_P(1:N).^2); hold on;
            plot(t, trackResults(ch).Pilot_I_E(1:N).^2 + trackResults(ch).Pilot_Q_E(1:N).^2);
            plot(t, trackResults(ch).Pilot_I_L(1:N).^2 + trackResults(ch).Pilot_Q_L(1:N).^2);
            grid on; legend('P','E','L'); title(sprintf('PRN %d Pilot correlator power', prn));
            xlabel('t [s]'); ylabel('|R|^2');
            % Data power
            subplot(3,2,2);
            plot(t, trackResults(ch).I_P(1:N).^2 + trackResults(ch).Q_P(1:N).^2);
            grid on; title('Data prompt power'); xlabel('t [s]');
            % PLL discr
            subplot(3,2,3);
            plot(t, trackResults(ch).pllDiscr(1:N)); hold on;
            plot(t, trackResults(ch).pllDiscrFilt(1:N));
            grid on; legend('raw','filt'); title('PLL discriminator'); xlabel('t [s]');
            % DLL
            subplot(3,2,4);
            plot(t, trackResults(ch).dllDiscr(1:N)); hold on;
            plot(t, trackResults(ch).dllDiscrFilt(1:N));
            grid on; legend('raw','filt'); title('DLL discriminator'); xlabel('t [s]');
            % Doppler
            subplot(3,2,5);
            plot(t, trackResults(ch).carrFreq(1:N));
            grid on; title('Carrier frequency (IF domain)'); xlabel('t [s]'); ylabel('Hz');
            % C/N0
            subplot(3,2,6);
            cno = trackResults(ch).B2a_CNo;
            tc = (1:numel(cno)) * settings.CNoInterval * 1e-3;
            plot(tc, cno, '-o', 'MarkerSize', 3);
            grid on; title('B2a C/N0'); xlabel('t [s]'); ylabel('dB-Hz');
            ylim([20 55]);
            fpath = fullfile(figDir, sprintf('trk_PRN%02d.png', prn));
            exportgraphics(f, fpath, 'Resolution', 150);
            close(f);
            figFiles{end+1} = fpath; %#ok<AGROW>
        catch ME
            warning('exportPvtFigures:Track', 'PRN %d: %s', prn, ME.message);
        end
    end

    % Navigation figures
    if ~isempty(navSolutions) && isfield(navSolutions, 'E')
        try
            ok = isfinite(navSolutions.E) & isfinite(navSolutions.N);
            if any(ok)
                f = figure('Visible', 'off', 'Color', 'w', 'Position', [50 50 1200 800], ...
                    'Name', 'Navigation');
                subplot(2,2,1);
                plot(navSolutions.E(ok) - mean(navSolutions.E(ok)), ...
                     navSolutions.N(ok) - mean(navSolutions.N(ok)), '.');
                axis equal; grid on;
                xlabel('\Delta E [m]'); ylabel('\Delta N [m]');
                title('Horizontal scatter (mean-centered)');
                subplot(2,2,2);
                k = find(ok);
                plot(k, navSolutions.U(ok) - mean(navSolutions.U(ok)), '.-');
                grid on; xlabel('fix idx'); ylabel('\Delta U [m]'); title('Up residual');
                subplot(2,2,3);
                if isfield(navSolutions, 'latitude')
                    geoplot(navSolutions.latitude(ok), navSolutions.longitude(ok), '.');
                    geobasemap streets;
                    title('LLA track');
                else
                    plot(navSolutions.E(ok), navSolutions.N(ok), '.-'); grid on;
                    title('EN track');
                end
                subplot(2,2,4);
                if isfield(navSolutions, 'DOP')
                    plot(navSolutions.DOP(1,:), '.-'); hold on;
                    if size(navSolutions.DOP,1) >= 4
                        plot(navSolutions.DOP(2,:), '.-');
                        plot(navSolutions.DOP(3,:), '.-');
                        plot(navSolutions.DOP(4,:), '.-');
                        legend('GDOP','PDOP','HDOP','VDOP');
                    end
                    grid on; title('DOP'); xlabel('fix idx');
                end
                fpath = fullfile(figDir, 'nav_overview.png');
                exportgraphics(f, fpath, 'Resolution', 150);
                close(f);
                figFiles{end+1} = fpath;
            end
        catch ME
            warning('exportPvtFigures:Nav', '%s', ME.message);
        end

        % Skyplot if az/el present
        try
            if isfield(navSolutions, 'az') && isfield(navSolutions, 'el')
                f = figure('Visible', 'off', 'Color', 'w', 'Position', [50 50 700 600]);
                % Use last valid epoch
                ncol = size(navSolutions.el, 2);
                last = ncol;
                for j = ncol:-1:1
                    if any(isfinite(navSolutions.el(:, j))), last = j; break; end
                end
                az = navSolutions.az(:, last);
                el = navSolutions.el(:, last);
                prn = [];
                if isfield(navSolutions, 'PRN')
                    prn = navSolutions.PRN(:, min(last, size(navSolutions.PRN,2)));
                end
                mask = isfinite(az) & isfinite(el) & el > 0;
                if any(mask)
                    polarplot(deg2rad(az(mask)), 90 - el(mask), 'o', 'MarkerSize', 10, 'LineWidth', 1.5);
                    ax = gca; ax.ThetaZeroLocation = 'top'; ax.ThetaDir = 'clockwise';
                    rlim([0 90]);
                    title(sprintf('Skyplot epoch %d', last));
                    if ~isempty(prn)
                        hold on;
                        azm = az(mask); elm = el(mask); prnm = prn(mask);
                        for i = 1:numel(azm)
                            if prnm(i) > 0
                                text(deg2rad(azm(i)), 90-elm(i), sprintf(' %d', prnm(i)));
                            end
                        end
                    end
                    fpath = fullfile(figDir, 'nav_skyplot.png');
                    exportgraphics(f, fpath, 'Resolution', 150);
                    close(f);
                    figFiles{end+1} = fpath;
                else
                    close(f);
                end
            end
        catch ME
            warning('exportPvtFigures:Sky', '%s', ME.message);
        end
    end

    % Optional legacy NHSMKF plots (export open figures)
    try
        activeIdx = find(arrayfun(@(x) ~isempty(x.PRN) && x.PRN ~= 0, trackResults));
        if ~isempty(activeIdx)
            plotTracking_NHSMKF(activeIdx, trackResults, settings);
            figs = findall(0, 'Type', 'figure');
            for i = 1:numel(figs)
                nm = figs(i).Name;
                if isempty(nm), nm = sprintf('fig_%d', figs(i).Number); end
                safe = regexprep(nm, '[^\w\-]+', '_');
                fpath = fullfile(figDir, sprintf('legacy_%s.png', safe));
                try
                    exportgraphics(figs(i), fpath, 'Resolution', 120);
                    figFiles{end+1} = fpath; %#ok<AGROW>
                catch
                end
                close(figs(i));
            end
        end
    catch ME
        warning('exportPvtFigures:Legacy', '%s', ME.message);
    end
end

function [T, rankT] = analyzeProfile(prof, outDir)
    if isempty(prof) || ~isfield(prof, 'FunctionTable') || isempty(prof.FunctionTable)
        T = table();
        rankT = table();
        return;
    end
    ft = prof.FunctionTable;
    n = numel(ft);
    FunctionName = cell(n,1);
    FileName = cell(n,1);
    NumCalls = zeros(n,1);
    TotalTime = zeros(n,1);
    SelfTime = zeros(n,1);
    IsMEX = false(n,1);
    for i = 1:n
        FunctionName{i} = char(string(ft(i).FunctionName));
        FileName{i} = char(string(ft(i).FileName));
        NumCalls(i) = ft(i).NumCalls;
        TotalTime(i) = ft(i).TotalTime;
        % Self time = total - time attributed to children (MATLAB Children col3)
        childTime = 0;
        if isfield(ft(i), 'Children') && ~isempty(ft(i).Children)
            ch = ft(i).Children;
            if size(ch, 2) >= 3
                childTime = sum(ch(:, 3));
            end
        end
        if isfield(ft(i), 'SelfTime') && ~isempty(ft(i).SelfTime)
            SelfTime(i) = ft(i).SelfTime;
        else
            SelfTime(i) = max(0, TotalTime(i) - childTime);
        end
        if isfield(ft(i), 'IsMEX')
            IsMEX(i) = logical(ft(i).IsMEX);
        else
            IsMEX(i) = contains(lower(FileName{i}), '.mex');
        end
    end

    T = table(FunctionName, FileName, NumCalls, TotalTime, SelfTime, IsMEX);
    T = sortrows(T, 'SelfTime', 'descend');

    keep = (T.SelfTime >= 0.01) | (T.NumCalls >= 1000);
    rankT = T(keep, :);
    rankT.MexCandidate = true(height(rankT), 1);
    builtins = {'profile','tic','toc','fprintf','plot','figure','exportgraphics', ...
        'fopen','fread','fclose','fseek','ftell','exist','warning','error', ...
        'datetime','string','fullfile','mkdir','save','load','onCleanup', ...
        'sin','cos','exp','fft','ifft','abs','mean','max','min','sum','zeros','ones'};
    for i = 1:height(rankT)
        fn = rankT.FunctionName{i};
        base = regexp(fn, '[^/\\>]+$', 'match', 'once');
        if isempty(base), base = fn; end
        inToolbox = contains(rankT.FileName{i}, [filesep 'toolbox' filesep]);
        inProject = contains(rankT.FileName{i}, 'matlab-GNSSsdr') || ...
                    contains(rankT.FileName{i}, [filesep 'B2a' filesep]);
        if any(strcmp(base, builtins)) || startsWith(fn, '@') || (inToolbox && ~inProject)
            rankT.MexCandidate(i) = false;
        end
        if inProject
            rankT.MexCandidate(i) = true;
        end
    end

    % ROI score: self time x log10(calls+1); demote non-candidates
    score = rankT.SelfTime .* log10(double(rankT.NumCalls) + 1);
    score(~rankT.MexCandidate) = score(~rankT.MexCandidate) * 0.15;
    rankT.MexScore = score;
    rankT = sortrows(rankT, 'MexScore', 'descend');

    writetable(T, fullfile(outDir, 'profile_all.csv'));
    writetable(rankT, fullfile(outDir, 'profile_mex_rank.csv'));
    save(fullfile(outDir, 'profile_stats.mat'), 'T', 'rankT', 'prof', '-v7.3');
end

function writePvtReport(smoke, path)
    fid = fopen(path, 'w');
    if fid < 0, return; end
    cleaner = onCleanup(@() fclose(fid));
    fprintf(fid, '# PVT Smoke Report (%s)\n\n', smoke.tag);
    fprintf(fid, '## Config\n\n');
    fprintf(fid, '- msToProcess: %d\n', smoke.settings.msToProcess);
    fprintf(fid, '- PRN list: %s\n', mat2str(smoke.settings.acqSatelliteList));
    fprintf(fid, '- EnablePB: %d\n\n', smoke.settings.EnablePB);
    fprintf(fid, '## Stage wall times\n\n');
    fprintf(fid, '| Stage | Seconds |\n|------|--------:|\n');
    fprintf(fid, '| Acquisition | %.2f |\n', smoke.stage.acq_s);
    fprintf(fid, '| Tracking | %.2f |\n', smoke.stage.track_s);
    fprintf(fid, '| Navigation | %.2f |\n', smoke.stage.nav_s);
    fprintf(fid, '| Plot/export | %.2f |\n', smoke.stage.plot_s);
    fprintf(fid, '| **Total** | **%.2f** |\n\n', smoke.stage.total_s);

    fprintf(fid, '## Tracking summary\n\n');
    fprintf(fid, '| PRN | status | mean C/N0 | max C/N0 | LONG%% |\n');
    fprintf(fid, '|----:|:------:|----------:|---------:|------:|\n');
    for i = 1:numel(smoke.trkSummary)
        r = smoke.trkSummary(i);
        fprintf(fid, '| %d | %s | %.1f | %.1f | %.1f |\n', ...
            r.PRN, r.status, r.meanCNo, r.maxCNo, r.pctLong);
    end

    fprintf(fid, '\n## Navigation summary\n\n');
    ns = smoke.navSummary;
    fprintf(fid, '- Fixes: %d\n', ns.nFixes);
    fprintf(fid, '- Eph OK SVs: %d\n', ns.nEphOk);
    fprintf(fid, '- Mean LLA: %.8f, %.8f, %.2f m\n', ns.meanLat, ns.meanLon, ns.meanH);
    fprintf(fid, '- ENU RMS (vs mean): %.3f m\n', ns.enuRms);
    fprintf(fid, '- Mean GDOP: %.2f\n\n', ns.meanDOP);

    fprintf(fid, '## MEX ROI ranking (top 20 by MexScore)\n\n');
    fprintf(fid, '| Rank | Function | Self [s] | Total [s] | Calls | MexScore | Candidate |\n');
    fprintf(fid, '|-----:|----------|---------:|----------:|------:|---------:|:---------:|\n');
    n = min(20, height(smoke.mexRank));
    for i = 1:n
        r = smoke.mexRank(i,:);
        fprintf(fid, '| %d | `%s` | %.3f | %.3f | %d | %.3f | %d |\n', i, ...
            r.FunctionName{1}, r.SelfTime, r.TotalTime, r.NumCalls, r.MexScore, r.MexCandidate);
    end

    fprintf(fid, '\n## Figures\n\n');
    for i = 1:numel(smoke.figFiles)
        [~, nm, ext] = fileparts(smoke.figFiles{i});
        fprintf(fid, '- `%s%s`\n', nm, ext);
    end
    fprintf(fid, '\n## Interpretation notes\n\n');
    fprintf(fid, '1. Highest **SelfTime** inside user code = best first MEX target.\n');
    fprintf(fid, '2. High **NumCalls** with moderate SelfTime: prefer vectorization or MEX batching.\n');
    fprintf(fid, '3. If almost all time is in `tracking2_v6_fix2` self-time, extract correlator/NCO kernel first.\n');
    fprintf(fid, '4. `parfor` multi-SV multiplies CPU; MEX multiplies per-channel throughput — do both.\n');
end
