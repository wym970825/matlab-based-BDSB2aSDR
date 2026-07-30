function rootDir = setupPaths()
%SETUPPATHS Add B2a receiver project folders to MATLAB path.
%
%   rootDir = setupPaths()
%
% All runtime modules live under the project root. Input (legacy) sources
% are never modified; this function only touches the output project tree.

    rootDir = fileparts(mfilename('fullpath'));

    subdirs = {
        'config'
        'core'
        'acquisition'
        'tracking'
        'navigation'
        'channelCtrl'
        'signal'
        'include'
        'common'
        'cn0'
        'tests'
        };

    addpath(rootDir);
    for k = 1:numel(subdirs)
        p = fullfile(rootDir, subdirs{k});
        if exist(p, 'dir')
            addpath(p);
        end
    end
end
