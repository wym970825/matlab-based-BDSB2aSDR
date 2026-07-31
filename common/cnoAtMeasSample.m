function cnoDb = cnoAtMeasSample(trackResults, chList, currMeasSample, settings)
%CNOATMEASSAMPLE Map measurement sample to nearest B2a_CNo [dB-Hz] per channel.
%
%   cnoDb = cnoAtMeasSample(trackResults, chList, currMeasSample, settings)
%
% Uses TrackResults2 / struct field B2a_CNo (CNoInterval bins). Missing
% values stay NaN so lsObservationWeights treats them as neutral weight.

    cnoDb = nan(1, numel(chList));
    cnoInt = 200;
    if isfield(settings, 'CNoInterval') && ~isempty(settings.CNoInterval) ...
            && settings.CNoInterval > 0
        cnoInt = settings.CNoInterval;
    end
    for k = 1:numel(chList)
        ch = chList(k);
        tr = trackResults(ch);
        if ~isfield(tr, 'B2a_CNo') || isempty(tr.B2a_CNo)
            continue;
        end
        absS = tr.absoluteSample;
        idx = find(isfinite(absS) & absS <= currMeasSample, 1, 'last');
        if isempty(idx)
            idx = find(isfinite(absS), 1, 'first');
        end
        if isempty(idx)
            continue;
        end
        cnoIdx = max(1, min(numel(tr.B2a_CNo), ceil(double(idx) / double(cnoInt))));
        v = tr.B2a_CNo(cnoIdx);
        if isfinite(v) && v > 0
            cnoDb(k) = v;
        end
    end
end
