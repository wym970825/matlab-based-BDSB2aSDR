function acqResults = acquisition_robust_v2fft(longSignal, settings, varargin)
%ACQUISITION_ROBUST_V2FFT Robust BDS B2a coarse/fine acquisition.
%
% Coarse acquisition noncoherently combines independent 1-ms searches.
% Within each millisecond, the pilot/data sign can either remain constant
% or change once at the primary-code boundary. This handles any number of
% secondary/data-symbol changes across a multi-ms observation without a
% combinatorial sign search.

    p = inputParser;
    p.FunctionName = mfilename;
    addRequired(p, 'longSignal', ...
        @(x) isnumeric(x) && isvector(x) && ~isempty(x));
    addRequired(p, 'settings', @isstruct);
    addParameter(p, 'STA', 'INIT', @(x) ischar(x) || isstring(x));
    addParameter(p, 'ISSILENT', false, @islogical);
    addParameter(p, 'USEFFT', false, @islogical);
    addParameter(p, 'SHOWFFT', false, @islogical);
    addParameter(p, 'PRN', [], ...
        @(x) isempty(x) || (isnumeric(x) && isscalar(x)));
    parse(p, longSignal, settings, varargin{:});

    sta = upper(string(p.Results.STA));
    isSilent = p.Results.ISSILENT;
    satList = localSatelliteList(sta, p.Results.PRN, settings, isSilent);

    fs = settings.samplingFreq;
    codeFreq = settings.codeFreqBasis;
    codeLen = settings.codeLength;
    samplesPerCode = round(fs / (codeFreq / codeLen));
    fineMs = max(1, round(settings.fineNoncoh));
    coarseMs = max(1, round(localSetting(settings, 'coarseNoncohMs', 5)));
    nSeg = max(2, round(localSetting(settings, 'acqFlipSegments', 8)));
    fineStepHz = localSetting(settings, 'fineStepHz', 2);
    fineInitialHalfHz = localSetting(settings, ...
        'fineSearchInitialHalfSpanHz', max(100, settings.acqStep));
    fineMaxHalfHz = localSetting(settings, ...
        'fineSearchMaxHalfSpanHz', max(1000, 10 * settings.acqStep));

    requiredSamples = max(coarseMs * samplesPerCode, ...
        (fineMs + 1) * samplesPerCode);
    if numel(longSignal) < requiredSamples
        error('acquisition_robust:InputTooShort', ...
            'Need at least %d samples (%d complete ms).', ...
            requiredSamples, ceil(requiredSamples / samplesPerCode));
    end
    longSignal = longSignal(:).';

    if isfield(settings, 'fineCodeSearchHalfWinSamples')
        halfWin = max(0, round(settings.fineCodeSearchHalfWinSamples));
    else
        halfWin = max(1, round(2 * fs / codeFreq));
    end

    ts = 1 / fs;
    phase1ms = (0:samplesPerCode - 1) * 2 * pi * ts;
    phaseFine = (0:fineMs * samplesPerCode - 1) * 2 * pi * ts;
    numFreqBins = round(2 * settings.acqSearchBand / settings.acqStep) + 1;
    freqBins = settings.IF - settings.acqSearchBand + ...
        (0:numFreqBins - 1) * settings.acqStep;

    [segmentMask, flipSigns, flipModeByTau] = ...
        localFlipModel(samplesPerCode, nSeg);
    coarseStart = numel(longSignal) - coarseMs * samplesPerCode + 1;
    coarseBlocks = reshape(longSignal(coarseStart:end), ...
        samplesPerCode, coarseMs).';

    nSat = numel(satList);
    acqResults = localEmptyResults(nSat, coarseMs);
    acqResults.coarseNoncohMs = coarseMs;
    acqResults.satelliteList = satList;

    for satIdx = 1:nSat
        prn = satList(satIdx);
        pilotChips = generateB2aPilotCode(prn, settings);
        dataChips = generateB2aDataCode(prn);
        localPilot = localSampleCode(pilotChips, samplesPerCode, fs, codeFreq);
        localData = localSampleCode(dataChips, samplesPerCode, fs, codeFreq);
        pilotFft = conj(fft(localPilot, samplesPerCode));
        dataFft = conj(fft(localData, samplesPerCode));

        coarseSurface = zeros(samplesPerCode, numFreqBins);
        pilotModes = ones(coarseMs, numFreqBins, 'uint8');
        dataModes = ones(coarseMs, numFreqBins, 'uint8');

        for freqIdx = 1:numFreqBins
            accumulatedPower = zeros(1, samplesPerCode);
            selectedPilot = ones(coarseMs, samplesPerCode, 'uint8');
            selectedData = ones(coarseMs, samplesPerCode, 'uint8');
            carrier = exp(-1i * freqBins(freqIdx) * phase1ms);

            for msIdx = 1:coarseMs
                baseband = coarseBlocks(msIdx, :) .* carrier;
                [pilotPower, selectedPilot(msIdx, :)] = ...
                    localFlipRobustPower(baseband, pilotFft, segmentMask, ...
                    flipSigns, flipModeByTau);
                [dataPower, selectedData(msIdx, :)] = ...
                    localFlipRobustPower(baseband, dataFft, segmentMask, ...
                    flipSigns, flipModeByTau);
                accumulatedPower = accumulatedPower + ...
                    0.5 * (pilotPower + dataPower);
            end

            coarseSurface(:, freqIdx) = accumulatedPower.';
            [~, tauAtFreq] = max(accumulatedPower);
            pilotModes(:, freqIdx) = selectedPilot(:, tauAtFreq);
            dataModes(:, freqIdx) = selectedData(:, tauAtFreq);
        end

        [peakByFreq, tauByFreq] = max(coarseSurface, [], 1);
        [peakCoarse, bestFreqIdx] = max(peakByFreq);
        coarseCodePhase = tauByFreq(bestFreqIdx);
        coarseFreq = freqBins(bestFreqIdx);
        bestCurve = coarseSurface(:, bestFreqIdx).';
        [peakMetric, meanMetric] = localPeakMetrics( ...
            bestCurve, coarseCodePhase, fs, codeFreq);

        acqResults.peakMetric(satIdx) = peakMetric;
        acqResults.peakMetric2(satIdx) = meanMetric;
        acqResults.coarsePeak(satIdx) = peakCoarse;
        acqResults.coarseFreq(satIdx) = coarseFreq;
        modes = [pilotModes(:, bestFreqIdx).'; dataModes(:, bestFreqIdx).'];
        acqResults.coarseModes{satIdx} = modes;
        acqResults.coarseMode(:, satIdx) = modes(:, end);

        passed = isfinite(peakMetric) && peakMetric >= settings.acqThreshold;
        if ~passed
            if ~isSilent
                fprintf('PRN(%02d) acquisition failed (metric %.3f < %.3f).\n', ...
                    prn, peakMetric, settings.acqThreshold);
            end
            continue;
        end

        if ~isSilent
            fprintf(['PRN(%02d) coarse acquired: codePhase=%d, f=%.1fHz, ' ...
                'metric=%.3f, %d-ms modes(P/D)=%s/%s\n'], ...
                prn, coarseCodePhase, coarseFreq, peakMetric, coarseMs, ...
                mat2str(modes(1, :)), mat2str(modes(2, :)));
        end

        % Use complete primary-code periods immediately before the boundary
        % detected in the final 1-ms block.
        boundaryAbs = numel(longSignal) - samplesPerCode + coarseCodePhase;
        fineStart = boundaryAbs - fineMs * samplesPerCode;
        fineEnd = boundaryAbs - 1;
        if fineStart < 1 || fineEnd > numel(longSignal)
            error('acquisition_robust:FineWindowOutOfRange', ...
                'Fine window [%d,%d] is outside input [1,%d].', ...
                fineStart, fineEnd, numel(longSignal));
        end
        fineSignal = longSignal(fineStart:fineEnd);

        weil100 = GenWeil(prn);
        noiseLocal = localNoiseCode(codeLen, samplesPerCode, ...
            fs, codeFreq, prn);
        fine = localFineSearch(fineSignal, localPilot, noiseLocal, ...
            weil100, phaseFine, coarseFreq, fineStepHz, ...
            fineInitialHalfHz, fineMaxHalfHz);

        deltaValues = -halfWin:halfWin;
        weilIndices = mod((0:fineMs - 1) + fine.weilPhase, 100) + 1;
        weilSigns = weil100(weilIndices);
        carrier = exp(-1i * fine.frequency * phaseFine);
        fineBaseband = fineSignal .* carrier;
        refineMagnitude = zeros(size(deltaValues));
        for deltaIdx = 1:numel(deltaValues)
            shiftedPilot = circshift(localPilot, -deltaValues(deltaIdx));
            coherent = 0;
            for msIdx = 1:fineMs
                idx = (msIdx - 1) * samplesPerCode + (1:samplesPerCode);
                coherent = coherent + weilSigns(msIdx) * ...
                    sum(fineBaseband(idx) .* shiftedPilot);
            end
            refineMagnitude(deltaIdx) = abs(coherent);
        end
        [~, bestDeltaIdx] = max(refineMagnitude);
        bestDelta = deltaValues(bestDeltaIdx);
        refinedCodePhase = mod(coarseCodePhase + bestDelta - 1, ...
            samplesPerCode) + 1;

        polarityRef = 1;
        bestPsum = fine.coherentSum;
        if real(bestPsum) < 0
            polarityRef = -1;
            bestPsum = -bestPsum;
        end

        noisePower = fine.noisePower;
        totalTime = fineMs * 1e-3;
        if isfinite(noisePower) && noisePower > 0
            snrLinear = (abs(bestPsum)^2 - fineMs * noisePower) / ...
                (fineMs * noisePower);
            snrLinear = max(snrLinear, 1e-12);
            acqResults.CN0_pilot(satIdx) = ...
                10 * log10(snrLinear / totalTime);
        end

        acqResults.carrFreq(satIdx) = -fine.frequency;
        acqResults.detected(satIdx) = true;
        acqResults.codePhase(satIdx) = refinedCodePhase;
        acqResults.codePhaseAbs(satIdx) = boundaryAbs - bestDelta;
        acqResults.weilPhase(satIdx) = fine.weilPhase;
        acqResults.polarityRef(satIdx) = polarityRef;
        acqResults.noisePow(satIdx) = noisePower;
        acqResults.fineAtSearchLimit(satIdx) = fine.atSearchLimit;
        acqResults.fineSearchHalfSpanHz(satIdx) = fine.halfSpanHz;

        if ~isSilent
            fprintf(['PRN(%02d) fine: f=%.1fHz, codePhase=%d, ' ...
                'WeilPhase=%d, polarityRef=%+d, span=+/-%.0fHz\n'], ...
                prn, fine.frequency, refinedCodePhase, fine.weilPhase, ...
                polarityRef, fine.halfSpanHz);
        end
    end
