function report = repairUiResultDirectory(resultDir, varargin)
%REPAIRUIRESULTDIRECTORY Restore the portable UI product contract.
%
%   report = repairUiResultDirectory(resultDir)
%   report = repairUiResultDirectory(resultDir, 'SourceMat', sourcePath)
%
% Older receiver runs may contain only run_B2a_*.mat or
% navigation_replay.mat.  This function restores the lightweight products
% required by downstream tools without copying the multi-gigabyte tracking
% arrays into ui_results.mat:
%
%   ui_config.json, report.json, ui_results.mat
%
% The resulting ui_results.mat always exposes the same wrapper fields as a
% current UI run: settings, acqResults, channel, trackResults,
% navSolutions, and eph.  Unavailable acquisition/tracking values are [] and
% the recovery metadata is recorded in report.json.

    setupPaths();
    p = inputParser;
    p.FunctionName = 'repairUiResultDirectory';
    addRequired(p, 'resultDir', @(x) ischar(x) || (isstring(x) && isscalar(x)));
    addParameter(p, 'SourceMat', '', @(x) ischar(x) || (isstring(x) && isscalar(x)));
    addParameter(p, 'Force', false, @localLogicalScalar);
    parse(p, resultDir, varargin{:});

    resultDir = char(p.Results.resultDir);
    if ~isfolder(resultDir)
        error('repairUiResultDirectory:MissingDir', ...
            'Result directory does not exist: %s', resultDir);
    end
    resultDir = char(java.io.File(resultDir).getCanonicalPath());
    localPrepareLayout(resultDir);

    uiPath = fullfile(resultDir, 'ui_results.mat');
    configPath = fullfile(resultDir, 'ui_config.json');
    reportPath = fullfile(resultDir, 'report.json');
    sourcePath = char(p.Results.SourceMat);
    if isempty(sourcePath)
        sourcePath = localFindSource(resultDir);
    elseif ~isfile(sourcePath)
        error('repairUiResultDirectory:MissingSource', ...
            'Source MAT file does not exist: %s', sourcePath);
    end

    recovered = struct('settings', [], 'navSolutions', [], ...
        'eph', [], 'sourcePath', sourcePath, 'sourceKind', '');
    if ~logical(p.Results.Force) && isfile(uiPath)
        recovered = localLoadExisting(uiPath, recovered);
        recovered.sourceKind = 'existing ui_results.mat';
    else
        recovered = localLoadSource(sourcePath, recovered);
    end

    if isempty(recovered.navSolutions)
        error('repairUiResultDirectory:NoNavigation', ...
            'No navSolutions could be recovered from %s.', sourcePath);
    end

    % Save a portable, navigation-focused UI wrapper.  Tracking files stay
    % in temp/ and remain available to replayTrackingChannels.
    results = struct('settings', recovered.settings, ...
        'acqResults', [], 'channel', [], 'trackResults', [], ...
        'navSolutions', recovered.navSolutions, 'eph', recovered.eph);
    writeUiResultsMat(uiPath, results);

    settings = recovered.settings;
    config = localBuildConfig(settings, resultDir);
    localWriteJson(configPath, config);
    report = localBuildReport(resultDir, sourcePath, recovered, configPath, uiPath);
    localWriteJson(reportPath, report);
end

function localPrepareLayout(resultDir)
    dirs = {'temp', fullfile('figures', 'AcqResult'), ...
        fullfile('figures', 'trkResult'), fullfile('figures', 'navResult')};
    for k = 1:numel(dirs)
        path = fullfile(resultDir, dirs{k});
        if ~exist(path, 'dir'), mkdir(path); end
    end
end

function sourcePath = localFindSource(resultDir)
    candidates = dir(fullfile(resultDir, 'run_B2a_*.mat'));
    candidates = candidates(~[candidates.isdir]);
    if ~isempty(candidates)
        [~, order] = sort([candidates.datenum], 'descend');
        sourcePath = fullfile(candidates(order(1)).folder, ...
            candidates(order(1)).name);
        return
    end
    replayPath = fullfile(resultDir, 'navigation_replay.mat');
    if isfile(replayPath)
        sourcePath = replayPath;
        return
    end
    error('repairUiResultDirectory:NoSource', ...
        'No ui_results.mat, run_B2a_*.mat, or navigation_replay.mat under %s.', ...
        resultDir);
