function smoke = resume_pvt_from_track(tempDir, varargin)
%RESUME_PVT_FROM_TRACK Load final TrackResults2 mats and finish nav+plots+report.
%
%   smoke = resume_pvt_from_track(tempDir)
%   smoke = resume_pvt_from_track(tempDir, 'msToProcess', 38000, ...)
%
% Used when tracking finished but navigation bridge failed mid-smoke.

    setupPaths();
    p = inputParser;
    addParameter(p, 'msToProcess', 38000);
    addParameter(p, 'acqSatelliteList', [41 39 38 24]);
    addParameter(p, 'tag', string(datetime('now'), 'yyMMdd_HHmmss'));
    addParameter(p, 'EnablePB', true);
    parse(p, varargin{:});

    settings = initSettings( ...
        'msToProcess', p.Results.msToProcess, ...
        'acqSatelliteList', p.Results.acqSatelliteList, ...
        'numberOfChannels', 12, ...
        'plotTracking', 0, ...
        'EnablePB', p.Results.EnablePB);
    settings.tempdataSvPth = tempDir;

    tag = char(p.Results.tag);
    outDir = fullfile(settings.resultRoot, 'smoke', ['pvt_' tag]);
    figDir = fullfile(outDir, 'figures');
    if ~exist(figDir, 'dir'), mkdir(figDir); end
    set(0, 'DefaultFigureVisible', 'off');

    prns = p.Results.acqSatelliteList(:).';
    nCh = settings.numberOfChannels;
    trackResults = TrackResults2.createArray(settings, nCh);

    for i = 1:numel(prns)
        f = fullfile(tempDir, sprintf('Trk_Prn_%02d_final.mat', prns(i)));
        if ~exist(f, 'file')
            error('resume_pvt:Missing', 'Missing %s', f);
        end
        S = load(f);
        if isfield(S, 'finalTRes')
            tr = S.finalTRes;
        elseif isfield(S, 'obj')
            tr = S.obj;
        else
            error('resume_pvt:BadMat', 'No finalTRes in %s', f);
        end
        trackResults(i) = tr;
        trackResults(i).status = 'T';
        fprintf('Loaded PRN %d from %s (N=%d)\n', prns(i), f, trackResults(i).Nsize);
    end

    stage = struct('acq_s', NaN, 'track_s', NaN, 'nav_s', NaN, 'plot_s', NaN, 'total_s', NaN);
    t0 = tic;
    [navSolutions, eph] = runNavigation(trackResults, settings);
    stage.nav_s = toc(t0);
    fprintf('Nav stage: %.2f s\n', stage.nav_s);

    % Reuse plot helpers from smoke_pvt via local copies of logic
    t0 = tic;
    figFiles = localExportFigures(trackResults, navSolutions, settings, figDir);
    stage.plot_s = toc(t0);

    trkSummary = localTrkSummary(trackResults);
    navSummary = localNavSummary(navSolutions, eph);

    smoke = struct();
    smoke.tag = tag;
    smoke.settings = settings;
    smoke.trackResults = trackResults;
    smoke.navSolutions = navSolutions;
    smoke.eph = eph;
    smoke.stage = stage;
    smoke.trkSummary = trkSummary;
    smoke.navSummary = navSummary;
    smoke.figFiles = figFiles;
    smoke.outDir = outDir;
    smoke.tempDir = tempDir;
    smoke.mexRank = table();
    smoke.profTable = table();

    save(fullfile(outDir, 'results.mat'), 'smoke', '-v7.3');
    writeResumeReport(smoke, fullfile(outDir, 'report_pvt.md'));
    fprintf('Saved %s\n', fullfile(outDir, 'results.mat'));
    if navSummary.nFixes > 0
        fprintf('PVT_RESUME=PASS fixes=%d enuRms=%.2f\n', navSummary.nFixes, navSummary.enuRms);
    else
        fprintf('PVT_RESUME=PARTIAL no fixes\n');
    end
end

