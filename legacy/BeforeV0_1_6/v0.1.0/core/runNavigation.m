function [navSolutions, eph] = runNavigation(trackResults, settings)
%RUNNAVIGATION Bridge tracking outputs into postNavigation.
%
% Fixes the legacy disconnect where init_B2a loaded a stale
% trackingResults_01.mat after tracking and discarded live results.

    trk = trackResultsToStruct(trackResults);

    % Drop empty slots (status '-')
    active = find(arrayfun(@(x) ~isempty(x.status) && x.status ~= '-', trk));
    if isempty(active)
        warning('runNavigation:NoActiveChannels', ...
            'No active tracking channels — navigation skipped.');
        navSolutions = [];
        eph = [];
        return;
    end

    fprintf('   Navigation using %d active channel(s): PRN %s\n', ...
        numel(active), mat2str([trk(active).PRN]));

    [navSolutions, eph] = postNavigation(trk, settings);
end