end

function recovered = localLoadExisting(uiPath, recovered)
    loaded = load(uiPath, 'results', 'settings', 'navSolutions', 'eph');
    [recovered.navSolutions, recovered.settings, recovered.eph] = ...
        localExtractLoaded(loaded, recovered.navSolutions, ...
        recovered.settings, recovered.eph);
end

function recovered = localLoadSource(sourcePath, recovered)
    loaded = load(sourcePath);
    recovered = localLoadFromStruct(loaded, recovered);
    clear loaded
end

function recovered = localLoadFromStruct(loaded, recovered)
    recovered.sourceKind = 'MAT source';
    if isfield(loaded, 'results') && isstruct(loaded.results)
        wrapper = loaded.results;
        if isfield(wrapper, 'navSolutions'), recovered.navSolutions = wrapper.navSolutions; end
        if isfield(wrapper, 'settings'), recovered.settings = wrapper.settings; end
        if isfield(wrapper, 'eph'), recovered.eph = wrapper.eph; end
    end
    [recovered.navSolutions, recovered.settings, recovered.eph] = ...
        localExtractLoaded(loaded, recovered.navSolutions, ...
        recovered.settings, recovered.eph);
end

function [navSolutions, settings, eph] = localExtractLoaded(loaded, navSolutions, settings, eph)
    if isempty(navSolutions) && isfield(loaded, 'navSolutions')
        navSolutions = loaded.navSolutions;
    end
    if (isempty(settings) || (isstruct(settings) && isempty(fieldnames(settings)))) && ...
            isfield(loaded, 'settings')
        settings = loaded.settings;
    end
    if isempty(eph) && isfield(loaded, 'eph')
        eph = loaded.eph;
    end
end

function config = localBuildConfig(settings, resultDir)
    if isstruct(settings) && isscalar(settings)
        config = settings;
    else
        config = struct();
    end
    config.outDir = strrep(resultDir, '\', '/');
    [~, tag] = fileparts(resultDir);
    config.tag = tag;
    config.doNavigation = true;
    config.doPlot = true;
    config.doNmea = isfile(fullfile(resultDir, 'pvt.nmea'));
    config.doBaiduMap = false;
    config.recovered = true;
    config.recoverySource = 'repairUiResultDirectory';
end

function report = localBuildReport(resultDir, sourcePath, recovered, configPath, uiPath)
    report = struct();
    report.ok = true;
    report.stage = 'recovered';
    report.outDir = resultDir;
    report.tag = localBaseName(resultDir);
    report.errorIdentifier = '';
    report.error = '';
    report.recovered = true;
    report.recoverySource = sourcePath;
    report.uiConfigPath = configPath;
    report.uiResultsPath = uiPath;
    report.nmeaPath = fullfile(resultDir, 'pvt.nmea');
    report.nAcquired = 0;
    report.navSummary = struct('nFixes', 0, 'meanLat', NaN, ...
        'meanLon', NaN, 'meanH', NaN);
    if isstruct(recovered.navSolutions) && ...
            isfield(recovered.navSolutions, 'latitude') && ...
            isfield(recovered.navSolutions, 'longitude')
        ok = isfinite(recovered.navSolutions.latitude) & ...
            isfinite(recovered.navSolutions.longitude);
        report.navSummary.nFixes = nnz(ok);
        if any(ok)
            report.navSummary.meanLat = mean(recovered.navSolutions.latitude(ok));
            report.navSummary.meanLon = mean(recovered.navSolutions.longitude(ok));
            if isfield(recovered.navSolutions, 'height')
                h = recovered.navSolutions.height(ok);
                h = h(isfinite(h));
                if ~isempty(h), report.navSummary.meanH = mean(h); end
            end
        end
    end
end

function localWriteJson(path, value)
    try
        text = jsonencode(value, 'PrettyPrint', true);
    catch
        text = jsonencode(value);
    end
    fid = fopen(path, 'w', 'n', 'UTF-8');
    if fid < 0
        error('repairUiResultDirectory:WriteJson', ...
            'Cannot write %s.', path);
    end
    cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
    fwrite(fid, text, 'char');
end

function name = localBaseName(path)
    [~, name] = fileparts(path);
end

function tf = localLogicalScalar(value)
    tf = (islogical(value) || isnumeric(value)) && isscalar(value);
end
