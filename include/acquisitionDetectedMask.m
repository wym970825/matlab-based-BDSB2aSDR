function mask = acquisitionDetectedMask(acqResults)
%ACQUISITIONDETECTEDMASK Resolve acquisition success for new/legacy results.

    if isfield(acqResults, 'detected') && ...
            numel(acqResults.detected) == numel(acqResults.carrFreq)
        mask = logical(acqResults.detected);
    else
        % Legacy acquisition used zero as the failure sentinel.
        mask = isfinite(acqResults.carrFreq) & acqResults.carrFreq ~= 0;
    end
    mask = reshape(mask, size(acqResults.carrFreq));
end
