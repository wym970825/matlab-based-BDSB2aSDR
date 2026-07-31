function report = runFromJsonConfig(jsonPath, varargin)
%RUNFROMJSONCONFIG Run full B2a pipeline from a UI/JSON config file.
%
%   report = runFromJsonConfig(jsonPath)
%   report = runFromJsonConfig(jsonPath, 'outDir', dir)
%
% Invoked by Python web UI:
%   matlab -batch "cd('.../B2a'); setupPaths; runFromJsonConfig('cfg.json')"
% No interactive MATLAB desktop required.

    setupPaths();

    p = inputParser;
    addParameter(p, 'outDir', '', @(x) ischar(x) || isstring(x));
    parse(p, varargin{:});

    jsonPath = char(jsonPath);
    if ~isfile(jsonPath)
        error('runFromJsonConfig:Missing', 'Config not found: %s', jsonPath);
    end

    raw = jsondecode(fileread(jsonPath));
    if ~isstruct(raw)
        error('runFromJsonConfig:BadJson', 'JSON root must be an object');
    end

    doNav   = localFlag(raw, 'doNavigation', true);
    doPlot  = localFlag(raw, 'doPlot', true);
    doNmea  = localFlag(raw, 'doNmea', true);
    doBaidu = localFlag(raw, 'doBaiduMap', true);
    tag = localStr(raw, 'tag', char(string(datetime('now'), 'yyMMdd_HHmmss')));

    outDir = char(p.Results.outDir);
    if isempty(outDir)
        outDir = localStr(raw, 'outDir', '');
    end
    if isempty(outDir)
        root = fileparts(fileparts(mfilename('fullpath')));
        outDir = fullfile(root, 'results', 'ui', tag);
    end
    if ~exist(outDir, 'dir'), mkdir(outDir); end
    figDir = fullfile(outDir, 'figures');
    tempDir = fullfile(outDir, 'temp');
    if ~exist(tempDir, 'dir'), mkdir(tempDir); end
    if ~exist(figDir, 'dir'), mkdir(figDir); end

    nv = localBuildInitArgs(raw);
    settings = initSettings(nv{:});
    settings = localApplyNested(settings, raw);
    settings.resultRoot = outDir;
    settings.tempdataSvPth = tempDir;
    settings.plotNavPost = doPlot;
    settings.plotBaiduMap = doBaidu && doPlot;
    if ~isfield(settings, 'nmea') || ~isstruct(settings.nmea)
        settings.nmea = struct('enable', doNmea);
    end
    settings.nmea.enable = doNmea;

    fprintf('\n========== B2a UI pipeline ==========\n');
    fprintf('outDir      = %s\n', outDir);
    fprintf('IF          = %s\n', fullfile(settings.filePath, settings.fileName));
    fprintf('msToProcess = %g\n', settings.msToProcess);
    fprintf('acqList     = %s\n', mat2str(settings.acqSatelliteList));
    fprintf('nav/plot/nmea/baidu = %d/%d/%d/%d\n', doNav, doPlot, doNmea, doBaidu);

    report = struct();
    report.ok = false;
    report.outDir = outDir;
    report.figDir = figDir;
    report.tag = tag;
    report.stage = 'start';
    report.error = '';
    report.nmeaPath = '';
    report.nAcquired = 0;
    report.navSummary = struct('nFixes', 0, 'meanLat', NaN, 'meanLon', NaN, 'meanH', NaN);

    acqResults = [];
    trackResults = [];
    navSolutions = [];
    eph = [];
    channel = [];

    try
        [fid, dataAdaptCoeff] = openIfFile(settings);
        cleaner = onCleanup(@() localClose(fid));

        %% Acquisition
        report.stage = 'acquisition';
        fprintf('--- Acquisition ---\n');
        if settings.skipAcquisition
            error('runFromJsonConfig:SkipAcq', ...
                'skipAcquisition=true is not supported from UI yet');
        end
        acqResults = runAcquisition(fid, settings, dataAdaptCoeff);
        nAcq = 0;
        if isfield(acqResults, 'carrFreq')
            nAcq = nnz(isfinite(acqResults.carrFreq) & acqResults.carrFreq ~= 0);
        end
        report.nAcquired = nAcq;
        fprintf('Acquired SV count: %d\n', nAcq);
        if nAcq < 1
            error('runFromJsonConfig:NoAcq', 'No GNSS signals detected');
        end

        channel = preRun2(acqResults, settings);
        showChannelStatus(channel, settings);

        %% Tracking
        report.stage = 'tracking';
        fprintf('--- Tracking ---\n');
        t0 = datetime('now');
        [trackResults, channel] = tracking2_v6_fix2(fid, channel, settings);
        fprintf('Tracking done (%s)\n', char(string(datetime('now') - t0)));

        %% Navigation
        if doNav
            report.stage = 'navigation';
            fprintf('--- Navigation ---\n');
            [navSolutions, eph] = runNavigation(trackResults, settings);
            if doNmea && ~isempty(navSolutions)
                try
                    report.nmeaPath = exportNmea(navSolutions, settings, ...
                        'trackResults', trackResults, 'outDir', outDir);
                catch ME
                    warning('runFromJsonConfig:NMEA', '%s', ME.message);
                end
            end
        end

        %% Plot (Python/UI path always uses fixed figDir)
        if doPlot && ~isempty(navSolutions)
            report.stage = 'plot';
            fprintf('--- Plot / Baidu ---\n');
            try
                plotNavPost(navSolutions, settings, ...
                    'saveDir', figDir, ...
                    'doLegacy', false, ...
                    'openBaiduMap', doBaidu);
            catch ME
                warning('runFromJsonConfig:Plot', '%s', ME.message);
            end
        end

        if ~isempty(navSolutions) && isfield(navSolutions, 'latitude')
            ok = isfinite(navSolutions.latitude) & isfinite(navSolutions.longitude);
            report.navSummary.nFixes = nnz(ok);
            if any(ok)
                report.navSummary.meanLat = mean(navSolutions.latitude(ok));
                report.navSummary.meanLon = mean(navSolutions.longitude(ok));
                if isfield(navSolutions, 'height')
                    hh = navSolutions.height(ok);
                    report.navSummary.meanH = mean(hh(isfinite(hh)));
                end
            end
        end

        results = struct( ...
            'settings', settings, ...
            'acqResults', acqResults, ...
            'channel', channel, ...
            'trackResults', trackResults, ...
            'navSolutions', navSolutions, ...
            'eph', eph);
        save(fullfile(outDir, 'ui_results.mat'), 'results', 'settings', '-v7.3');
        save(fullfile(outDir, sprintf('run_B2a_%s.mat', tag)), 'results', '-v7.3');

        report.ok = true;
        report.stage = 'done';
        fprintf('========== UI pipeline DONE fixes=%d ==========\n', ...
            report.navSummary.nFixes);
    catch ME
        report.ok = false;
        report.error = ME.message;
        if strcmp(report.stage, 'start'), report.stage = 'failed'; end
        fprintf(2, 'FAILED at %s: %s\n', report.stage, ME.message);
        try
            fprintf(2, '%s\n', getReport(ME, 'basic'));
        catch
        end
    end

    writeReportJson(fullfile(outDir, 'report.json'), report);
    fprintf('report.json -> %s\n', fullfile(outDir, 'report.json'));
