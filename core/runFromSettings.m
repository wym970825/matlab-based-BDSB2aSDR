function report = runFromSettings(settings, varargin)
%RUNFROMSETTINGS Run the full B2a pipeline from an initSettings struct.
%
%   report = runFromSettings(settings)
%   report = runFromSettings(settings, 'outDir', dir)
%
% settings may be a partial configuration or a complete initSettings struct.
% Explicit name/value controls override its tag/doNavigation/doPlot/doNmea/
% doBaiduMap fields; omitted options preserve those fields and their shared
% fallbacks. No separate configuration normalizer is implemented here.
% See ../docs/config_entrypoints/README.md and runFromJsonConfig.

    setupPaths();
    if ~isstruct(settings) || ~isscalar(settings)
        error('runFromSettings:BadSettings', ...
            'settings must be a scalar struct');
    end

    % This adapter supplies only explicitly requested execution overrides.
    % All default flags, tags, configuration merging and validation belong to
    % runFromJsonConfig/initSettings; keeping another copy caused drift.
    p = inputParser;
    addParameter(p,'outDir','',@(x) ischar(x) || isstring(x));
    addParameter(p,'tag','',@(x) ischar(x) || isstring(x));
    for name={'doNavigation','doPlot','doNmea','doBaiduMap'}
        addParameter(p,name{1},[]);
    end
    addParameter(p,'openBaiduBrowser',true);
    addParameter(p,'closeFigures',false);
    parse(p,varargin{:}); opt=p.Results;
    config=settings;
    for name={'tag','doNavigation','doPlot','doNmea','doBaiduMap'}
        if ~ismember(name{1},p.UsingDefaults), config.(name{1})=opt.(name{1}); end
    end
    report=runFromJsonConfig(config,'outDir',opt.outDir, ...
        'openBaiduBrowser',opt.openBaiduBrowser,'closeFigures',opt.closeFigures);
end
