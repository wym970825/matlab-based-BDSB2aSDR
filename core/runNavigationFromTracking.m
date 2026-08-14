function report = runNavigationFromTracking(resultPath, varargin)
%RUNNAVIGATIONFROMTRACKING Re-run PVT/NMEA from saved tracking results.
%
%   report = runNavigationFromTracking(runDir)
%   report = runNavigationFromTracking(tempDir, 'Config', jsonPath)
%
% RESULTPATH is either a receiver run directory or its TEMP directory. The
% function discovers every Trk_Prn_*_final.mat file, restores settings from
% ui_results.mat and/or a JSON config, runs navigation, and atomically
% replaces <runDir>/pvt.nmea. Acquisition and tracking are not re-run.
%
% Name-value options:
%   Config       JSON file or settings struct; overrides saved settings
%   OutputFile   NMEA path (default <runDir>/pvt.nmea)
%   SaveResults  Save <runDir>/navigation_replay.mat (default true)
%   ForceNmea    Export even when settings.nmea.enable=false (default true)
%   PlotNavigation Export and close offline PVT figures (default true)
%   FigureDir    Figure directory (default <runDir>/figures/navResult)

    setupPaths();
    p = inputParser;
    p.FunctionName = 'runNavigationFromTracking';
    addParameter(p, 'Config', [], @(x) isempty(x) || isstruct(x) || ...
        ischar(x) || (isstring(x) && isscalar(x)));
    addParameter(p, 'OutputFile', '', @(x) ischar(x) || ...
        (isstring(x) && isscalar(x)));
    addParameter(p, 'SaveResults', true, @localLogicalScalar);
    addParameter(p, 'ForceNmea', true, @localLogicalScalar);
    addParameter(p, 'PlotNavigation', true, @localLogicalScalar);
    addParameter(p, 'FigureDir', '', @(x) ischar(x) || ...
        (isstring(x) && isscalar(x)));
    parse(p, varargin{:});
    opt = p.Results;

    [runDir, tempDir] = localResolveDirectories(resultPath);
    [trackResults, prns, trackFiles] = localLoadTracking(tempDir);
    [settings, settingsSources] = localLoadSettings(runDir, opt.Config);
    settings.numberOfChannels = numel(trackResults);
    settings.tempdataSvPth = tempDir;
    settings.resultRoot = runDir;
    settings.msToProcess = localTrackingLength(trackResults, settings);

    outputFile = char(opt.OutputFile);
    if isempty(outputFile)
        outputFile = fullfile(runDir, localNmeaFileName(settings));
    elseif isempty(fileparts(outputFile))
        outputFile = fullfile(runDir, outputFile);
    end
    outputDir = fileparts(outputFile);
    if ~exist(outputDir, 'dir'), mkdir(outputDir); end

    fprintf('\n========== Navigation replay ==========\n');
    fprintf('runDir       = %s\n', runDir);
    fprintf('tracking SVs = %s\n', mat2str(prns));
    fprintf('duration     = %g ms\n', settings.msToProcess);
    fprintf('settings     = %s\n', strjoin(settingsSources, ', '));

    started = tic;
    [navSolutions, eph] = runNavigation(trackResults, settings);
    if isempty(navSolutions)
        error('runNavigationFromTracking:NoNavigation', ...
            'Navigation produced no solution; the existing NMEA was not changed.');
    end

    tempName = sprintf('.%s.replay-%s.tmp', localBaseName(outputFile), ...
        char(string(datetime('now'), 'yyyyMMddHHmmssSSS')));
    tempNmea = fullfile(outputDir, tempName);
    cleanup = onCleanup(@() localDeleteTemp(tempNmea));
    generated = exportNmea(navSolutions, settings, ...
        'trackResults', trackResults, 'eph', eph, 'outDir', outputDir, ...
        'fileName', tempName, 'force', logical(opt.ForceNmea));
    if isempty(generated) || ~isfile(generated)
        error('runNavigationFromTracking:NoNmea', ...
            'NMEA export failed; the existing NMEA was not changed.');
    end
    [moveOk, moveMessage] = movefile(generated, outputFile, 'f');
    if ~moveOk
        error('runNavigationFromTracking:ReplaceNmea', ...
            'Could not replace %s: %s', outputFile, moveMessage);
    end

    validFix = isfinite(navSolutions.latitude) & ...
        isfinite(navSolutions.longitude);
    [usageTable, usageSummary] = localUsageStatistics( ...
        trackResults, navSolutions, eph);
    usageCsv = fullfile(runDir, 'navigation_satellite_usage.csv');
    writetable(usageTable, usageCsv);

    figureDir = char(opt.FigureDir);
    if isempty(figureDir)
        figureDir = fullfile(runDir, 'figures', 'navResult');
    elseif isempty(fileparts(figureDir))
        figureDir = fullfile(runDir, figureDir);
    end
    figureFiles = {};
    if logical(opt.PlotNavigation) && any(validFix)
        settings.plotNavPost = true;
        settings.plotBaiduMap = false;
        navFigs = plotNavPost(navSolutions, settings, ...
            'saveDir', figureDir, 'doLegacy', false, ...
            'openBaiduMap', false, 'openBaiduBrowser', false);
        figureFiles = localFigureFiles(figureDir);
        localCloseFigureStruct(navFigs);
        drawnow;
    end
    report = struct();
    report.ok = true;
    report.runDir = runDir;
    report.tempDir = tempDir;
    report.settingsSources = settingsSources;
    report.trackFiles = trackFiles;
    report.prns = prns;
    report.nChannels = numel(prns);
    report.nEpochs = numel(navSolutions.latitude);
    report.nFixes = nnz(validFix);
    report.nmeaPath = outputFile;
    report.resultsPath = '';
    report.figureDir = figureDir;
    report.figureFiles = figureFiles;
    report.usageCsv = usageCsv;
    report.usage = usageSummary;
    report.elapsedSeconds = toc(started);

    if opt.SaveResults
        report.resultsPath = fullfile(runDir, 'navigation_replay.mat');
        generatedAt = datetime('now');
        save(report.resultsPath, 'navSolutions', 'eph', 'settings', ...
            'prns', 'trackFiles', 'usageTable', 'usageSummary', ...
            'generatedAt', '-v7.3');
    end
    fprintf('Navigation replay complete: fixes=%d/%d, NMEA=%s\n', ...
        report.nFixes, report.nEpochs, report.nmeaPath);
