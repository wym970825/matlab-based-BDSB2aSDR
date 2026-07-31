function nWorkers = ensureTrackParPool(maxWorkers)
%ENSURETRACKPARPOOL Start/resize local parallel pool, hard-capped.
%
%   nWorkers = ensureTrackParPool(maxWorkers)
%
% Creates a local pool with at most maxWorkers workers (also limited by
% feature('numcores')). Returns 0 if Parallel Computing Toolbox is missing
% or pool start fails (caller should fall back to serial).

    if nargin < 1 || isempty(maxWorkers)
        maxWorkers = 6;
    end
    maxWorkers = max(1, min(6, round(maxWorkers)));  % hard cap 6

    nWorkers = 0;
    if license('test', 'Distrib_Computing_Toolbox') == 0 ...
            && license('test', 'Parallel_Computing_Toolbox') == 0
        warning('ensureTrackParPool:NoPCT', ...
            'Parallel Computing Toolbox not available — serial tracking.');
        return;
    end

    try
        nCores = feature('numcores');
    catch
        nCores = maxWorkers;
    end
    want = min([maxWorkers, nCores, 6]);

    try
        p = gcp('nocreate');
        if isempty(p)
            p = parpool('local', want);
        elseif p.NumWorkers > want
            % Downsize: user requested max 6 (or lower)
            delete(p);
            p = parpool('local', want);
        elseif p.NumWorkers < want
            % Leave smaller existing pool (avoid thrash); use what we have
            % Optional grow: delete + recreate only if gap is large
            if p.NumWorkers < want && (want - p.NumWorkers) >= 2
                delete(p);
                p = parpool('local', want);
            end
        end
        nWorkers = p.NumWorkers;
        fprintf('ensureTrackParPool: local pool with %d worker(s) (want<=%d)\n', ...
            nWorkers, want);
    catch ME
        warning('ensureTrackParPool:Failed', ...
            'Could not start parpool: %s — serial tracking.', ME.message);
        nWorkers = 0;
    end
end
