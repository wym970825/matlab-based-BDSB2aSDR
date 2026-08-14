
function acqResults = acquisition_robust_v2fft(longSignal, settings, varargin)
%ACQUISITION  BDS B2a acquisition (coarse 1ms + fine N ms pilot/Weil)
%
% 改进点：
%   1) 粗捕获：1ms切 8 段(0.125ms)，单次翻转组合；显式 Nfft
%   2) 精捕获：在 bestFineFreq / bestWeilPhase 下，对码相位做局部逐样点精细化（至少到码片/样点）
%
% Required:
%   longSignal  - raw IF / IQ samples, must contain >= N ms data at least
%   settings    - struct, receiver settings
%
% Optional name-value:
%   'STA'  - 'INIT' (default) or 'SING'
%   'PRN'  - scalar PRN, required if STA='SING'
%
% Output fields (per searched PRN):
%   carrFreq     - estimated carrier frequency (Hz, at IF domain)
%   codePhase    - code phase (sample index, 1-based)
%   peakMetric   - CPPR-like metric
%   peakMetric2  - CPPM-like metric
%   weilPhase    - estimated Weil(100) start phase [0..99] (fine stage)
%   polarityRef  - +1/-1 from pilot coherent sum (for ±pi / polarity ref)
%   coarseMode   - which flip-mode won in coarse stage (0..7)

% -----------------------------
% Parse inputs
% -----------------------------

p = inputParser;
p.FunctionName = mfilename;

addRequired(p, 'longSignal', @(x) isnumeric(x) && isvector(x) && ~isempty(x));
addRequired(p, 'settings',   @(x) isstruct(x));

addParameter(p, 'STA', 'INIT', @(s) ischar(s) || isstring(s));
addParameter(p, 'ISSILENT', false, @(x) islogical(x));
addParameter(p, 'USEFFT', false, @(x) islogical(x));
addParameter(p, 'SHOWFFT', false, @(x) islogical(x));
addParameter(p, 'PRN', [], @(x) isempty(x) || (isnumeric(x) && isscalar(x)));

parse(p, longSignal, settings, varargin{:});
STA = upper(string(p.Results.STA));
PRN = p.Results.PRN;
issilent = p.Results.ISSILENT;
usefft = p.Results.USEFFT;
showfft = p.Results.SHOWFFT;

% -----------------------------
% STA logic (INIT / SING)
% -----------------------------
if STA == "INIT"
    if isfield(settings,'acqSatelliteList') && ~isempty(settings.acqSatelliteList)
        SatList = settings.acqSatelliteList;
    else
        error('acquisition_robust:MissingAcqList',...
            'settings.acqSatelliteList is empty but STA==''INIT''.');
    end

elseif STA == "SING"
    if ~isempty(PRN)
        candidatePRN = PRN;
    elseif isfield(settings,'acqSatelliteList') && ~isempty(settings.acqSatelliteList)
        candidatePRN = settings.acqSatelliteList;
    else
        error('acquisition_robust:MissingPRN', ...
            'STA="SING" requires a scalar PRN via ''PRN'' or settings.acqSatelliteList.');
    end

    if isstring(candidatePRN) || ischar(candidatePRN)
        candidatePRN = str2num(candidatePRN); %#ok<ST2NM>
    end
    if ~isnumeric(candidatePRN) || isempty(candidatePRN)
        error('acquisition_robust:InvalidPRN','Provided PRN invalid/empty.');
    end
    if numel(candidatePRN) ~= 1
        error('acquisition_robust:PRNMustBeScalar','PRN must be scalar in SING.');
    end
    candidatePRN = double(candidatePRN);
    if candidatePRN <= 0 || candidatePRN ~= floor(candidatePRN)
        error('acquisition_robust:InvalidPRNValue','PRN must be positive integer.');
    end
    if isfield(settings,'acqSatelliteList') && ~isempty(settings.acqSatelliteList) && ...
            ~ismember(candidatePRN, settings.acqSatelliteList)
        warning('acquisition_robust:PRNNotInSettings',...
            'PRN=%d not in settings.acqSatelliteList; proceeding anyway.', candidatePRN);
    end

    SatList = candidatePRN;
    if ~ issilent
        fprintf('Single acquisition mode: PRN(%d) selected.\n', candidatePRN);
    end