end

function tf = localLogicalScalar(value)
    tf = (islogical(value) || isnumeric(value)) && isscalar(value) ...
        && isfinite(double(value));
end

function [runDir, tempDir] = localResolveDirectories(resultPath)
    path = char(resultPath);
    if ~isfolder(path)
        error('runNavigationFromTracking:MissingPath', ...
            'Result directory does not exist: %s', path);
    end
    [parent, name] = fileparts(path);
    if strcmpi(name, 'temp')
        runDir = parent;
        tempDir = path;
    elseif isfolder(fullfile(path, 'temp'))
        runDir = path;
        tempDir = fullfile(path, 'temp');
    elseif ~isempty(dir(fullfile(path, 'Trk_Prn_*_final.mat')))
        % Interrupted/manual runs may use a timestamped directory directly
        % below results/temp. Keep all replay outputs next to those finals.
        runDir = path;
        tempDir = path;
    else
        error('runNavigationFromTracking:MissingTemp', ...
            'No temp directory was found below %s.', path);
    end
end

function [trackResults, prns, paths] = localLoadTracking(tempDir)
    files = dir(fullfile(tempDir, 'Trk_Prn_*_final.mat'));
    if isempty(files)
        error('runNavigationFromTracking:NoTrackingFiles', ...
            'No Trk_Prn_*_final.mat files found in %s.', tempDir);
    end
    prns = nan(1, numel(files));
    for idx = 1:numel(files)
        token = regexp(files(idx).name, '^Trk_Prn_(\d+)_final\.mat$', ...
            'tokens', 'once');
        if ~isempty(token), prns(idx) = str2double(token{1}); end
    end
    keep = isfinite(prns);
    files = files(keep);
    prns = prns(keep);
    [prns, order] = sort(prns);
    files = files(order);
    if isempty(files)
        error('runNavigationFromTracking:BadTrackingNames', ...
            'No tracking files had a supported PRN filename.');
    end

    channels = cell(1, numel(files));
    paths = cell(1, numel(files));
    for idx = 1:numel(files)
        paths{idx} = fullfile(files(idx).folder, files(idx).name);
        loaded = load(paths{idx});
        channel = localFindChannel(loaded, prns(idx), paths{idx});
        channels{idx} = localNavigationChannel(channel);
        clear loaded channel
        channels{idx}.PRN = prns(idx);
        channels{idx}.status = 'T';
    end
    trackResults = localNormalizeStructs(channels);
end

