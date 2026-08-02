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
    addParameter(p, 'openBaiduBrowser', true, @islogical);
    addParameter(p, 'closeFigures', false, @islogical);
    parse(p, varargin{:});

    settingsSource = isstruct(jsonPath);
    if settingsSource
        if ~isscalar(jsonPath)
            error('runFromJsonConfig:BadSettings', ...
                'Settings input must be a scalar struct');
        end
        raw = jsonPath;
        doPlotDefault = localTopFlag(raw, 'plotNavPost', true);
        doNmeaDefault = localNestedFlag(raw, 'nmea', 'enable', true);
        doBaiduDefault = localTopFlag(raw, 'plotBaiduMap', true);
    else
        jsonPath = char(jsonPath);
        if ~isfile(jsonPath)
            error('runFromJsonConfig:Missing', 'Config not found: %s', jsonPath);
        end
        raw = jsondecode(fileread(jsonPath));
        if ~isstruct(raw) || ~isscalar(raw)
            error('runFromJsonConfig:BadJson', 'JSON root must be an object');
        end
        doPlotDefault = true;
        doNmeaDefault = true;
        doBaiduDefault = true;
    end

    doNav   = localFlag(raw, 'doNavigation', true);
    doPlot  = localFlag(raw, 'doPlot', doPlotDefault);
    doNmea  = localFlag(raw, 'doNmea', doNmeaDefault);
    doBaidu = localFlag(raw, 'doBaiduMap', doBaiduDefault);
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

    if settingsSource
        settings = raw;
    else
        nv = localBuildInitArgs(raw);
        settings = initSettings(nv{:});
        settings = localApplyNested(settings, raw);
    end
    settings = localFinalizeSettings(settings, raw, settingsSource);
    settings.resultRoot = outDir;
    settings.tempdataSvPth = tempDir;
    settings.plotNavPost = doPlot;
    settings.plotBaiduMap = doBaidu && doPlot;
    if ~isfield(settings, 'nmea') || ~isstruct(settings.nmea)
        settings.nmea = struct('enable', doNmea);
    end
    settings.nmea.enable = doNmea;
    figuresBefore = [];
    if p.Results.closeFigures
        figuresBefore = findall(groot, 'Type', 'figure');
    end
    figureCleaner = onCleanup(@() localCloseNewFigures( ...
        figuresBefore, p.Results.closeFigures));

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
    report.errorIdentifier = '';
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
                    'openBaiduMap', doBaidu, ...
                    'openBaiduBrowser', p.Results.openBaiduBrowser);
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
        report.errorIdentifier = ME.identifier;
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
        'acqStep','fineNoncoh','fineCodeSearchHalfWinSamples','resamplingThreshold', ...
        'resamplingflag','dllNoiseBandwidth_pull','dllNoiseBandwidth_stab', ...
        'pllNoiseBandwidth_pull','pllNoiseBandwidth_stab','filter_pullinMS', ...
        'trackInit_MS','carrierAidCode','carrierAidCodeMaxHz','TrkCN0Th','CNo_Th', ...
        'CNoInterval','navSolPeriod','elevationMask','useTropCorr','plotNavPost', ...
        'plotBaiduMap','plotNavLegacy','navTrackMaxSpeedMps','REACQ_max','max_reacqT', ...
        'scint_updateMs','scint_bufLen','scint_fCutoff', ...
        'dllDampingRatio','dllCorrelatorSpacing','pllOrder','pllDampingRatio', ...
        'pllDampingRatio_pull','pllDampingRatio_stab','phaseDisType','phaseDisType_init', ...
        'reEstimateMS','longCoh_ms','intTime','pilotTRKflag','weilEstBuffLen', ...
        'weilConfTh','codeLength','codeFreqBasis','carrFreqBasis','startOffset','c', ...
        'IFBandwidth','skipNumberOfBytes','Th_static_dBm','FLLinitT', ...
        'REACQ_eachTimeWaitMs','pllDampingRatio_init','baiduMapKeyFile'};
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
        settings.pllNoiseBandwidth_init = settings.pllNoiseBandwidth_pull;
    end
    settings = localMergeStruct(settings, raw, 'FLL');
    settings = localMergeStruct(settings, raw, 'KF');
    settings = localMergeStruct(settings, raw, 'raim');
    settings = localMergeStruct(settings, raw, 'lsWeight');
    settings = localMergeStruct(settings, raw, 'nmea');
    settings = localMergeStruct(settings, raw, 'truePosition');
    settings = localSanitizeTruePosition(settings);
    settings = localMergeStruct(settings, raw, 'usrp');
    if isfield(settings, 'Th_static_dBm') && isfield(settings, 'usrp')
        try
            threshold_digdB = settings.Th_static_dBm - settings.usrp.scaleK - ...
                settings.usrp.gain + 10*log10(settings.samplingFreq);
            settings.PB_settings.Th_static = 10.^(threshold_digdB/20);
        catch
        end
    end
    % An explicitly supplied digital threshold takes precedence over dBm.
    settings = localMergeStruct(settings, raw, 'PB_settings');