end

function satList = localSatelliteList(sta, prn, settings, isSilent)
    if sta == "INIT"
        if ~isfield(settings, 'acqSatelliteList') || ...
                isempty(settings.acqSatelliteList)
            error('acquisition_robust:MissingAcqList', ...
                'settings.acqSatelliteList is required for INIT.');
        end
        satList = double(settings.acqSatelliteList(:).');
        return;
    end
    if sta ~= "SING"
        error('acquisition_robust:InvalidSTA', ...
            'STA must be INIT or SING, not %s.', sta);
    end
    if isempty(prn)
        if isfield(settings, 'acqSatelliteList') && ...
                isscalar(settings.acqSatelliteList)
            prn = settings.acqSatelliteList;
        else
            error('acquisition_robust:MissingPRN', ...
                'SING requires a scalar PRN.');
        end
    end
    validateattributes(prn, {'numeric'}, ...
        {'scalar', 'integer', 'positive', '<=', 63});
    satList = double(prn);
    if ~isSilent
        fprintf('Single acquisition mode: PRN(%d) selected.\n', prn);
    end
end

function results = localEmptyResults(nSat, coarseMs)
    results = struct();
    names = {'carrFreq', 'codePhase', 'codePhaseAbs', 'peakMetric', ...
        'peakMetric2', 'weilPhase', 'polarityRef', 'noisePow', ...
        'CN0_pilot', 'coarsePeak', 'coarseFreq', ...
        'fineSearchHalfSpanHz'};
    for idx = 1:numel(names)
        results.(names{idx}) = nan(1, nSat);
    end
    results.coarseMode = nan(2, nSat);
    results.coarseModes = repmat({nan(2, coarseMs)}, 1, nSat);
    results.detected = false(1, nSat);
    results.fineAtSearchLimit = false(1, nSat);
end

function value = localSetting(settings, name, defaultValue)
    value = defaultValue;
    if isfield(settings, name) && ~isempty(settings.(name)) && ...
            isfinite(settings.(name))
        value = double(settings.(name));
    end
end

function sampled = localSampleCode(chips, nSamples, fs, codeFreq)
    % Preserve the established acquisition coordinate convention. A
    % dedicated acquisition-to-tracking sample-origin test should precede
    % any change to this indexing rule.
    indices = floor(((1:nSamples) / fs) * codeFreq);
    sampled = chips(mod(indices, numel(chips)) + 1);
    sampled = sampled(:).';
end

function [mask, signs, flipModeByTau] = localFlipModel(nSamples, nSeg)
    edges = round(linspace(0, nSamples, nSeg + 1));
    mask = false(nSeg, nSamples);
    for idx = 1:nSeg
        mask(idx, edges(idx) + 1:edges(idx + 1)) = true;
    end
    signs = ones(nSeg);
    for mode = 2:nSeg
        signs(mode, mode:nSeg) = -1;
    end

    internalEdges = edges(2:end - 1);
    offsets = 0:nSamples - 1;
    flipModeByTau = ones(1, nSamples, 'uint8');
    if isempty(internalEdges), return; end
    [distance, nearest] = min(abs(offsets(:) - internalEdges), [], 2);
    endpointDistance = min(offsets(:), nSamples - offsets(:));
    useInternalFlip = distance < endpointDistance;
    flipModeByTau(useInternalFlip) = uint8(nearest(useInternalFlip) + 1);
end

function [power, selectedMode] = localFlipRobustPower( ...
        baseband, localFft, segmentMask, flipSigns, flipModeByTau)
    [nSeg, nSamples] = size(segmentMask);
    correlations = complex(zeros(nSeg, nSamples));
    for segment = 1:nSeg
        sliced = zeros(1, nSamples);
        sliced(segmentMask(segment, :)) = ...
            baseband(segmentMask(segment, :));
        correlations(segment, :) = ifft(fft(sliced) .* localFft);
    end
    combined = flipSigns * correlations;
    noFlipPower = abs(combined(1, :)).^2;
    columns = 1:nSamples;
    flipLinear = sub2ind(size(combined), double(flipModeByTau), columns);
    flipPower = abs(combined(flipLinear)).^2;
    useFlip = flipModeByTau > 1 & flipPower > noFlipPower;
    power = noFlipPower;
    power(useFlip) = flipPower(useFlip);
    selectedMode = ones(1, nSamples, 'uint8');
    selectedMode(useFlip) = flipModeByTau(useFlip);
end

function [peakRatio, peakToMean] = localPeakMetrics( ...
        curve, peakIndex, fs, codeFreq)
    nSamples = numel(curve);
    indices = 1:nSamples;
    circularDistance = abs(indices - peakIndex);
    circularDistance = min(circularDistance, nSamples - circularDistance);
    exclusion = max(1, 2 * ceil(fs / codeFreq));
    valid = circularDistance > exclusion & isfinite(curve);
    if ~any(valid) || ~isfinite(curve(peakIndex))
        peakRatio = NaN;
        peakToMean = NaN;
        return;
    end
    secondPeak = max(curve(valid));
    noiseMean = mean(curve(valid));
    if secondPeak <= 0 || noiseMean <= 0
        peakRatio = NaN;
        peakToMean = NaN;
        return;
    end
    peakRatio = curve(peakIndex) / secondPeak;
    peakToMean = curve(peakIndex) / noiseMean;
end

function noiseCode = localNoiseCode(codeLen, nSamples, fs, codeFreq, prn)
    stream = RandStream('mt19937ar', 'Seed', 6400 + round(prn));
    chips = sign(randn(stream, 1, codeLen));
    chips(chips == 0) = 1;
    noiseCode = localSampleCode(chips, nSamples, fs, codeFreq);
end

function fine = localFineSearch(signal, localPilot, noiseLocal, weil100, ...
        phase, coarseFreq, stepHz, initialHalfHz, maxHalfHz)
    nSamples = numel(localPilot);
    nMs = numel(signal) / nSamples;
    weilMatrix = zeros(100, nMs);
    for phaseIdx = 0:99
        weilMatrix(phaseIdx + 1, :) = weil100( ...
            mod(phaseIdx + (0:nMs - 1), 100) + 1);
    end

    initialHalfHz = max(stepHz, abs(initialHalfHz));
    maxHalfHz = max(initialHalfHz, abs(maxHalfHz));
    halfSpan = initialHalfHz;
    while true
        bins = (coarseFreq - halfSpan):stepHz:(coarseFreq + halfSpan);
        z = -inf(size(bins));
        phaseByBin = zeros(size(bins));
        sumByBin = complex(zeros(size(bins)));
        noiseByBin = nan(size(bins));
        for binIdx = 1:numel(bins)
            baseband = signal .* exp(-1i * bins(binIdx) * phase);
            prompt = complex(zeros(1, nMs));
            noisePrompt = complex(zeros(1, nMs));
            for msIdx = 1:nMs
                idx = (msIdx - 1) * nSamples + (1:nSamples);
                prompt(msIdx) = sum(baseband(idx) .* localPilot);
                noisePrompt(msIdx) = sum(baseband(idx) .* noiseLocal);
            end
            coherentByPhase = weilMatrix * prompt.';
            [z(binIdx), phaseIndex] = max(abs(coherentByPhase));
            phaseByBin(binIdx) = phaseIndex - 1;
            sumByBin(binIdx) = coherentByPhase(phaseIndex);
            noiseByBin(binIdx) = mean(abs(noisePrompt).^2);
        end
        [~, bestBin] = max(z);
        onEdge = bestBin <= 2 || bestBin >= numel(bins) - 1;
        if ~onEdge || halfSpan >= maxHalfHz
            atLimit = onEdge && halfSpan >= maxHalfHz;
            break;
        end
        halfSpan = min(maxHalfHz, halfSpan + initialHalfHz);
    end

    fine = struct( ...
        'frequency', bins(bestBin), ...
        'weilPhase', phaseByBin(bestBin), ...
        'coherentSum', sumByBin(bestBin), ...
        'noisePower', noiseByBin(bestBin), ...
        'halfSpanHz', halfSpan, ...
        'atSearchLimit', atLimit);
end