end

function localClose(fid)
    if ~isempty(fid) && fid > 0
        try, fclose(fid); catch, end %#ok<CTCH>
    end
end

function nv = localBuildInitArgs(raw)
    nv = {};
    keys = {'msToProcess','filePath','fileName','EnablePB','skipAcquisition', ...
        'plotTracking','numberOfChannels','useParfor','parMaxWorkers'};
    for i = 1:numel(keys)
        k = keys{i};
        if isfield(raw, k)
            nv{end+1} = k; %#ok<AGROW>
            nv{end+1} = raw.(k);
        end
    end
    if isfield(raw, 'acqSatelliteList')
        nv{end+1} = 'acqSatelliteList';
        nv{end+1} = localParsePrnList(raw.acqSatelliteList);
    end
end

function settings = localApplyNested(settings, raw)
    flat = { ...
        'samplingFreq','IF','dataType','fileType','acqSearchBand','acqThreshold', ...
        'acqStep','fineNoncoh','dllNoiseBandwidth_pull','dllNoiseBandwidth_stab', ...
        'pllNoiseBandwidth_pull','pllNoiseBandwidth_stab','filter_pullinMS', ...
        'trackInit_MS','carrierAidCode','carrierAidCodeMaxHz','TrkCN0Th','CNo_Th', ...
        'navSolPeriod','elevationMask','useTropCorr','plotNavPost','plotBaiduMap', ...
        'navTrackMaxSpeedMps','REACQ_max','max_reacqT','scint_updateMs', ...
        'dllDampingRatio','dllCorrelatorSpacing','pllOrder','pllDampingRatio'};
    for i = 1:numel(flat)
        k = flat{i};
        if isfield(raw, k)
            settings.(k) = raw.(k);
        end
    end
    % Keep DLL/PLL aliases consistent
    if isfield(settings, 'dllNoiseBandwidth_stab')
        settings.dllNoiseBandwidth = settings.dllNoiseBandwidth_stab;
    end
    if isfield(settings, 'pllNoiseBandwidth_stab')
        settings.pllNoiseBandwidth = settings.pllNoiseBandwidth_stab;
    end
    settings = localMergeStruct(settings, raw, 'FLL');
    settings = localMergeStruct(settings, raw, 'KF');
    settings = localMergeStruct(settings, raw, 'raim');
    settings = localMergeStruct(settings, raw, 'lsWeight');
    settings = localMergeStruct(settings, raw, 'nmea');
    settings = localMergeStruct(settings, raw, 'truePosition');
    settings = localMergeStruct(settings, raw, 'PB_settings');
