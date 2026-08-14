function smoke = smoke_tracking(varargin)
%SMOKE_TRACKING Single-satellite acquisition + short tracking smoke test.
%
%   smoke = smoke_tracking()
%   smoke = smoke_tracking('msToProcess', 5000, 'acqSatelliteList', 24)
%
% Does NOT run full navigation (needs >=24 s and >=4 SVs with eph).
% Use run_B2a(..., 'doNavigation', true) for positioning smoke.

    setupPaths();

    p = inputParser;
    p.KeepUnmatched = true;
    addParameter(p, 'msToProcess', 5000, @(x)isnumeric(x)&&isscalar(x));
    addParameter(p, 'acqSatelliteList', [24], @(x)isnumeric(x));
    addParameter(p, 'doQuickPlot', true, @islogical);
    parse(p, varargin{:});

    unmatched = namedargs2cell(p.Unmatched);
    settings = initSettings(unmatched{:}, ...
        'msToProcess', p.Results.msToProcess, ...
        'acqSatelliteList', p.Results.acqSatelliteList, ...
        'numberOfChannels', max(4, numel(p.Results.acqSatelliteList)), ...
        'plotTracking', 0, ...
        'EnablePB', true);

    [fid, dataAdaptCoeff] = openIfFile(settings);
    cleaner = onCleanup(@() safeClose(fid)); %#ok<NASGU>

    acqResults = runAcquisition(fid, settings, dataAdaptCoeff);
    if ~any(isfinite(acqResults.carrFreq) & acqResults.carrFreq ~= 0)
        error('smoke_tracking:NoAcq', 'No satellite acquired — abort tracking smoke.');
    end

    channel = preRun2(acqResults, settings);
    showChannelStatus(channel, settings);

    t0 = tic;
    [trackResults, channel] = tracking2_v6_fix2(fid, channel, settings);
    elapsed = toc(t0);

    % Quick correlator sanity plot for channel 1 if present
    if p.Results.doQuickPlot
        try
            tr = trackResults(1);
            N = min(500, numel(tr.Pilot_I_P));
            if N > 10 && any(isfinite(tr.Pilot_I_P(1:N)))
                figure('Name', 'Smoke tracking correlators');
                subplot(2,1,1);
                plot(1e-3*(1:N), tr.Pilot_I_P(1:N).^2 + tr.Pilot_Q_P(1:N).^2); hold on;
                plot(1e-3*(1:N), tr.Pilot_I_E(1:N).^2 + tr.Pilot_Q_E(1:N).^2);
                plot(1e-3*(1:N), tr.Pilot_I_L(1:N).^2 + tr.Pilot_Q_L(1:N).^2);
                title(sprintf('Pilot correlators PRN %d', tr.PRN));
                legend('P','E','L'); grid on; xlabel('s');
                subplot(2,1,2);
                plot(1e-3*(1:N), tr.I_P(1:N).^2 + tr.Q_P(1:N).^2); hold on;
                plot(1e-3*(1:N), tr.I_E(1:N).^2 + tr.Q_E(1:N).^2);
                plot(1e-3*(1:N), tr.I_L(1:N).^2 + tr.Q_L(1:N).^2);
                title('Data correlators'); legend('P','E','L'); grid on; xlabel('s');
            end
        catch ME
            warning('smoke_tracking:Plot', '%s', ME.message);
        end
    end

    % Summary metrics
    summary = [];
    for k = 1:numel(trackResults)
        if trackResults(k).PRN == 0, continue; end
        s = struct();
        s.PRN = trackResults(k).PRN;
        s.status = trackResults(k).status;
        cno = trackResults(k).B2a_CNo;
        cno = cno(isfinite(cno));
        if isempty(cno)
            s.meanCNo = NaN;
            s.maxCNo = NaN;
        else
            s.meanCNo = mean(cno);
            s.maxCNo = max(cno);
        end
        ip = trackResults(k).Pilot_I_P;
        ip = ip(isfinite(ip));
        s.meanPilotPower = mean(abs(ip).^2);
        summary = [summary; s]; %#ok<AGROW>
        fprintf('PRN %02d status=%s meanCNo=%.1f maxCNo=%.1f mean|Pp|^2=%.3g\n', ...
            s.PRN, s.status, s.meanCNo, s.maxCNo, s.meanPilotPower);
    end

    smoke = struct();
    smoke.settings = settings;
    smoke.acqResults = acqResults;
    smoke.channel = channel;
    smoke.trackResults = trackResults;
    smoke.summary = summary;
    smoke.elapsed_s = elapsed;

    outDir = fullfile(settings.resultRoot, 'smoke');
    if ~exist(outDir, 'dir'), mkdir(outDir); end
    outFile = fullfile(outDir, sprintf('trk_%s.mat', ...
        string(datetime('now'), 'yyMMdd_HHmmss')));
    save(outFile, 'smoke', '-v7.3');
    fprintf('Tracking smoke done in %.1f s. Saved: %s\n', elapsed, outFile);
end

function safeClose(fid)
    if ~isempty(fid) && fid > 0
        try, fclose(fid); catch, end %#ok<CTCH>
    end
end