function s = localTrkSummary(trackResults)
    s = struct('PRN', {}, 'status', {}, 'meanCNo', {}, 'maxCNo', {}, 'pctLong', {});
    for k = 1:numel(trackResults)
        if trackResults(k).PRN == 0, continue; end
        r.PRN = trackResults(k).PRN;
        r.status = char(string(trackResults(k).status));
        cno = trackResults(k).B2a_CNo; cno = cno(isfinite(cno));
        r.meanCNo = mean(cno); r.maxCNo = max(cno);
        st = trackResults(k).cur_state;
        r.pctLong = 100 * mean(logical(st));
        s(end+1) = r; %#ok<AGROW>
        fprintf('TRK PRN%02d CNo mean/max=%.1f/%.1f LONG%%=%.1f\n', ...
            r.PRN, r.meanCNo, r.maxCNo, r.pctLong);
    end
end

function s = localNavSummary(navSolutions, eph)
    s = struct('nFixes',0,'nEphOk',0,'meanLat',NaN,'meanLon',NaN,'meanH',NaN,'enuRms',NaN,'meanDOP',NaN);
    if isempty(navSolutions), return; end
    if ~isempty(eph)
        for k = 1:numel(eph)
            if isfield(eph(k),'idValid') && numel(eph(k).idValid) >= 3
                if eph(k).idValid(1)==10 && eph(k).idValid(2)==11 && any(ismember(eph(k).idValid(3:min(7,end)),30:34))
                    s.nEphOk = s.nEphOk + 1;
                end
            end
        end
    end
    if isfield(navSolutions,'E')
        ok = isfinite(navSolutions.E) & isfinite(navSolutions.N) & isfinite(navSolutions.U);
        s.nFixes = nnz(ok);
        if s.nFixes > 0
            E=navSolutions.E(ok); N=navSolutions.N(ok); U=navSolutions.U(ok);
            s.enuRms = sqrt(mean((E-mean(E)).^2 + (N-mean(N)).^2 + (U-mean(U)).^2));
            if isfield(navSolutions,'latitude')
                s.meanLat = mean(navSolutions.latitude(ok));
                s.meanLon = mean(navSolutions.longitude(ok));
                s.meanH = mean(navSolutions.height(ok));
            end
            if isfield(navSolutions,'DOP')
                s.meanDOP = mean(navSolutions.DOP(1,ok), 'omitnan');
            end
        end
    end
    fprintf('NAV fixes=%d ephOK=%d ENU_rms=%.2f lat/lon/h=%.6f/%.6f/%.1f\n', ...
        s.nFixes, s.nEphOk, s.enuRms, s.meanLat, s.meanLon, s.meanH);
end