function channel = localFindChannel(loaded, expectedPrn, path)
    preferred = {'finalTRes', 'obj', 'trackResults'};
    names = [preferred, setdiff(fieldnames(loaded).', preferred, 'stable')];
    for nameIdx = 1:numel(names)
        value = loaded.(names{nameIdx});
        for valueIdx = 1:numel(value)
            item = value(valueIdx);
            if isobject(item) && ismethod(item, 'toStruct')
                item = item.toStruct();
            end
            if ~isstruct(item) || ~isscalar(item) || ~isfield(item, 'PRN')
                continue;
            end
            if isempty(item.PRN) || item.PRN == expectedPrn
                channel = item;
                return;
            end
        end
    end
    error('runNavigationFromTracking:BadTrackingFile', ...
        'No PRN %d tracking result found in %s.', expectedPrn, path);
end

function output = localNormalizeStructs(channels)
    fields = {};
    for idx = 1:numel(channels)
        names = fieldnames(channels{idx});
        fields = [fields; setdiff(names, fields, 'stable')]; %#ok<AGROW>
    end
    for idx = 1:numel(channels)
        for fieldIdx = 1:numel(fields)
            name = fields{fieldIdx};
            if ~isfield(channels{idx}, name), channels{idx}.(name) = []; end
        end
        channels{idx} = orderfields(channels{idx}, fields);
    end
    output = [channels{:}];
end

function channel = localNavigationChannel(channel)
    if isobject(channel) && ismethod(channel, 'toStruct')
        channel = channel.toStruct();
    end
    keepNames = {'PRN', 'status', 'Nsize', 'CNoInterval', 'I_P', ...
        'trk_state', 'reacqLoopCnt', 'absoluteSample', 'codeFreq', ...
        'remCodePhase', 'B2a_CNo'};
    output = struct();
    for idx = 1:numel(keepNames)
        name = keepNames{idx};
        if isfield(channel, name), output.(name) = channel.(name); end
    end
    n = localValidTrackingLength(output);
    cnoInterval = 200;
    if isfield(output, 'CNoInterval') && isfinite(output.CNoInterval) ...
            && output.CNoInterval > 0
        cnoInterval = max(1, round(output.CNoInterval));
    end
    oneMsFields = {'I_P', 'trk_state', 'absoluteSample', 'codeFreq', ...
        'remCodePhase'};
    for idx = 1:numel(oneMsFields)
        name = oneMsFields{idx};
        if isfield(output, name) && isvector(output.(name))
            value = output.(name);
            output.(name) = value(1:min(n, numel(value)));
        end
    end
    if isfield(output, 'B2a_CNo') && isvector(output.B2a_CNo)
        nCno = min(numel(output.B2a_CNo), max(1, ceil(n / cnoInterval)));
        output.B2a_CNo = output.B2a_CNo(1:nCno);
    end
    if isfield(output, 'reacqLoopCnt')
        output.reacqLoopCnt = output.reacqLoopCnt( ...
            isfinite(output.reacqLoopCnt) & output.reacqLoopCnt <= n);
    end
    output.Nsize = n;
    channel = output;
end

function n = localValidTrackingLength(channel)
    fields = {'absoluteSample', 'I_P', 'codeFreq', 'remCodePhase'};
    last = [];
    for idx = 1:numel(fields)
        name = fields{idx};
        if ~isfield(channel, name), continue; end
        value = channel.(name);
        lastFinite = find(isfinite(value), 1, 'last');
        if ~isempty(lastFinite), last(end + 1) = lastFinite; end %#ok<AGROW>
    end
    if isempty(last)
        n = max(1, floor(double(channel.Nsize)));
    else
        n = min(last);
    end
end

function [settings, sources] = localLoadSettings(runDir, supplied)
    settings = [];
    sources = {};
    savedPath = fullfile(runDir, 'ui_results.mat');
    if isfile(savedPath)
        variables = whos('-file', savedPath);
        if any(strcmp({variables.name}, 'settings'))
            loaded = load(savedPath, 'settings');
            if isstruct(loaded.settings) && isscalar(loaded.settings)
                settings = localSettingsDefaults(loaded.settings);
                settings = localMerge(settings, loaded.settings);
                settings = localApplyNmeaAlias(settings, loaded.settings);
                sources{end + 1} = savedPath;
            end
        end
    end

    if isempty(supplied)
        jsonPath = fullfile(runDir, 'ui_config.json');
        if isempty(settings) && isfile(jsonPath)
            config = localReadJson(jsonPath);
            settings = localSettingsDefaults(config);
            settings = localMerge(settings, config);
            settings = localApplyNmeaAlias(settings, config);
            sources{end + 1} = jsonPath;
        end
    elseif isstruct(supplied)
        if ~isscalar(supplied)
            error('runNavigationFromTracking:BadConfig', ...
                'Config struct must be scalar.');
        end
        if isempty(settings)
            settings = localSettingsDefaults(supplied);
        end
        settings = localMerge(settings, supplied);
        settings = localApplyNmeaAlias(settings, supplied);
        sources{end + 1} = 'Config struct';
    else
        jsonPath = char(supplied);
        config = localReadJson(jsonPath);
        if isempty(settings)
            settings = localSettingsDefaults(config);
        end
        settings = localMerge(settings, config);
        settings = localApplyNmeaAlias(settings, config);
        sources{end + 1} = jsonPath;
    end
    if isempty(settings)
        settings = initSettings();
        sources{end + 1} = 'initSettings defaults';
    end
end

function settings = localSettingsDefaults(config)
    args = {};
    names = {'msToProcess','filePath','fileName','EnablePB', ...
        'skipAcquisition','plotTracking','numberOfChannels', ...
        'useParfor','parMaxWorkers'};
    for idx = 1:numel(names)
        name = names{idx};
        if isfield(config, name)
            args{end + 1} = name; %#ok<AGROW>
            args{end + 1} = config.(name); %#ok<AGROW>
        end
    end
    if isfield(config, 'acqSatelliteList')
        args{end + 1} = 'acqSatelliteList';
        args{end + 1} = localPrnList(config.acqSatelliteList);
    end
    settings = initSettings(args{:});
end

function list = localPrnList(value)
    if isnumeric(value)
        list = double(value(:).');
        return;
    end
    text = strtrim(char(string(value)));
    tokens = regexp(text, '^\s*(\d+)\s*:\s*(\d+)\s*$', 'tokens', 'once');
    if ~isempty(tokens)
        list = str2double(tokens{1}):str2double(tokens{2});
        return;
    end
    list = sscanf(strrep(text, ',', ' '), '%f').';
    if isempty(list)
        error('runNavigationFromTracking:BadPrnList', ...
            'Could not parse acqSatelliteList: %s', text);
    end
end

function settings = localApplyNmeaAlias(settings, source)
    if isfield(source, 'nmea') && isstruct(source.nmea) ...
            && isfield(source.nmea, 'bdtMinusUtc') ...
            && ~isfield(source.nmea, 'utcOffsetSeconds')
        settings.nmea.utcOffsetSeconds = source.nmea.bdtMinusUtc;
    end
end

function value = localReadJson(path)
    if ~isfile(path)
        error('runNavigationFromTracking:MissingConfig', ...
            'Config file does not exist: %s', path);
    end
    value = jsondecode(fileread(path));
    if ~isstruct(value) || ~isscalar(value)
        error('runNavigationFromTracking:BadConfig', ...
            'Config JSON root must be an object: %s', path);
    end
end

function target = localMerge(target, source)
    names = fieldnames(source);
    for idx = 1:numel(names)
        name = names{idx};
        value = source.(name);
        if isstruct(value) && isscalar(value) && isfield(target, name) ...
                && isstruct(target.(name)) && isscalar(target.(name))
            target.(name) = localMerge(target.(name), value);
        else
            target.(name) = value;
        end
    end
end

function n = localTrackingLength(trackResults, settings)
    lengths = nan(1, numel(trackResults));
    for idx = 1:numel(trackResults)
        if isfield(trackResults(idx), 'Nsize') && ...
                isfinite(trackResults(idx).Nsize) && trackResults(idx).Nsize > 0
            lengths(idx) = double(trackResults(idx).Nsize);
        elseif isfield(trackResults(idx), 'absoluteSample')
            lengths(idx) = numel(trackResults(idx).absoluteSample);
        end
    end
    lengths = lengths(isfinite(lengths) & lengths > 0);
    if isempty(lengths)
        n = settings.msToProcess;
    else
        n = max(lengths);
    end
end

function fileName = localNmeaFileName(settings)
    fileName = 'pvt.nmea';
    if isfield(settings, 'nmea') && isstruct(settings.nmea) && ...
            isfield(settings.nmea, 'fileName') && ~isempty(settings.nmea.fileName)
        fileName = char(settings.nmea.fileName);
    end
end

function name = localBaseName(path)
    [~, stem, extension] = fileparts(path);
    name = [stem extension];
end

function localDeleteTemp(path)
    if isfile(path), delete(path); end
end

function [usageTable, summary] = localUsageStatistics(trackResults, nav, eph)
    prns = double([trackResults.PRN]);
    nPrn = numel(prns);
    trackedSamples = zeros(nPrn, 1);
    towSegments = zeros(nPrn, 1);
    hasMsg10 = false(nPrn, 1);
    hasMsg11 = false(nPrn, 1);
    hasMsg30To34 = false(nPrn, 1);
    candidateEpochs = zeros(nPrn, 1);
    validPseudorangeEpochs = zeros(nPrn, 1);
    raimUsedEpochs = zeros(nPrn, 1);
    raimExcludedEpochs = zeros(nPrn, 1);

    for idx = 1:nPrn
        trackedSamples(idx) = localValidTrackingLength(trackResults(idx));
        if isfield(nav, 'towSeg') && idx <= numel(nav.towSeg)
            towSegments(idx) = numel(nav.towSeg{idx});
        end
        prn = prns(idx);
        if prn >= 1 && prn <= numel(eph) && isfield(eph(prn), 'idValid')
            ids = double(eph(prn).idValid(:).');
            if ~isempty(ids), hasMsg10(idx) = ids(1) == 10; end
            if numel(ids) >= 2, hasMsg11(idx) = ids(2) == 11; end
            if numel(ids) >= 3
                hasMsg30To34(idx) = any(ismember(ids(3:min(7, end)), 30:34));
            end
        end
        if isfield(nav, 'PRN') && idx <= size(nav.PRN, 1)
            candidateEpochs(idx) = nnz(nav.PRN(idx, :) == prn);
        end
        if isfield(nav, 'validPrn')
            validPseudorangeEpochs(idx) = localCountCellPrn(nav.validPrn, prn);
        end
        if isfield(nav, 'raim') && isfield(nav.raim, 'usedPRN')
            accepted = true(1, numel(nav.raim.usedPRN));
            if isfield(nav.raim, 'passed')
                nAccepted = min(numel(accepted), numel(nav.raim.passed));
                accepted(1:nAccepted) = logical(nav.raim.passed(1:nAccepted));
            end
            raimUsedEpochs(idx) = localCountCellPrn( ...
                nav.raim.usedPRN, prn, accepted);
        end
        if isfield(nav, 'raim') && isfield(nav.raim, 'excludedPRN')
            raimExcludedEpochs(idx) = localCountCellPrn( ...
                nav.raim.excludedPRN, prn);
        end
    end

    ephemerisComplete = hasMsg10 & hasMsg11 & hasMsg30To34;
    usageTable = table(prns(:), trackedSamples, towSegments, hasMsg10, ...
        hasMsg11, hasMsg30To34, ephemerisComplete, candidateEpochs, ...
        validPseudorangeEpochs, raimUsedEpochs, raimExcludedEpochs, ...
        'VariableNames', {'PRN', 'TrackedSamples', 'TowSegments', ...
        'HasMessage10', 'HasMessage11', 'HasMessage30To34', ...
        'EphemerisComplete', 'CandidateEpochs', ...
        'ValidPseudorangeEpochs', 'RaimUsedEpochs', ...
        'RaimExcludedEpochs'});

    summary = struct();
    summary.trackedPrns = prns;
    summary.towPrns = prns(towSegments > 0);
    summary.ephemerisPrns = prns(ephemerisComplete);
    summary.pseudorangePrns = prns(validPseudorangeEpochs > 0);
    summary.raimUsedPrns = prns(raimUsedEpochs > 0);
    summary.raimExcludedPrns = prns(raimExcludedEpochs > 0);
end

function count = localCountCellPrn(values, prn, mask)
    if nargin < 3, mask = true(1, numel(values)); end
    count = 0;
    for idx = 1:numel(values)
        if idx <= numel(mask) && mask(idx) && ~isempty(values{idx}) ...
                && any(double(values{idx}(:)) == prn)
            count = count + 1;
        end
    end
end

function files = localFigureFiles(figureDir)
    entries = dir(fullfile(figureDir, '*.png'));
    files = arrayfun(@(x) fullfile(x.folder, x.name), entries, ...
        'UniformOutput', false);
end

function localCloseFigureStruct(figs)
    if ~isstruct(figs), return; end
    names = fieldnames(figs);
    for idx = 1:numel(names)
        fig = figs.(names{idx});
        if ~isempty(fig) && all(isgraphics(fig)), close(fig); end
    end
end
