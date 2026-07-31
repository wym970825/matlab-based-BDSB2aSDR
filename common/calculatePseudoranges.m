function [pseudoranges,transmitTime,localTime] = ...
             calculatePseudoranges(trackResults,towSeg,TOW_legacy,currMeasSample, ...
             localTime,channelList, settings)
%calculatePseudoranges finds relative pseudoranges for all satellites
%listed in CHANNELLIST at the specified millisecond of the processed
%signal. The pseudoranges contain unknown receiver clock offset.
%
% Supports multi-segment TOW after REACQ:
%   towSeg  - cell 1xNch, each cell a struct array with fields
%             indexStart, indexEnd, subFrameStart, TOW
%             OR numeric vector of subFrameStart (legacy SoftGNSS)
%   TOW_legacy - if towSeg is numeric, vector of TOW [s] per channel
%
% When towSeg is a cell of segments, TOW_legacy is ignored (pass []).

%--------------------------------------------------------------------------
%                         CU Multi-GNSS SDR
% (C) Written by Yafeng Li, Nagaraj C. Shivaramaiah and Dennis M. Akos
% based on the original work by Darius Plausinaitis,
% Peter Rinder, Nicolaj Bertelsen and Dennis M. Akos
% Extended: multi-segment TOW for mid-session REACQ
%--------------------------------------------------------------------------

transmitTime = inf(1, settings.numberOfChannels);

% Accelerate sequential search along absoluteSample
persistent searchIndex;
if isempty(searchIndex) || (localTime == inf)
    searchIndex = ones(1, settings.numberOfChannels);
end

useSegments = iscell(towSeg);

for channelNr = channelList
    absS = trackResults(channelNr).absoluteSample;
    nAbs = numel(absS);
    if nAbs < 2
        transmitTime(channelNr) = inf;
        continue;
    end

    % --- Resolve (subFrameStart, TOW) for this measurement index --------
    % Find tracking index first, then pick matching TOW segment.
    i0 = searchIndex(channelNr);
    if ~isfinite(i0) || i0 < 1
        i0 = 1;
    end
    i0 = min(i0, nAbs);

    index = i0;
    for ii = i0:nAbs
        a = absS(ii);
        if ~isfinite(a)
            continue;
        end
        if a > currMeasSample
            break
        end
        index = ii;
    end
    searchIndex(channelNr) = max(1, index);

    if index < 1 || index > nAbs || ~isfinite(absS(index))
        transmitTime(channelNr) = inf;
        continue;
    end
    if isfield(trackResults, 'trk_state') ...
            && numel(trackResults(channelNr).trk_state) >= index ...
            && trackResults(channelNr).trk_state(index) == 9
        transmitTime(channelNr) = inf;
        continue;
    end

    [sf0, tow0] = localTowAtIndex(towSeg, TOW_legacy, channelNr, index, useSegments);
    if ~isfinite(sf0) || ~isfinite(tow0)
        transmitTime(channelNr) = inf;
        continue;
    end

    cf = trackResults(channelNr).codeFreq(index);
    if ~isfinite(cf) || cf <= 0
        cf = settings.codeFreqBasis;
    end
    codePhaseStep = cf / settings.samplingFreq;

    codePhase = trackResults(channelNr).remCodePhase(index) +  ...
        codePhaseStep * (currMeasSample - absS(index));

    transmitTime(channelNr) = (codePhase/settings.codeLength + index - ...
        sf0) * settings.codeLength / settings.codeFreqBasis + tow0;
end

if (localTime == inf)
    finiteTt = transmitTime(channelList);
    finiteTt = finiteTt(isfinite(finiteTt));
    if isempty(finiteTt)
        % leave localTime = inf; caller will skip
        pseudoranges = nan(1, settings.numberOfChannels);
        return;
    end
    maxTime   = max(finiteTt);
    localTime = maxTime + settings.startOffset/1000;
end

pseudoranges = (localTime - transmitTime) * settings.c;
badTt = ~isfinite(transmitTime);
pseudoranges(badTt) = NaN;

end

function [sf0, tow0] = localTowAtIndex(towSeg, TOW_legacy, channelNr, index, useSegments)
    sf0 = inf;
    tow0 = inf;
    if useSegments
        if channelNr > numel(towSeg) || isempty(towSeg{channelNr})
            return;
        end
        segs = towSeg{channelNr};
        for k = 1:numel(segs)
            a = segs(k).indexStart;
            b = segs(k).indexEnd;
            if index >= a && index <= b ...
                    && isfinite(segs(k).subFrameStart) && isfinite(segs(k).TOW)
                % Need measurement at or after first subframe of this segment
                if index >= segs(k).subFrameStart
                    sf0 = segs(k).subFrameStart;
                    tow0 = segs(k).TOW;
                    return;
                end
            end
        end
        return;
    end
    % Legacy SoftGNSS: numeric subFrameStart + TOW vectors
    if channelNr > numel(towSeg) || channelNr > numel(TOW_legacy)
        return;
    end
    sf0 = towSeg(channelNr);
    tow0 = TOW_legacy(channelNr);
end
