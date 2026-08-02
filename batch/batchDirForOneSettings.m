function batchReport = batchDirForOneSettings(inputDir, settingsSource, varargin)
%BATCHDIRFORONESETTINGS Process every matching IF file with one configuration.
%
%   report = batchDirForOneSettings(inputDir, settings)
%   report = batchDirForOneSettings(inputDir, jsonPath)
%
% settingsSource accepts either a scalar struct returned by initSettings or
% a JSON config path accepted by runFromJsonConfig. Files are processed
% sequentially; multi-SV parallelism inside each file remains controlled by
% settings.useParfor.
%
% Name-value options:
%   OutputRoot       Batch output directory (default results/batch/<tag>)
%   FilePattern      Input file pattern (default *.bin)
%   Recursive        Include subdirectories (default false)
%   ContinueOnError  Continue after a failed file (default true)
%   DryRun           Only discover files and write per-file configs
%   OpenBaiduBrowser Open a browser for each Baidu result (default false)
%   CloseFigures     Close figures created by each item (default true)
%   Tag              Batch tag used in output names

    setupPaths();

    p = inputParser;
    addRequired(p, 'inputDir', @(x) ischar(x) || isstring(x));
    addRequired(p, 'settingsSource', ...
        @(x) (isstruct(x) && isscalar(x)) || ischar(x) || isstring(x));
    addParameter(p, 'OutputRoot', '', @(x) ischar(x) || isstring(x));
    addParameter(p, 'FilePattern', '*.bin', ...
        @(x) ischar(x) || (isstring(x) && isscalar(x)));
    addParameter(p, 'Recursive', false, @localLogicalScalar);
    addParameter(p, 'ContinueOnError', true, @localLogicalScalar);
    addParameter(p, 'DryRun', false, @localLogicalScalar);
    addParameter(p, 'OpenBaiduBrowser', false, @localLogicalScalar);
    addParameter(p, 'CloseFigures', true, @localLogicalScalar);
    addParameter(p, 'Tag', char(string(datetime('now'), ...
        'yyMMdd_HHmmss')), @(x) ischar(x) || isstring(x));
    parse(p, inputDir, settingsSource, varargin{:});
    opt = p.Results;

    inputDir = char(inputDir);
    if ~isfolder(inputDir)
        error('batchDirForOneSettings:MissingInputDir', ...
            'Input directory not found: %s', inputDir);
    end
    inputDir = char(java.io.File(inputDir).getCanonicalPath());

    [baseConfig, sourceKind, sourceDescription] = ...
        localLoadSettingsSource(settingsSource);
    files = localFindFiles(inputDir, char(opt.FilePattern), ...
        logical(opt.Recursive));
    if isempty(files)
        error('batchDirForOneSettings:NoFiles', ...
            'No files matching %s under %s', opt.FilePattern, inputDir);
    end

    batchTag = localSafeName(char(opt.Tag));
    if isempty(batchTag)
        batchTag = char(string(datetime('now'), 'yyMMdd_HHmmss'));
    end
    outputRoot = char(opt.OutputRoot);
    if isempty(outputRoot)
        projectRoot = fileparts(fileparts(mfilename('fullpath')));
        [~, inputName] = fileparts(inputDir);
        outputRoot = fullfile(projectRoot, 'results', 'batch', ...
            sprintf('%s_%s', batchTag, localSafeName(inputName)));
    end
    localPrepareOutputRoot(outputRoot);

    sourceSnapshot = fullfile(outputRoot, 'source_config.json');
    localWriteJson(sourceSnapshot, baseConfig);

    itemTemplate = struct( ...
        'index', 0, ...
        'fileName', '', ...
        'inputPath', '', ...
        'outDir', '', ...
        'configPath', '', ...
        'logPath', '', ...
        'status', 'pending', ...
        'ok', false, ...
        'stage', 'pending', ...
        'elapsedSeconds', NaN, ...
        'nAcquired', 0, ...
        'nFixes', 0, ...
        'errorIdentifier', '', ...
        'error', '');
    items = repmat(itemTemplate, numel(files), 1);
    for i = 1:numel(files)
        inputPath = fullfile(files(i).folder, files(i).name);
        [~, stem] = fileparts(files(i).name);
        itemName = sprintf('%04d_%s', i, localSafeName(stem));
        items(i).index = i;
        items(i).fileName = files(i).name;
        items(i).inputPath = inputPath;
        items(i).outDir = fullfile(outputRoot, itemName);
        items(i).logPath = fullfile(items(i).outDir, 'matlab.log');
    end

    batchReport = struct();
    batchReport.ok = false;
    batchReport.stage = 'running';
    batchReport.tag = batchTag;
    batchReport.inputDir = inputDir;
    batchReport.outputRoot = outputRoot;
    batchReport.settingsSource = sourceDescription;
    batchReport.settingsKind = sourceKind;
    batchReport.filePattern = char(opt.FilePattern);
    batchReport.recursive = logical(opt.Recursive);
    batchReport.dryRun = logical(opt.DryRun);
    batchReport.startedAt = localNow();
    batchReport.finishedAt = '';
    batchReport.nFiles = numel(files);
    batchReport.nAttempted = 0;
    batchReport.nSucceeded = 0;
    batchReport.nFailed = 0;
    batchReport.nPlanned = 0;
    batchReport.items = items;
    localWriteBatchReport(batchReport);

    fprintf('\n========== B2a directory batch ==========\n');
    fprintf('inputDir   = %s\n', inputDir);
    fprintf('outputRoot = %s\n', outputRoot);
    fprintf('settings   = %s (%s)\n', sourceDescription, sourceKind);
    fprintf('files      = %d (%s, recursive=%d)\n', ...
        numel(files), opt.FilePattern, logical(opt.Recursive));

    for i = 1:numel(files)
        item = batchReport.items(i);
        if ~exist(item.outDir, 'dir'), mkdir(item.outDir); end
        [~, stem] = fileparts(item.fileName);
        itemTag = sprintf('%s_%04d_%s', batchTag, i, localSafeName(stem));
        started = tic;
        figuresBefore = findall(groot, 'Type', 'figure');
        diaryCleaner = [];
        if ~opt.DryRun
            diary(item.logPath);
            diaryCleaner = onCleanup(@() diary('off'));
        end

        fprintf('\n--- Batch item %d/%d: %s ---\n', ...
            i, numel(files), item.inputPath);
        try
            if strcmp(sourceKind, 'json')
                config = baseConfig;
                config.filePath = files(i).folder;
                config.fileName = files(i).name;
                config.outDir = strrep(item.outDir, '\', '/');
                config.tag = itemTag;
                item.configPath = fullfile(item.outDir, 'ui_config.json');
                localWriteJson(item.configPath, config);
                if opt.DryRun
                    runReport = localPlannedReport(item.outDir);
                else
                    runReport = runFromJsonConfig(item.configPath, ...
                        'outDir', item.outDir, ...
                        'openBaiduBrowser', logical(opt.OpenBaiduBrowser), ...
                        'closeFigures', logical(opt.CloseFigures));
                end
            else
                settings = baseConfig;
                settings.filePath = files(i).folder;
                settings.fileName = files(i).name;
                settings.resultRoot = item.outDir;
                settings.tempdataSvPth = fullfile(item.outDir, 'temp');
                item.configPath = fullfile(item.outDir, 'settings_config.json');
                localWriteJson(item.configPath, settings);
                if opt.DryRun
                    runReport = localPlannedReport(item.outDir);
                else
                    runReport = runFromSettings(settings, ...
                        'outDir', item.outDir, ...
                        'tag', itemTag, ...
                        'openBaiduBrowser', logical(opt.OpenBaiduBrowser), ...
                        'closeFigures', logical(opt.CloseFigures));
                end
            end

            item.ok = localReportOk(runReport);
            item.stage = localReportText(runReport, 'stage', 'unknown');
            item.error = localReportText(runReport, 'error', '');
            if isfield(runReport, 'errorIdentifier')
                item.errorIdentifier = char(string(runReport.errorIdentifier));
            end
            if isfield(runReport, 'nAcquired') && ...
                    isnumeric(runReport.nAcquired) && isscalar(runReport.nAcquired)
                item.nAcquired = double(runReport.nAcquired);
            end
            if isfield(runReport, 'navSummary') && ...
                    isstruct(runReport.navSummary) && ...
                    isfield(runReport.navSummary, 'nFixes') && ...
                    isnumeric(runReport.navSummary.nFixes) && ...
                    isscalar(runReport.navSummary.nFixes)
                item.nFixes = double(runReport.navSummary.nFixes);
            end
            if opt.DryRun
                item.status = 'planned';
            elseif item.ok
                item.status = 'succeeded';
            else
                item.status = 'failed';
            end
        catch ME
            item.ok = false;
            item.status = 'failed';
            item.stage = 'batch_item';
            item.errorIdentifier = ME.identifier;
            item.error = ME.message;
            fprintf(2, 'Batch item failed: %s\n', ME.message);
        end

        if opt.CloseFigures
            localCloseNewFigures(figuresBefore);
        end
        if ~isempty(diaryCleaner)
            clear diaryCleaner
        end
        item.elapsedSeconds = toc(started);
        batchReport.items(i) = item;
        batchReport = localUpdateCounts(batchReport);
        localWriteBatchReport(batchReport);
        fprintf('Batch item %d status=%s elapsed=%.1f s\n', ...
            i, item.status, item.elapsedSeconds);

        if strcmp(item.status, 'failed') && ~opt.ContinueOnError
            batchReport.stage = 'stopped_on_error';
            break;
        end
    end

    batchReport = localUpdateCounts(batchReport);
    batchReport.finishedAt = localNow();
    if opt.DryRun
        batchReport.ok = batchReport.nPlanned == batchReport.nFiles;
        batchReport.stage = 'planned';
    elseif batchReport.nFailed == 0 && ...
            batchReport.nSucceeded == batchReport.nFiles
        batchReport.ok = true;
        batchReport.stage = 'done';
    elseif strcmp(batchReport.stage, 'running')
        batchReport.stage = 'done_with_errors';
    end
    localWriteBatchReport(batchReport);

    fprintf(['========== Batch %s: succeeded=%d failed=%d ' ...
        'planned=%d/%d ==========\n'], batchReport.stage, ...
        batchReport.nSucceeded, batchReport.nFailed, ...
        batchReport.nPlanned, batchReport.nFiles);
end

function [config, kind, description] = localLoadSettingsSource(source)
    if isstruct(source)
        if ~isscalar(source)
            error('batchDirForOneSettings:BadSettings', ...
                'settingsSource must be a scalar struct');
        end
        config = source;
        kind = 'settings';
        description = 'MATLAB settings struct';
        return;
    end

    path = char(source);
    if ~isfile(path)
        error('batchDirForOneSettings:MissingConfig', ...
            'JSON config not found: %s', path);
    end
    [~, ~, ext] = fileparts(path);
    if ~strcmpi(ext, '.json')
        error('batchDirForOneSettings:BadConfigType', ...
            'settingsSource path must be a .json file: %s', path);
    end
    config = jsondecode(fileread(path));
    if ~isstruct(config) || ~isscalar(config)
        error('batchDirForOneSettings:BadJson', ...
            'JSON config root must be an object');
    end
    kind = 'json';
    description = char(java.io.File(path).getCanonicalPath());
end

function files = localFindFiles(inputDir, pattern, recursive)
    if recursive
        files = dir(fullfile(inputDir, '**', pattern));
    else
        files = dir(fullfile(inputDir, pattern));
    end
    files = files(~[files.isdir]);
    if isempty(files), return; end
    paths = strings(numel(files), 1);
    for i = 1:numel(files)
        paths(i) = string(fullfile(files(i).folder, files(i).name));
    end
    [~, order] = sort(lower(paths));
    files = files(order);
end

function localPrepareOutputRoot(outputRoot)
    if isfolder(outputRoot)
        entries = dir(outputRoot);
        names = {entries.name};
        nonDots = ~ismember(names, {'.', '..'});
        if any(nonDots)
            error('batchDirForOneSettings:OutputNotEmpty', ...
                'OutputRoot already exists and is not empty: %s', outputRoot);
        end
    else
        [ok, message] = mkdir(outputRoot);
        if ~ok
            error('batchDirForOneSettings:CreateOutput', ...
                'Cannot create OutputRoot %s: %s', outputRoot, message);
        end
    end
end

function report = localPlannedReport(outDir)
    report = struct('ok', true, 'stage', 'planned', 'error', '', ...
        'outDir', outDir, 'nAcquired', 0, ...
        'navSummary', struct('nFixes', 0));
end

function tf = localReportOk(report)
    tf = isstruct(report) && isfield(report, 'ok') && ...
        (islogical(report.ok) || isnumeric(report.ok)) && ...
        isscalar(report.ok) && logical(report.ok);
end

function value = localReportText(report, name, default)
    value = default;
    if isstruct(report) && isfield(report, name) && ~isempty(report.(name))
        value = char(string(report.(name)));
    end
end

function report = localUpdateCounts(report)
    statuses = {report.items.status};
    report.nSucceeded = nnz(strcmp(statuses, 'succeeded'));
    report.nFailed = nnz(strcmp(statuses, 'failed'));
    report.nPlanned = nnz(strcmp(statuses, 'planned'));
    report.nAttempted = report.nSucceeded + report.nFailed;
end

function localWriteBatchReport(batchReport)
    localWriteJson(fullfile(batchReport.outputRoot, ...
        'batch_report.json'), batchReport);
    save(fullfile(batchReport.outputRoot, 'batch_report.mat'), ...
        'batchReport');
end

function localWriteJson(path, value)
    try
        text = jsonencode(value, 'PrettyPrint', true);
    catch
        text = jsonencode(value);
    end
    fid = fopen(path, 'w', 'n', 'UTF-8');
    if fid < 0
        error('batchDirForOneSettings:WriteJson', ...
            'Cannot write JSON file: %s', path);
    end
    cleaner = onCleanup(@() fclose(fid));
    fwrite(fid, text, 'char');
end

function localCloseNewFigures(figuresBefore)
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

function name = localSafeName(value)
    name = regexprep(char(value), '[^A-Za-z0-9_-]+', '_');
    name = regexprep(name, '^_+|_+$', '');
    if numel(name) > 80
        name = name(1:80);
    end
end

function value = localNow()
    value = char(string(datetime('now'), 'yyyy-MM-dd HH:mm:ss'));
end

function tf = localLogicalScalar(value)
    tf = (islogical(value) || isnumeric(value)) && isscalar(value);
end
