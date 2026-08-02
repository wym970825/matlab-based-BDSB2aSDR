%BATCH_DIR_FORONESETTINGS Script launcher for batchDirForOneSettings.
%
% Define these variables before running this file:
%   inputDir       - directory containing IF binary files
%   settingsSource - initSettings(...) struct or JSON config path
%
% Optional:
%   batchOptions   - cell array of name-value options
%
% Example:
%   inputDir = 'F:\Data\ExpKLHP\X310_IFData';
%   settingsSource = 'results\ui\job\ui_config.json';
%   batchOptions = {'OutputRoot', 'results\batch\my_run'};
%   run(fullfile('batch', 'batch_dir_ForOneSettings.m'));

if ~exist('inputDir', 'var') || isempty(inputDir)
    error('batchDirForOneSettings:MissingInputDir', ...
        'Define inputDir before running this script.');
end
if ~exist('settingsSource', 'var') || isempty(settingsSource)
    error('batchDirForOneSettings:MissingSettings', ...
        'Define settingsSource before running this script.');
end
if exist('batchOptions', 'var') && ~isempty(batchOptions)
    if ~iscell(batchOptions)
        error('batchDirForOneSettings:BadOptions', ...
            'batchOptions must be a cell array of name-value options.');
    end
    batchReport = batchDirForOneSettings( ...
        inputDir, settingsSource, batchOptions{:});
else
    batchReport = batchDirForOneSettings(inputDir, settingsSource);
end