else
    error('acquisition_robust:InvalidSTA','Invalid STA: %s (use INIT or SING).', STA);
end

% -----------------------------
% Basic parameters
% -----------------------------
fs = settings.samplingFreq;
ts = 1/fs;
fineNcoh = settings.fineNoncoh;

codeFreq = settings.codeFreqBasis;   % 10.23e6
codeLen  = settings.codeLength;      % 10230

samplesPerCode = round(fs / (codeFreq / codeLen));  % samples in 1ms

if isfield(settings,'fineCodeSearchHalfWinSamples')
    halfWin = settings.fineCodeSearchHalfWinSamples;
else
    samplesPerChip = fs / codeFreq;
    halfWin = max(1, round(2*samplesPerChip)); % default: +/-2 chips
end
delta_arr = -halfWin:halfWin;

% Nfft = 2^(1+nextpow2(samplesPerCode));
Nfft = samplesPerCode;

if length(longSignal) < fineNcoh*samplesPerCode
    error('Input signal is too short: need at least %d ms (%d samples).', ...
        fineNcoh, fineNcoh*samplesPerCode);
end

% 粗捕获用尾部 1ms（保持你原结构）
coarseStart = max(1, length(longSignal) - samplesPerCode + 1);
sig1ms  = longSignal(coarseStart : coarseStart + samplesPerCode - 1);

phasePoints1ms   = (0:samplesPerCode-1) * 2*pi*ts;
phasePoints_N_ms = (0:fineNcoh*samplesPerCode-1) * 2*pi*ts;

% -----------------------------
% Noise branch: build a "virtual PRN" local code for rough noise power
% -----------------------------
% rng(64);
noiseChips = sign(randn(1, codeLen));
noiseChips(noiseChips==0) = 1;
codeIdx1ms = floor((ts*(1:samplesPerCode)) / (1/codeFreq));
noiseLocal1ms = noiseChips(rem(codeIdx1ms, codeLen) + 1);
noiseLocal1ms = noiseLocal1ms(:).';

% -----------------------------
% Doppler bins (coarse)
% -----------------------------
numFrqBins = round(settings.acqSearchBand * 2 / settings.acqStep) + 1;
frqBins = zeros(1, numFrqBins);

% -----------------------------
% N-slice masks
% -----------------------------
nSeg = 8;
segEdges = round(linspace(0, samplesPerCode, nSeg+1)); % 0..N
segMask = false(nSeg, samplesPerCode);
for k = 1:nSeg
    a = segEdges(k)+1;
    b = segEdges(k+1);
    segMask(k, a:b) = true;
end

% -----------------------------
% single-flip sign patterns (mode=0..7)
%   mode=0: + + + + + + + +
%   mode=i: +...+ -...-  (flip after slice i)
% -----------------------------
flipSigns = ones(nSeg);            % [8 x 8]
for mode = 2:nSeg                         % mode index 2..8 => report 1..7
    flipSigns(mode, mode:nSeg) = -1;
end

% -----------------------------
% Init output struct
% -----------------------------
nSat = length(SatList);
acqResults.carrFreq     = nan(1, nSat);
acqResults.codePhase    = nan(1, nSat);
acqResults.codePhaseAbs = nan(1, nSat);
acqResults.peakMetric   = nan(1, nSat);
acqResults.peakMetric2  = nan(1, nSat);
acqResults.weilPhase    = nan(1, nSat);
acqResults.polarityRef  = nan(1, nSat);
acqResults.coarseMode   = nan(2, nSat);
acqResults.noisePow     = nan(1, nSat);
acqResults.CN0_pilot    = nan(1, nSat);