end

function settings = localFinalizeSettings(settings, raw, settingsSource)
    required = {'filePath','fileName','dataType','fileType','samplingFreq', ...
        'skipNumberOfBytes','msToProcess'};
    for i = 1:numel(required)
        if ~isfield(settings, required{i})
            error('runFromJsonConfig:MissingSetting', ...
                'Required setting is missing: %s', required{i});
        end
    end

    bytesPerValue = localBytesPerValue(settings.dataType);
    if ~isnumeric(settings.fileType) || ~isscalar(settings.fileType) || ...
            ~isfinite(settings.fileType) || settings.fileType ~= round(settings.fileType) || ...
            ~ismember(round(double(settings.fileType)), [1 2])
        error('runFromJsonConfig:BadFileType', ...
            'fileType must be 1 (real) or 2 (IQ)');
    end
    settings.fileType = round(double(settings.fileType));
    settings.size_per_sample = settings.fileType * bytesPerValue;

    if ~isnumeric(settings.samplingFreq) || ~isscalar(settings.samplingFreq) || ...
            ~isfinite(settings.samplingFreq) || settings.samplingFreq <= 0
        error('runFromJsonConfig:BadSamplingFreq', ...
            'samplingFreq must be a positive finite scalar');
    end
    if ~isnumeric(settings.skipNumberOfBytes) || ...
            ~isscalar(settings.skipNumberOfBytes) || ...
            ~isfinite(settings.skipNumberOfBytes) || settings.skipNumberOfBytes < 0
        error('runFromJsonConfig:BadSkip', ...
            'skipNumberOfBytes must be a nonnegative finite scalar');
    end
    settings.skipNumberOfBytes = floor(double(settings.skipNumberOfBytes));

    requestedMs = double(settings.msToProcess);
    if ~settingsSource && isfield(raw, 'msToProcess')
        requestedMs = double(raw.msToProcess);
    end
    if ~isscalar(requestedMs) || ~isfinite(requestedMs) || requestedMs < 1
        error('runFromJsonConfig:BadDuration', ...
            'msToProcess must be a positive finite scalar');
    end

    fileInfo = dir(fullfile(settings.filePath, settings.fileName));
    if ~isempty(fileInfo)
        usableBytes = double(fileInfo(1).bytes) - settings.skipNumberOfBytes;
        maxMs = floor(1e3 * usableBytes / settings.size_per_sample / ...
            double(settings.samplingFreq) - 1e3);
        if maxMs < 1
            error('runFromJsonConfig:FileTooShort', ...
                'IF file is too short after skip/reserved tail: %s', ...
                fullfile(settings.filePath, settings.fileName));
        end
        settings.msToProcess = min(floor(requestedMs), maxMs);
        if settings.msToProcess < requestedMs
            warning('runFromJsonConfig:CapMs', ...
                'msToProcess capped to file length: %d ms', ...
                settings.msToProcess);
        end
    else
        settings.msToProcess = floor(requestedMs);
    end

    if ~settingsSource && ~isfield(raw, 'fineCodeSearchHalfWinSamples')
        settings.fineCodeSearchHalfWinSamples = ceil( ...
            2 * settings.samplingFreq / settings.codeFreqBasis);
    end
    if isfield(settings, 'REACQ_max')
        nReacq = max(0, round(double(settings.REACQ_max)));
        if ~isfield(settings, 'REACQ_eachTimeWaitMs') || ...
                numel(settings.REACQ_eachTimeWaitMs) ~= nReacq
            settings.REACQ_eachTimeWaitMs = 100 * (0:nReacq-1);
        end
    end
