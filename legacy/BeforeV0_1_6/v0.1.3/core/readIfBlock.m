function data = readIfBlock(fid, settings, dataAdaptCoeff, nMs)
%READIFBLOCK Read nMs milliseconds of complex/real IF samples.

    samplesPerCode = round(settings.samplingFreq / ...
        (settings.codeFreqBasis / settings.codeLength));
    nSamples = dataAdaptCoeff * samplesPerCode * nMs;

    raw = fread(fid, nSamples, settings.dataType)';
    if numel(raw) < nSamples
        error('readIfBlock:EOF', 'Not enough samples (got %d, need %d).', ...
            numel(raw), nSamples);
    end

    if dataAdaptCoeff == 2
        data = raw(1:2:end) + 1i * raw(2:2:end);
    else
        data = raw;
    end
end