end

function settings = localMergeStruct(settings, raw, name)
    if ~isfield(raw, name), return; end
    src = raw.(name);
    if isstruct(src)
        if ~isfield(settings, name) || ~isstruct(settings.(name))
            settings.(name) = struct();
        end
        f = fieldnames(src);
        for i = 1:numel(f)
            settings.(name).(f{i}) = src.(f{i});
        end
    end
end

function list = localParsePrnList(v)
    if isnumeric(v)
        list = double(v(:)');
        return;
    end
    if iscell(v)
        list = cellfun(@double, v);
        list = list(:)';
        return;
    end
    s = strtrim(char(string(v)));
    if contains(s, ':')
        parts = split(s, ':');
        list = str2double(parts{1}):str2double(parts{end});
        return;
    end
    s = strrep(s, ';', ',');
    parts = split(s, ',');
    list = [];
    for i = 1:numel(parts)
        x = str2double(strtrim(parts{i}));
        if isfinite(x), list(end+1) = x; end %#ok<AGROW>
    end
    if isempty(list), list = [24 38 39 41]; end
end

function tf = localFlag(raw, name, default)
    tf = default;
    if ~isfield(raw, name), return; end
    v = raw.(name);
    if islogical(v), tf = v; return; end
    if isnumeric(v), tf = v ~= 0; return; end
    if ischar(v) || isstring(v)
        tf = any(strcmpi(strtrim(char(v)), {'1','true','yes','on'}));
    end
end

function s = localStr(raw, name, default)
    s = default;
    if isfield(raw, name) && ~isempty(raw.(name))
        s = char(string(raw.(name)));
    end
end

function writeReportJson(path, report)
    % jsonencode may fail on some MATLAB versions with nested empties
    try
        txt = jsonencode(report);
    catch
        txt = sprintf(['{"ok":%s,"stage":"%s","outDir":"%s","error":"%s",' ...
            '"nAcquired":%d,"navSummary":{"nFixes":%d,"meanLat":%g,"meanLon":%g,"meanH":%g}}'], ...
            mat2str(logical(report.ok)), ...
            localEsc(report.stage), localEsc(report.outDir), localEsc(report.error), ...
            report.nAcquired, report.navSummary.nFixes, ...
            report.navSummary.meanLat, report.navSummary.meanLon, report.navSummary.meanH);
    end
    fid = fopen(path, 'w', 'n', 'UTF-8');
    if fid < 0, return; end
    cleaner = onCleanup(@() fclose(fid));
    fwrite(fid, txt, 'char');
end

function t = localEsc(s)
    t = char(string(s));
    t = strrep(t, '\', '/');
    t = strrep(t, '"', '''');
    t = strrep(t, newline, ' ');
end