function figFiles = localExportFigures(trackResults, navSolutions, settings, figDir)
    % Call smoke_pvt's nested logic via duplicated minimal export
    figFiles = {};
    for ch = 1:numel(trackResults)
        if trackResults(ch).PRN == 0, continue; end
        prn = trackResults(ch).PRN;
        try
            f = figure('Visible','off','Color','w','Position',[50 50 1200 900]);
            N = min(settings.msToProcess, numel(trackResults(ch).I_P));
            t = (1:N)*1e-3;
            subplot(3,2,1);
            plot(t, trackResults(ch).Pilot_I_P(1:N).^2+trackResults(ch).Pilot_Q_P(1:N).^2); hold on;
            plot(t, trackResults(ch).Pilot_I_E(1:N).^2+trackResults(ch).Pilot_Q_E(1:N).^2);
            plot(t, trackResults(ch).Pilot_I_L(1:N).^2+trackResults(ch).Pilot_Q_L(1:N).^2);
            grid on; legend('P','E','L'); title(sprintf('PRN %d Pilot power', prn));
            subplot(3,2,2);
            plot(t, trackResults(ch).I_P(1:N).^2+trackResults(ch).Q_P(1:N).^2); grid on; title('Data P power');
            subplot(3,2,3);
            plot(t, trackResults(ch).pllDiscr(1:N)); hold on; plot(t, trackResults(ch).pllDiscrFilt(1:N));
            grid on; legend('raw','filt'); title('PLL');
            subplot(3,2,4);
            plot(t, trackResults(ch).dllDiscr(1:N)); hold on; plot(t, trackResults(ch).dllDiscrFilt(1:N));
            grid on; legend('raw','filt'); title('DLL');
            subplot(3,2,5);
            plot(t, trackResults(ch).carrFreq(1:N)); grid on; title('Carrier freq');
            subplot(3,2,6);
            cno = trackResults(ch).B2a_CNo;
            tc = (1:numel(cno))*settings.CNoInterval*1e-3;
            plot(tc, cno, '-o', 'MarkerSize', 3); grid on; title('C/N0'); ylim([20 55]);
            fpath = fullfile(figDir, sprintf('trk_PRN%02d.png', prn));
            exportgraphics(f, fpath, 'Resolution', 150); close(f);
            figFiles{end+1} = fpath; %#ok<AGROW>
        catch ME
            warning('fig: %s', ME.message);
        end
    end
    if ~isempty(navSolutions) && isfield(navSolutions,'E')
        ok = isfinite(navSolutions.E) & isfinite(navSolutions.N);
        if any(ok)
            try
                f = figure('Visible','off','Color','w','Position',[50 50 1200 800]);
                subplot(2,2,1);
                plot(navSolutions.E(ok)-mean(navSolutions.E(ok)), navSolutions.N(ok)-mean(navSolutions.N(ok)), '.');
                axis equal; grid on; xlabel('\Delta E'); ylabel('\Delta N'); title('Horizontal scatter');
                subplot(2,2,2);
                plot(find(ok), navSolutions.U(ok)-mean(navSolutions.U(ok)), '.-'); grid on; title('Up residual');
                subplot(2,2,3);
                if isfield(navSolutions,'latitude')
                    plot(navSolutions.longitude(ok), navSolutions.latitude(ok), '.-'); grid on;
                    xlabel('lon'); ylabel('lat'); title('LLA track');
                end
                subplot(2,2,4);
                if isfield(navSolutions,'DOP')
                    plot(navSolutions.DOP(1,:), '.-'); hold on;
                    if size(navSolutions.DOP,1)>=4
                        plot(navSolutions.DOP(2:4,:).'); legend('GDOP','PDOP','HDOP','VDOP');
                    end
                    grid on; title('DOP');
                end
                fpath = fullfile(figDir, 'nav_overview.png');
                exportgraphics(f, fpath, 'Resolution', 150); close(f);
                figFiles{end+1} = fpath;
            catch ME
                warning('navfig: %s', ME.message);
            end
        end
    end
end

function writeResumeReport(smoke, path)
    fid = fopen(path, 'w');
    if fid < 0, return; end
    cleaner = onCleanup(@() fclose(fid));
    fprintf(fid, '# PVT Resume Report (%s)\n\n', smoke.tag);
    fprintf(fid, 'Recovered track results from: `%s`\n\n', smoke.tempDir);
    fprintf(fid, '## Tracking\n\n');
    for i = 1:numel(smoke.trkSummary)
        r = smoke.trkSummary(i);
        fprintf(fid, '- PRN %d: C/N0 mean/max %.1f/%.1f, LONG %.1f%%\n', ...
            r.PRN, r.meanCNo, r.maxCNo, r.pctLong);
    end
    ns = smoke.navSummary;
    fprintf(fid, '\n## Navigation\n\n');
    fprintf(fid, '- Fixes: %d\n- Eph OK: %d\n- ENU RMS: %.3f m\n', ns.nFixes, ns.nEphOk, ns.enuRms);
    fprintf(fid, '- Mean LLA: %.8f, %.8f, %.2f m\n- Mean GDOP: %.2f\n', ...
        ns.meanLat, ns.meanLon, ns.meanH, ns.meanDOP);
    fprintf(fid, '\n## Figures\n\n');
    for i = 1:numel(smoke.figFiles)
        [~,nm,ext] = fileparts(smoke.figFiles{i});
        fprintf(fid, '- `%s%s`\n', nm, ext);
    end
end