end

function n = localBytesPerValue(dataType)
    t = lower(strtrim(char(string(dataType))));
    arrow = strfind(t, '=>');
    if ~isempty(arrow), t = strtrim(t(1:arrow(1)-1)); end
    if startsWith(t, '*'), t = t(2:end); end
    switch t
        case {'int8','uint8','char','schar','uchar','logical'}
            n = 1;
        case {'int16','uint16','short','ushort'}
            n = 2;
        case {'int32','uint32','single','float','integer*4','real*4'}
            n = 4;
        case {'int64','uint64','double','integer*8','real*8'}
            n = 8;
        otherwise
            error('runFromJsonConfig:BadDataType', ...
                'Unsupported fread dataType: %s', t);
    end
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

function settings = localSanitizeTruePosition(settings)
    % jsondecode maps JSON null → []; plotNavPost/plotNavigation use scalar
    % isfinite/isnan &&/|| on E/N/U. Empty must become NaN.
    if ~isfield(settings, 'truePosition') || ~isstruct(settings.truePosition)
        settings.truePosition = struct('E', nan, 'N', nan, 'U', nan);
        return;
    end
    for f = {'E', 'N', 'U'}
        k = f{1};
        if ~isfield(settings.truePosition, k)
            settings.truePosition.(k) = nan;
            continue;
        end
        v = settings.truePosition.(k);
        if isempty(v) || ~isnumeric(v) || ~isscalar(v)
            settings.truePosition.(k) = nan;
        else
            settings.truePosition.(k) = double(v);
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
        nums = str2double(parts);
        if numel(nums) == 2 && all(isfinite(nums))
            list = nums(1):nums(2);
            return;
        elseif numel(nums) == 3 && all(isfinite(nums)) && nums(2) ~= 0
            list = nums(1):nums(2):nums(3);
            return;
        end
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
    if islogical(v) && isscalar(v), tf = v; return; end
    if isnumeric(v) && isscalar(v), tf = v ~= 0; return; end
    if ischar(v) || isstring(v)
        tf = any(strcmpi(strtrim(char(v)), {'1','true','yes','on'}));
    end
end

function tf = localTopFlag(raw, name, default)
    tf = default;
    if isfield(raw, name)
        value = raw.(name);
        if (islogical(value) || isnumeric(value)) && isscalar(value)
            tf = logical(value);
        end
    end
end

function tf = localNestedFlag(raw, parent, name, default)
    tf = default;
    if isfield(raw, parent) && isstruct(raw.(parent)) && ...
            isfield(raw.(parent), name)
        value = raw.(parent).(name);
        if (islogical(value) || isnumeric(value)) && isscalar(value)
            tf = logical(value);
        end
    end
end

function s = localStr(raw, name, default)
    s = default;
    if isfield(raw, name) && ~isempty(raw.(name))
        s = char(string(raw.(name)));
    end
end

function localCloseNewFigures(figuresBefore, enabled)
    if ~enabled, return; end
    figuresAfter = findall(groot, 'Type', 'figure');
    for i = 1:numel(figuresAfter)
        h = figuresAfter(i);
        try
            if isempty(figuresBefore) || ~any(h == figuresBefore)
                close(h);
            end
        catch
        end
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