% -----------------------------
% Main acquisition loop
% -----------------------------
for si = 1:nSat
    tempRes = nan(Nfft,numFrqBins);
    prn = SatList(si);

    % --- Local pilot main-code (1ms sampled)
    pilotChips = generateB2aPilotCode(prn, settings); % length=10230, +/-1
    dataChips = generateB2aDataCode(prn); % length=10230, +/-1
    codeIdx1ms = floor((ts*(1:samplesPerCode)) / (1/codeFreq));
    localPilot1ms = pilotChips(rem(codeIdx1ms, codeLen) + 1);
    localdata1ms = dataChips(rem(codeIdx1ms, codeLen) + 1);
    localPilotFFT = conj(fft(localPilot1ms, Nfft));
    localDataFFT = conj(fft(localdata1ms, Nfft));

    EachModeRec = zeros(numFrqBins, 2);

    % -------------------------
    % Coarse: 1ms, 8-slice PCPS with single-flip model
    % -------------------------
    for bi = 1:numFrqBins
        frqBins(bi) = settings.IF - settings.acqSearchBand + settings.acqStep*(bi-1);

        carr = exp(-1i * frqBins(bi) * phasePoints1ms);
        bb = sig1ms(:).' .* carr; % complex baseband

        % C(k,tau): each slice PCPS
        C_pilot = zeros(nSeg, samplesPerCode);
        C_data = zeros(nSeg, samplesPerCode);
        for k = 1:nSeg
            xk = zeros(1, samplesPerCode);
            xk(segMask(k,:)) = bb(segMask(k,:));
            Xk = fft(xk, Nfft);
            tmp_pilot = ifft(Xk .* localPilotFFT, Nfft);
            tmp_data = ifft(Xk .* localDataFFT, Nfft);
            C_pilot(k,:) = tmp_pilot(1:samplesPerCode);
            C_data(k,:)  = tmp_data(1:samplesPerCode);
        end

        % Combine: S(mode,tau) = sum_k flipSigns(mode,k)*C(k,tau)
        S_pilot = flipSigns * C_pilot;
        S_data = flipSigns * C_data;

        % pilot branch -- 0
        [bestPerMode0, tauIdx0] = max(abs(S_pilot).^2, [], 2);
        modefit0 = abs(1/2 + (tauIdx0/samplesPerCode*nSeg) - (1:nSeg).')<=0.5;
        modefit0(1) = true; modefit0 = find(modefit0);
        bestPerMode0 = bestPerMode0(modefit0);
        % data branch -- 1
        [bestPerMode1, tauIdx1] = max(abs(S_data).^2, [], 2);
        modefit1 = abs(1/2 + (tauIdx1/samplesPerCode*nSeg) - (1:nSeg).')<=0.5;
        modefit1(1) = true; modefit1 = find(modefit1);
        bestPerMode1 = bestPerMode1(modefit1);
        
        [~, bestMode0Ind] = max(bestPerMode0);
        [~, bestMode1Ind] = max(bestPerMode1);
        bestMode0 = modefit0(bestMode0Ind);
        bestMode1 = modefit1(bestMode1Ind);

        EachModeRec(bi, :) = [bestMode0,bestMode1];
        tempRes(:,bi) = 0.5 * (abs(S_pilot(bestMode0,:).').^2 +...
            abs(S_data(bestMode1,:).').^2);

    end

    % Pick best bin
    [peakPerFB, bestTauPerFB] = max(tempRes,[],1);
    [peakCoarse, bestFBIndex] = max(peakPerFB,[],2);

    coarseCodePhase = bestTauPerFB(bestFBIndex);
    coarseMode      = EachModeRec(bestFBIndex,:);
    coarseCarrFreq  = frqBins(bestFBIndex);
    bestFB_Corr     = tempRes(:,bestFBIndex);

    % CPPR-like metric: second peak excluding +/- ~2 chips
    samplesPerChip2 = ceil(fs / codeFreq)*2;
    exclude1 = coarseCodePhase - samplesPerChip2;
    exclude2 = coarseCodePhase + samplesPerChip2;
    validIdx = true(1, samplesPerCode);
    if exclude1>0 && exclude2<samplesPerCode
        validIdx(exclude1 : exclude2) = false;
    elseif exclude1<0
        validIdx(samplesPerCode + exclude1 : samplesPerCode) = false;
        validIdx(1:exclude2) = false;
    elseif exclude2>=samplesPerCode
        validIdx(exclude1:samplesPerCode) = false;
        validIdx(1:exclude2-samplesPerCode) = false;
    end

    secondPeak = max(bestFB_Corr(validIdx));
    meanMetric = mean(bestFB_Corr(validIdx));

    acqResults.peakMetric(si)  = peakCoarse / secondPeak;
    acqResults.peakMetric2(si) = peakCoarse / meanMetric;
    acqResults.coarseMode(:,si)  = coarseMode.';

    if acqResults.peakMetric(si) < settings.acqThreshold && ~issilent
        fprintf('PRN(%02d) acquisition failed.\n', prn);
        continue;
    end

    if ~ issilent
        fprintf('PRN(%02d) coarse acquired: codePhase=%d, f=%.1fHz, mode=%1d and %1d for pilot and data\n', ...
            prn, coarseCodePhase, coarseCarrFreq, coarseMode(1), coarseMode(2));
    end
    % -------------------------
    % Fine: N ms, pilot + Weil(100) enumeration + fine Doppler
    % -------------------------
    % Fine window ends at tail 1ms, aligned to coarseCodePhase
    edAbs = length(longSignal)-samplesPerCode + (coarseCodePhase-1);
    stAbs = edAbs-fineNcoh*samplesPerCode+1;
    sigFine = longSignal(stAbs:edAbs).';
    if iscolumn(sigFine); sigFine = sigFine.'; end

    fineSpan = max(100, 2 * settings.acqStep); % Hz
    fineStep = 2;                      % Hz
    fineBins = (coarseCarrFreq - fineSpan/2) : fineStep : (coarseCarrFreq + fineSpan/2);

    localPilot1ms = localPilot1ms(:).'; % row
    localdata1ms = localdata1ms(:).';
    weil100 = GenWeil(prn);             % length 100, +/-1
    
    if usefft
        Nfft2 = 2^(nextpow2(samplesPerCode)+3);
        FFT_acc = zeros(1,Nfft2);
        Faxis = (0:Nfft2-1)*(fs/Nfft2) - fs/2;
        for slice_ii = 1:fineNcoh
            shortsig = sigFine(((slice_ii-1) * samplesPerCode) + 1:...
                slice_ii* samplesPerCode);
            FFT_acc = FFT_acc + ...
                abs(fftshift(fft(shortsig .* (localdata1ms + 1j*localPilot1ms),Nfft2)));
        end
        ind = abs(Faxis)<1e4;
        Faxis = Faxis(ind);
        FFT_acc = FFT_acc(ind);
        [Fmax,ind] = max(FFT_acc);
        fmax = Faxis(ind);

        if showfft
            figure('Units','centimeters','Position',[3,3,10,10],'Color','w');
            ax = newplot(); plot(ax, Faxis, FFT_acc,'-*','Color','b')
            hold on;scatter(ax, fmax,Fmax,20,'r','o');
            text(ax,fmax,Fmax,sprintf('f_m = %.1f(Hz)',fmax),'FontName',...
                'Time New Roman', 'FontSize',9,'HorizontalAlignment','left');
            grid on; set(gca,'Yscale','log','YLim',[min(FFT_acc),Fmax]);
        end
        
        fRange = [min([coarseCarrFreq,fmax]) - fineSpan/2,...
            max([coarseCarrFreq,fmax]) + - fineSpan/2];
        fineBins = (fRange(1) - fineSpan/2) : fineStep :...
            (fRange(2) + fineSpan/2);
    end
    
    bestZ = -inf;
    bestFineFreq  = coarseCarrFreq;
    bestWeilPhase = 0;
    bestPsum      = 0;
    bestNoisePow  = NaN;

    En = zeros(length(fineBins),1);
    for fb = 1:length(fineBins)
        f = fineBins(fb);
        carr_long = exp(-1i * f * phasePoints_N_ms);
        bb_long = sigFine .* carr_long;

        % per-ms pilot correlator outputs
        P = zeros(1,fineNcoh);
        for l = 1:fineNcoh
            idx = (l-1)*samplesPerCode + (1:samplesPerCode);
            P(l) = sum(bb_long(idx) .* localPilot1ms);
        end
        En(fb) = sqrt(sum(abs(P).^2)/fineNcoh);

        % noise branch
        Pnoise = zeros(1,fineNcoh);
        for l = 1:fineNcoh
            idx = (l-1)*samplesPerCode + (1:samplesPerCode);
            Pnoise(l) = sum(bb_long(idx) .* noiseLocal1ms);
        end
        NoisePowFb = mean(abs(Pnoise).^2);

        % Weil start phase
        for s = 0:99
            w = zeros(1,fineNcoh);
            for l = 1:fineNcoh
                w(l) = weil100(mod(s + (l-1), 100) + 1);
            end
            Psum = sum(w .* P);
            Z = abs(Psum);
            if Z > bestZ
                bestZ = Z;
                bestFineFreq  = f;
                bestWeilPhase = s;
                bestPsum      = Psum;
                bestNoisePow  = NoisePowFb;
            end
        end
    end

    % Polarity reference: force real(Psum) >= 0
    polarityRef = 1;
    if real(bestPsum) < 0
        polarityRef = -1;
        bestPsum = -bestPsum;
    end

    % -------------------------
    % Fine code-phase refinement (sample-level)
    % -------------------------
    idxWeil = mod((0:fineNcoh-1) + bestWeilPhase, 100) + 1;
    w = weil100(idxWeil);

    carr_best = exp(-1i * bestFineFreq * phasePoints_N_ms);
    bb_best = sigFine .* carr_best;

    bestDelta = 0;
    bestMag = -inf;

    % tempSig = nan(size(bb_best));
    for d_ii = 1:2*halfWin+1
        delta = delta_arr(d_ii);
        pilotShift = circshift(localPilot1ms, -delta); % 循环左移d_ii，相当于右移sig d_ii
        Pdelta = 0;
        for l = 1:fineNcoh
            idx = (l-1)*samplesPerCode + (1:samplesPerCode);
            P_l = sum(bb_best(idx) .* pilotShift);
            Pdelta = Pdelta + w(l) * P_l;
            % tempSig(idx) = w(l) * sigFine(idx) .* pilotShift;
        end
        mag = abs(Pdelta);
        temp(d_ii) = mag;
        if mag > bestMag
            bestMag = mag;
            bestDelta = delta;
        end
    end

    refinedCodePhase = coarseCodePhase + bestDelta;
    refinedCodePhase = mod(refinedCodePhase-1, samplesPerCode) + 1; % in a range of (1...N)

    % -------------------------
    % CN0 estimate (optional)
    % -------------------------
    N = fineNcoh;
    Tcoh = 1e-3;
    Ttotal = N * Tcoh;
    NoisePow = bestNoisePow;
    acqResults.noisePow(si) = NoisePow;
    if ~isnan(NoisePow) && NoisePow > 0
        SNRlin = (abs(bestPsum)^2 - N*NoisePow) / (N*NoisePow);
        SNRlin = max(SNRlin, 1e-12);
        acqResults.CN0_pilot(si) = 10*log10(SNRlin / Ttotal);
    else
        acqResults.CN0_pilot(si) = nan;
    end

    % Store results
    % 注意：这里沿用你函数原先的符号习惯（如果你 IF/多普勒定义不同，自行统一）
    acqResults.carrFreq(si)     = -bestFineFreq;
    acqResults.codePhase(si)    = refinedCodePhase;
    acqResults.codePhaseAbs(si) = edAbs + 1 - bestDelta;
    acqResults.weilPhase(si)    = bestWeilPhase;
    acqResults.polarityRef(si)  = polarityRef;
    if ~issilent
        fprintf('PRN(%02d) fine: f=%.1fHz, fineCodePhase=%d, WeilPhase=%d, polarityRef=%+d\n', ...
            prn, bestFineFreq, refinedCodePhase, bestWeilPhase, polarityRef);
    end
end
end
