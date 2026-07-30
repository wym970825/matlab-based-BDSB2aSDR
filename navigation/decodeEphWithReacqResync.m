function [eph, subFrameStart, TOW] = decodeEphWithReacqResync(trackCh)
%DECODEEPHWITHREACQRESYNC BCNAV2 decode with post-REACQ frame re-sync.
%
%   [eph, subFrameStart, TOW] = decodeEphWithReacqResync(trackCh)
%
% SoftGNSS uses a *single* first-preamble TOW for the whole track. After
% mid-session REACQ each SV re-locks at a different time; the old TOW +
% subFrameStart no longer matches the code-period index. Re-decode I_P
% starting after the last REACQ epoch and map firstSubFrame into the full
% tracking index so calculatePseudoranges stays consistent.

    eph = eph_structure_init();
    subFrameStart = inf;
    TOW = inf;

    if isempty(trackCh) || ~isfield(trackCh, 'I_P') || isempty(trackCh.I_P)
        return;
    end
    I_P = trackCh.I_P(:).';
    n = numel(I_P);
    if n < 1000
        return;
    end

    % Baseline: first valid preamble on full stream
    try
        [eph, subFrameStart, TOW] = BCNAV2decoding(I_P);
    catch
        eph = eph_structure_init();
        subFrameStart = inf;
        TOW = inf;
    end

    % Locate last REACQ ms (trk_state id 9) if present
    lastReacq = 0;
    if isfield(trackCh, 'trk_state') && ~isempty(trackCh.trk_state)
        st = trackCh.trk_state(:);
        idx = find(st == 9, 1, 'last');
        if ~isempty(idx)
            lastReacq = idx;
        end
    end
    % Also honour explicit reacqLoopCnt from trackOneChannel if present
    if isfield(trackCh, 'reacqLoopCnt') && ~isempty(trackCh.reacqLoopCnt)
        lastReacq = max(lastReacq, max(trackCh.reacqLoopCnt(:)));
    end

    if lastReacq < 1
        return; % no REACQ — keep first-preamble solution
    end

    % Need enough post-REACQ ms for B-CNAV2 (messages ~6 s each; use 24 s)
    startMs = min(n, lastReacq + 1);
    minNeed = 24000;
    if (n - startMs + 1) < minNeed
        warning('decodeEphWithReacqResync:ShortPostReacq', ...
            'PRN post-REACQ span %d ms < %d — keep pre-REACQ TOW if any', ...
            n - startMs + 1, minNeed);
        return;
    end

    try
        [eph2, sf2, tow2] = BCNAV2decoding(I_P(startMs:end));
    catch ME
        warning('decodeEphWithReacqResync:Decode', '%s', ME.message);
        return;
    end

    if ~isfinite(sf2) || ~isfinite(tow2)
        warning('decodeEphWithReacqResync:NoPreamble', ...
            'No preamble after REACQ @ ms %d — keep pre-REACQ TOW', lastReacq);
        return;
    end

    % Map subframe index into full tracking timeline
    subFrameStart = startMs - 1 + sf2;
    TOW = tow2;
    eph = eph2;
    fprintf(['  REACQ frame re-sync: lastReacqMs=%d  subFrameStart=%d' ...
        '  TOW=%.3f s (was first-preamble only)\n'], ...
        lastReacq, subFrameStart, TOW);
end
