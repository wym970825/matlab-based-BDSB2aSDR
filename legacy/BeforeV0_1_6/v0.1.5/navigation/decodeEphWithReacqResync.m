function [eph, segments, subFrameStart, TOW] = decodeEphWithReacqResync(trackCh)
%DECODEEPHWITHREACQRESYNC BCNAV2 decode with per-REACQ TOW segments.
%
%   [eph, segments, subFrameStart, TOW] = decodeEphWithReacqResync(trackCh)
%
% SoftGNSS originally uses a *single* first-preamble TOW for the whole track.
% Mid-session REACQ re-locks each SV at a different time; the old TOW no
% longer matches the code-period index in later epochs.
%
% This routine splits the track at REACQ gaps, decodes B-CNAV2 in *each*
% contiguous lock stretch that is long enough, and returns a segment list
% so navigation can keep pre- and post-REACQ epochs (LS whenever nSat>=4).
%
% segments(k) fields:
%   .indexStart     - first ms index of segment (1-based, inclusive)
%   .indexEnd       - last  ms index of segment (1-based, inclusive)
%   .subFrameStart  - first valid preamble index in full track timeline
%   .TOW            - TOW of that preamble [s]
%
% subFrameStart / TOW (scalars) = first valid segment (legacy callers).
% eph = best complete ephemeris among segments (prefer latest).

    eph = eph_structure_init();
    segments = struct('indexStart', {}, 'indexEnd', {}, ...
        'subFrameStart', {}, 'TOW', {});
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

    minNeed = 24000; % B-CNAV2: need several 6 s messages

    % --- Contiguous lock runs (exclude REACQ state == 9) ---------------
    valid = true(1, n);
    if isfield(trackCh, 'trk_state') && ~isempty(trackCh.trk_state)
        st = trackCh.trk_state(:).';
        st = st(1:min(numel(st), n));
        if numel(st) < n
            st(end+1:n) = st(end);
        end
        valid(st == 9) = false;
    end
    % Honour explicit reacqLoopCnt ticks as gap points
    if isfield(trackCh, 'reacqLoopCnt') && ~isempty(trackCh.reacqLoopCnt)
        for r = trackCh.reacqLoopCnt(:).'
            if isfinite(r) && r >= 1 && r <= n
                valid(r) = false;
            end
        end
    end

    d = diff([false, valid, false]);
    runStarts = find(d == 1);
    runEnds   = find(d == -1) - 1;

    bestEphOk = false;
    bestEphIdx = 0;

    for ir = 1:numel(runStarts)
        a = runStarts(ir);
        b = runEnds(ir);
        span = b - a + 1;
        if span < minNeed
            continue;
        end

        try
            [ephR, sfR, towR] = BCNAV2decoding(I_P(a:b));
        catch
            continue;
        end
        if ~isfinite(sfR) || ~isfinite(towR) || sfR < 1
            continue;
        end

        sfAbs = a - 1 + sfR;
        if sfAbs < a || sfAbs > b
            continue;
        end

        seg = struct();
        seg.indexStart    = a;
        seg.indexEnd      = b;
        seg.subFrameStart = sfAbs;
        seg.TOW           = towR;
        segments(end+1) = seg; %#ok<AGROW>

        ephOk = isEphComplete(ephR);
        if ephOk
            % Prefer latest complete eph (fresher IODE / clock)
            eph = ephR;
            bestEphOk = true;
            bestEphIdx = numel(segments);
        elseif ~bestEphOk && ir == 1
            eph = ephR; % keep partial for diagnostics
        end
    end

    % Fallback: whole stream once (no REACQ split or all runs too short)
    if isempty(segments)
        try
            [eph, sf0, tow0] = BCNAV2decoding(I_P);
        catch
            return;
        end
        if isfinite(sf0) && isfinite(tow0)
            seg = struct();
            seg.indexStart    = 1;
            seg.indexEnd      = n;
            seg.subFrameStart = sf0;
            seg.TOW           = tow0;
            segments = seg;
        end
    end

    if ~isempty(segments)
        subFrameStart = segments(1).subFrameStart;
        TOW = segments(1).TOW;
        if numel(segments) > 1
            fprintf(['  TOW segments: %d lock runs with preamble' ...
                ' (first sf=%d TOW=%.3f s; last sf=%d TOW=%.3f s)\n'], ...
                numel(segments), ...
                segments(1).subFrameStart, segments(1).TOW, ...
                segments(end).subFrameStart, segments(end).TOW);
        elseif bestEphOk && bestEphIdx > 0
            % single segment after REACQ-aware path
        end
    end
end

function ok = isEphComplete(eph)
    ok = false;
    if isempty(eph) || ~isfield(eph, 'idValid')
        return;
    end
    v = eph.idValid(:).';
    if numel(v) < 7
        return;
    end
    ok = (v(1) == 10) && (v(2) == 11) && any(v(3:7) == (30:34));
end
