function report = runFromSettings(settings, varargin)
%RUNFROMSETTINGS Run the full B2a pipeline from an initSettings struct.
%
%   report = runFromSettings(settings)
%   report = runFromSettings(settings, 'outDir', dir)
%
% settings must be a scalar struct returned by initSettings (or an
% equivalent complete settings struct). Pipeline controls can be overridden
% with doNavigation, doPlot, doNmea, and doBaiduMap.

    setupPaths();
    if ~isstruct(settings) || ~isscalar(settings)
        error('runFromSettings:BadSettings', ...
            'settings must be a scalar struct');
    end

    p = inputParser;
    addParameter(p, 'outDir', '', @(x) ischar(x) || isstring(x));
    addParameter(p, 'tag', char(string(datetime('now'), ...
        'yyMMdd_HHmmss')), @(x) ischar(x) || isstring(x));
    addParameter(p, 'doNavigation', localTopFlag(settings, ...
        'doNavigation', true), @localLogicalScalar);
    addParameter(p, 'doPlot', localPipelineFlag(settings, ...
        'doPlot', 'plotNavPost', true), @localLogicalScalar);
    addParameter(p, 'doNmea', localPipelineNestedFlag(settings, ...
        'doNmea', 'nmea', 'enable', true), @localLogicalScalar);
    addParameter(p, 'doBaiduMap', localPipelineFlag(settings, ...
        'doBaiduMap', 'plotBaiduMap', true), @localLogicalScalar);
    addParameter(p, 'openBaiduBrowser', true, @localLogicalScalar);
    addParameter(p, 'closeFigures', false, @localLogicalScalar);
    parse(p, varargin{:});
    opt = p.Results;

    config = settings;
    config.doNavigation = logical(opt.doNavigation);
    config.doPlot = logical(opt.doPlot);
    config.doNmea = logical(opt.doNmea);
    config.doBaiduMap = logical(opt.doBaiduMap);
    config.tag = char(opt.tag);

    report = runFromJsonConfig(config, ...
        'outDir', opt.outDir, ...
        'openBaiduBrowser', logical(opt.openBaiduBrowser), ...
        'closeFigures', logical(opt.closeFigures));
end

function tf = localLogicalScalar(value)
    tf = (islogical(value) || isnumeric(value)) && isscalar(value);
end

function tf = localTopFlag(settings, name, default)
    tf = default;
    if isfield(settings, name)
        value = settings.(name);
        if localLogicalScalar(value)
            tf = logical(value);
        end
    end
end

function tf = localNestedFlag(settings, parent, name, default)
    tf = default;
    if isfield(settings, parent) && isstruct(settings.(parent)) && ...
            isfield(settings.(parent), name)
        value = settings.(parent).(name);
        if localLogicalScalar(value)
            tf = logical(value);
        end
    end
end

function tf = localPipelineFlag(settings, pipelineName, settingName, default)
    tf = localTopFlag(settings, settingName, default);
    tf = localTopFlag(settings, pipelineName, tf);
end

function tf = localPipelineNestedFlag(settings, pipelineName, ...
        parent, name, default)
    tf = localNestedFlag(settings, parent, name, default);
    tf = localTopFlag(settings, pipelineName, tf);
end
