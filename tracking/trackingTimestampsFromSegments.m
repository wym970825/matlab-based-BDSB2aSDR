function timestamps = trackingTimestampsFromSegments(nSamples, segments, epochSeconds)
%TRACKINGTIMESTAMPSFROMSEGMENTS Preserve independent post-REACQ TOW anchors.
    timestamps = nan(1, nSamples);
    for k = 1:numel(segments)
        seg = segments(k);
        indices = max(1, seg.indexStart):min(nSamples, seg.indexEnd);
        if isfinite(seg.TOW) && isfinite(seg.subFrameStart)
            timestamps(indices) = seg.TOW + ...
                (indices - seg.subFrameStart) * epochSeconds;
        end
    end
end
