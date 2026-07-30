function [finalTRes, ch] = trackOneChannel(ch, settings, c_i, TrkedNr)
%TRACKONECHANNEL Single-channel B2a tracking (private IF file handle).
%
%   [finalTRes, ch] = trackOneChannel(ch, settings, c_i, TrkedNr)
%
% Designed for serial or parfor multi-SV scheduling. Each call opens its own
% IF file so workers do not share file identifiers.
%
% Inputs:
%   ch       - channel struct (PRN, codePhase, acquiredFreq, ...)
%   settings - receiver settings
%   c_i      - channel index (for status prints)
%   TrkedNr  - total tracked channel count (status print)
%
% Outputs:
%   finalTRes - TrackResults2 for this PRN
%   ch        - possibly updated channel (e.g. after REACQ)

    if nargin < 3 || isempty(c_i), c_i = 1; end
    if nargin < 4 || isempty(TrkedNr), TrkedNr = 1; end

    finalTRes = TrackResults2.empty;
    if isempty(ch) || ~isfield(ch, 'PRN') || ch.PRN == 0
        return;
    end

    codePeriods = settings.msToProcess;
    if (settings.fileType == 1), dataAdaptCoeff = 1; else, dataAdaptCoeff = 2; end
    Nin1ms = settings.samplingFreq * 1e-3;

    useKF = false;
    if isfield(settings, 'KF') && isstruct(settings.KF) && isfield(settings.KF, 'enable')
        useKF = settings.KF.enable;
    end
    useFLL = false;
    if isfield(settings, 'FLL') && isstruct(settings.FLL) && isfield(settings.FLL, 'enable')
        useFLL = settings.FLL.enable;
    end
    useFLLfold = false;
    if isfield(settings, 'FLL') && isstruct(settings.FLL) && isfield(settings.FLL, 'useBpskFold')
        useFLLfold = settings.FLL.useBpskFold;
    end

    el_Spc = settings.dllCorrelatorSpacing;
    PDIcode = settings.intTime;
    % DLL: pull-in vs stable (switch with PLL at filter_pullinMS via nhsm)
    dllZeta = 0.707;
    if isfield(settings, 'dllDampingRatio') && ~isempty(settings.dllDampingRatio)
        dllZeta = settings.dllDampingRatio;
    end
    dllBwPull = 10;
    if isfield(settings, 'dllNoiseBandwidth_pull') && ~isempty(settings.dllNoiseBandwidth_pull)
        dllBwPull = settings.dllNoiseBandwidth_pull;
    end
    dllBwStab = 2;
    if isfield(settings, 'dllNoiseBandwidth_stab') && ~isempty(settings.dllNoiseBandwidth_stab)
        dllBwStab = settings.dllNoiseBandwidth_stab;
    elseif isfield(settings, 'dllNoiseBandwidth') && ~isempty(settings.dllNoiseBandwidth)
        dllBwStab = settings.dllNoiseBandwidth;
    end
    [tau1code_pull, tau2code_pull] = calcLoopCoef(dllBwPull, dllZeta, 1.0);
    [tau1code_stab, tau2code_stab] = calcLoopCoef(dllBwStab, dllZeta, 1.0);
    tau1code = tau1code_pull;
    tau2code = tau2code_pull;
    if ~isfield(settings, 'longCoh_ms'), settings.longCoh_ms = 20; end

    % --- private IF handle (parfor-safe) ---
    targetfile = fullfile(settings.filePath, settings.fileName);
    [fid, msg] = fopen(targetfile, 'rb');
    if fid <= 0
        error('trackOneChannel:OpenFailed', 'Unable to open %s: %s', targetfile, msg);
    end
    cleaner = onCleanup(@() local_fclose(fid)); %#ok<NASGU>

    trkBuf = TrackResults2(settings); % per-channel rolling buffer (chunked save)
    trkBuf.PRN     = ch.PRN;
    % Seek to this channel code-phase start (private file handle)
    seekBytes = settings.skipNumberOfBytes + settings.size_per_sample * (ch.codePhase - 1);
    if fseek(fid, seekBytes, 'bof') ~= 0
        error('trackOneChannel:SeekFailed', 'fseek failed for PRN %d codePhase=%g', ch.PRN, ch.codePhase);
    end
    %-----------------------------------------------------------------%
    % Local spreading code
    % Get a vector with the B2a data code sampled 1x/chip
    B2aData = generateB2aDataCode(ch.PRN);
    % Then make it possible to do early and late versions
    B2aData = [B2aData(settings.codeLength) B2aData B2aData(1)]; %#ok<AGROW>
    % Get a vector with the B2a pilot code sampled 1x/chip
    B2aPliot = generateB2aPilotCode(ch.PRN,settings); % (always enabled)
    B2aPliot = [B2aPliot(settings.codeLength) B2aPliot B2aPliot(1)]; %#ok<AGROW>

    % --- Pilot Weil(100) subcode (1ms-per-chip) handling ---
    % generate NH code (+/-1) and align with acquisition-estimated Weil phase.
    weil100 = GenWeil(ch.PRN); % length 100, +/-1
    if isfield(ch,'polarityRef'),polarityRef = ch.polarityRef; % +/-1
    else,polarityRef = 1;
    end

    %--- Perform various initializations ------------------------------
    remCodePhase  = 0.0;                % Define residual code phase (in chips)
    carrFreq      = ch.acquiredFreq ; % Define carrier frequency which is used over whole tracking period
    carrFreqBasis = ch.acquiredFreq ;
    remCarrPhase  = 0.0 + (polarityRef < 0) * pi; % Define residual carrier phase (apply acquisition polarity reference)
    % Code NCO: nominal + optional carrier aid (instantaneous carrFreq), DLL codeNco=0 at start
    codeFreq      = codeFreqFromCarrierAid(settings, carrFreq, 0);
    %code tracking loop parameters
    oldCodeNco   = 0.0;
    oldCodeError = 0.0;
    % Carrier/Costas loop parameters
    d2CarrError  = 0.0;
    dCarrError   = 0.0;
    % Long coherent carrier loop accumulators (pilot)
    PsumPilot = 0 + 1i*0;
    pdiCnt = 0;
    lastCarrError = 0.0;
    lastCarrNco = 0.0;
    % For C/No computation
    CNoValue = zeros(1,3);
    tempCNoValue = -ones(1,3);

    % --- FLL helper (1ms) ---
    prevPp_fll = 0 + 1i*0;
    fllErrHz = 0;
    fllErrHz_filt = 0;
    % --- NEW: FLL 2nd-order LPF (biquad) state ---
    xFLL_1 = 0; xFLL_2 = 0;     % x[n-1], x[n-2]
    yFLL_1 = 0; yFLL_2 = 0;     % y[n-1], y[n-2]
    bFLL = [1 0 0];             % [b0 b1 b2]
    aFLL = [1 0 0];             % [1 a1 a2]
    prevFLLLongFlag = false;
    % --- NEW: forced INIT aiding window counter ---
    fllInitRemain_ms = 0;
    prevNhStateStr = "";
    fllCorrHz = 0;

    % --- optional carrier Kalman filter (1ms base tick) ---
    if useKF, kf = CarrierKF2(settings); else, kf = [];end
    kf_lastCN0dB = nan; % last valid total CN0 (dB-Hz) used for KF R update
    % flag for KF phase measurement availability within current tick
    kf_phiMeasValid = false;
    kf_phiMeasRad = 0;
    kf_phiMeasTcoh = settings.intTime;
    enKFaided = false;
    if ~isempty(kf)
        if isfield(settings,'KF')
            if isstruct(settings.KF)
                if isfield(settings.KF,'enableFeedback')
                    enKFaided = settings.KF.enableFeedback;
                end
            end
        end
    end

    fbGain = 1.0;
    if isfield(settings.KF,'feedbackGain')
        fbGain = settings.KF.feedbackGain;
    end
    fbMaxHz = 200;
    if isfield(settings.KF,'maxCorrHz')
        fbMaxHz = settings.KF.maxCorrHz;
    end

    % initial
    % NH state machine initial
    if exist('nhsm','var'),delete(nhsm);end
    nhsm = NH_stateMachine(settings,ch.PRN);
    % Data subcode (length-5) for B2a data channel: 00010 (map 0->-1, 1->+1)
    % dataNH5 = [-1 -1 -1 +1 -1];

    % Update in version 5, Feb-2026
    % re-acquisition
    REACQbuff_size = Nin1ms*(settings.fineNoncoh + 1); % +1ms to allow fine stage window without wrap
    REACQbuff = zeros(REACQbuff_size,1);
    REACQbuff_pointer = 1;
    % REACQbuff_isfull = false;
    
    % Update in Version 4, Feb-2026
    % Pulse blanker (PB) initialization
    if settings.EnablePB
        pb = pulseBlanker(settings);
    end
    % force Aiding after acq
    forceInitAiding = true;

    % update in fix2 
    % --- scintillation calculator ---
    scCal = scint_calculator(settings);
    % scintillation warm-up should be counted from the latest successful
    % entry into tracking, not from the global loopCnt. This avoids using
    % unconverged S4 right after REACQ handover.
    scintWarmup_ms = 120e3;
    if isfield(settings,'KF') && isstruct(settings.KF) && ...
            isfield(settings.KF,'scintWarmup_ms') && ~isempty(settings.KF.scintWarmup_ms)
        scintWarmup_ms = settings.KF.scintWarmup_ms;
    end
    scintTrackAge_ms = 0;
    scintWarmReady = false;
    
    if isfield(settings,'KF') && isstruct(settings.KF) && ...
            isfield(settings.KF,'scintAdaptiveEnable') && ~isempty(settings.KF.scintAdaptiveEnable)
        useScintAdaptiveKF = logical(settings.KF.scintAdaptiveEnable);
    else
        useScintAdaptiveKF = false;
    end
    latestScintRes = struct();
    latestScintResValid = false;
    % Reusable tick log (avoid struct() alloc every ms — profile hotspot)
    tick = struct( ...
        'absoluteSample', 0, 'codeFreq', 0, 'carrFreq', 0, ...
        'I_E', 0, 'I_P', 0, 'I_L', 0, 'Q_E', 0, 'Q_P', 0, 'Q_L', 0, ...
        'Pilot_I_E', 0, 'Pilot_I_P', 0, 'Pilot_I_L', 0, ...
        'Pilot_Q_E', 0, 'Pilot_Q_P', 0, 'Pilot_Q_L', 0, ...
        'dllDiscr', 0, 'dllDiscrFilt', 0, 'pllDiscr', 0, 'pllDiscrFilt', 0, ...
        'remCodePhase', 0, 'remCarrPhase', 0, ...
        'cur_state', false, 'trk_state', uint8(0), ...
        'fllDiscrHz', 0, 'fllDiscrFiltHz', 0, 'fllCorrHz', 0, 'fllAided', false, ...
        'Ppre', NaN, 'Ppost', NaN, 'eta', NaN, ...
        'kf_phiRad', NaN, 'kf_omegaHz', NaN, 'kf_alphaHzps', NaN, ...
        'kf_corrHz', NaN, 'kf_nisPhi', NaN, 'kf_nisOmega', NaN, ...
        'kf_rmsNuPhiRad', NaN, 'kf_rmsNuOmegaHz', NaN);
    % power scale
    % + k + gain - 10*log10(fs);
    PwrK = settings.usrp.scaleK + settings.usrp.gain - 10*log10(settings.samplingFreq);
    %=== Process the number of specified code periods =================
    for loopCnt =  1 : codePeriods
        
        % Record NH state (update from v5(3 state) to v6 (5-state))
        % Use ChunkCapacity for ring index (Nsize may shrink after partsave)
        chunkCap = trkBuf.ChunkCapacity;
        if isempty(chunkCap) || chunkCap <= 0
            chunkCap = trkBuf.Nsize;
        end
        TRii = rem(loopCnt - 1, chunkCap) + 1; 
        isLongState = strncmpi(nhsm.STATE,'LONG',4); % LONG or LONG_FLL
        logCurState = isLongState;
        logTrkState = nhsm.getStateId();
        logFllAided = (strcmpi(nhsm.STATE,'INIT_FLL') || ...
            strcmpi(nhsm.STATE,'LONG_FLL') || forceInitAiding);
        % KF log defaults for this tick
        logKf_phi = NaN; logKf_omega = NaN; logKf_alpha = NaN;
        logKf_corr = NaN; logKf_nisPhi = NaN; logKf_nisOmega = NaN;
        logKf_rmsPhi = NaN; logKf_rmsOmega = NaN;
        logFllCorr = 0;
        %% UI update -------------------------------------------------
        % The GUI is updated every 200ms. This way Matlab GUI is still
        % responsive enough. At the same time Matlab is not occupied
        % all the time with GUI task.
        if (rem(loopCnt, 200) == 0)
            % Compose a single-line status to overwrite previous one
            % statusLine = sprintf(['|T|%6.2fd|' ...
            %     ' %02d/%02d PRN: %02d|' ...
            %     ' Completed: %6.2f%% |' ...
            %     ' CNo: (%4.1f-%4.1f) dB-Hz | ' ...
            %     'State: %8s |' ...
            %     ' S4: %.2f |' ...
            %     ' σΦ: %.2f|...' ...
            %     'ω: %.2f, Rω = %.2f' ...
            %     'φ: %.2f, Rφ = %.2f'], ...
            %     loopCnt*settings.intTime, c_i, TrkedNr, ch.PRN,...
            %     round(100*loopCnt/codePeriods,2), ...
            %     round(CNoValue(1),1), round(CNoValue(2),1),...
            %     string(nhsm.STATE),scCal.result.S4_ori, scCal.result.phi60,...
            %     omegaMeas, Romega, kf_phiMeasRad, Rphi);
            statusLine = sprintf(['|T|%6.2fd|' ...
                ' %02d/%02d PRN: %02d|' ...
                ' Completed: %6.2f%% |' ...
                ' CNo: (%4.1f-%4.1f) dB-Hz | ' ...
                'State: %8s |' ...
                ' S4: %.2f |' ...
                ' σΦ: %.2f|'], ...
                loopCnt*settings.intTime, c_i, TrkedNr, ch.PRN,...
                round(100*loopCnt/codePeriods,2), ...
                round(CNoValue(1),1), round(CNoValue(2),1),...
                string(nhsm.STATE),scCal.result.S4_ori, scCal.result.phi60);
            % print and return carriage to beginning of the line (overwrite)
            fprintf('%s\n', statusLine);
        end
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        % New in V4
        % If any CN0 (pilot or data) below CN0 threshold defined in
        % initSettings.m (settings.TrkCN0Th) is detected no matter the
        % state is 'LONG' or 'INIT' the state machine 'nhsm' will enter
        % the 'REACQ' state. During re-acquisition the tracking part
        % will actually stop and wait for the IF data load into a
        % buffer called 'REACQbuff'
        %
        % process the REACQ state
        if strcmpi(nhsm.STATE,'REACQ')
            % Mark C/No as invalid during REACQ
            % (so later post-processing can exclude them)
            if (rem(loopCnt,settings.CNoInterval)==0)
                CNoCnt = max(1, ceil(TRii / settings.CNoInterval));
                trkBuf.writeCNo(CNoCnt, -1, -1, -1, -1, -1);
            end

            % --- absoluteSample MUST be logged during REACQ ---
            % Previously continue'd without writeTick → NaN holes and broken
            % postNavigation TOW/index ↔ sample mapping after re-acq.
            logAbsSampleReacq = (ftell(fid)) / settings.size_per_sample;

            % load buffer in this step
            % ensure that only one ms data read in one step
            temp_data = fread(fid, dataAdaptCoeff*Nin1ms, settings.dataType);
            
            if (dataAdaptCoeff == 2)
                data_ii = temp_data(1:2:end);
                data_qq = temp_data(2:2:end);
                temp_data = data_ii + 1i .* data_qq;
            end
            if settings.EnablePB
                temp_data = pb.mitigate(temp_data);
            end
            REACQbuff(REACQbuff_pointer+1:REACQbuff_pointer + Nin1ms) = temp_data;
            REACQbuff_pointer = REACQbuff_pointer + Nin1ms;
            if REACQbuff_pointer == 0 
                fseek(fid,round(rand(1)*Nin1ms)*settings.size_per_sample,'cof');
            end

            % Log REACQ 1-ms slot (invalid correlators; keep sample timeline)
            tick.absoluteSample = logAbsSampleReacq;
            tick.codeFreq = codeFreq; tick.carrFreq = carrFreq;
            tick.I_E = 0; tick.I_P = 0; tick.I_L = 0;
            tick.Q_E = 0; tick.Q_P = 0; tick.Q_L = 0;
            tick.Pilot_I_E = 0; tick.Pilot_I_P = 0; tick.Pilot_I_L = 0;
            tick.Pilot_Q_E = 0; tick.Pilot_Q_P = 0; tick.Pilot_Q_L = 0;
            tick.dllDiscr = 0; tick.dllDiscrFilt = 0;
            tick.pllDiscr = 0; tick.pllDiscrFilt = 0;
            tick.remCodePhase = remCodePhase; tick.remCarrPhase = remCarrPhase;
            tick.cur_state = false; tick.trk_state = uint8(9); % REACQ
            tick.fllDiscrHz = 0; tick.fllDiscrFiltHz = 0;
            tick.fllCorrHz = 0; tick.fllAided = false;
            tick.Ppre = NaN; tick.Ppost = NaN; tick.eta = NaN;
            tick.kf_phiRad = NaN; tick.kf_omegaHz = NaN; tick.kf_alphaHzps = NaN;
            tick.kf_corrHz = NaN; tick.kf_nisPhi = NaN; tick.kf_nisOmega = NaN;
            tick.kf_rmsNuPhiRad = NaN; tick.kf_rmsNuOmegaHz = NaN;
            trkBuf.writeTick(TRii, tick);
            if rem(loopCnt, trkBuf.ChunkCapacity) == 0
                try, trkBuf.save(); catch, end %#ok<CTCH>
            end

            if REACQbuff_pointer >= REACQbuff_size
                % do acquisition (use v2fft; legacy acquisition_robust_v2 not required)
                try
                    acqResults = acquisition_robust_v2fft(REACQbuff, settings, ...
                        'STA', 'SING', 'PRN', ch.PRN, 'ISSILENT', true);
                catch ME
                    warning('tracking2_v6_fix2:REACQ', ...
                        'REACQ acquisition failed for PRN %d: %s', ch.PRN, ME.message);
                    acqResults = struct('carrFreq', NaN);
                end
                if isfield(acqResults, 'carrFreq') && any(isfinite(acqResults.carrFreq(:))) ...
                        && any(acqResults.carrFreq(:) ~= 0)
                    % --- REACQ -> tracking handover ---
                    % 1) Ensure preRun2 PRN mapping is correct in STA='SING'
                    tmpSettings = settings;
                    tmpSettings.numberOfChannels = 1;
                    tmpSettings.acqSatelliteList = ch.PRN;
                    cur_channel = preRun2(acqResults, tmpSettings);
                    cur_channel = cur_channel(1);

                    % 2) Sync channel struct baseline with re-acquisition result
                    ch.PRN          = cur_channel.PRN;
                    ch.acquiredFreq = cur_channel.acquiredFreq;
                    ch.codePhase    = cur_channel.codePhase;
                    ch.codeFreq     = cur_channel.codeFreq;
                    ch.status       = cur_channel.status;
                    ch.weilPhase    = cur_channel.weilPhase;
                    ch.polarityRef  = cur_channel.polarityRef;

                    % 3) Align file pointer to detected code start (tail 1 ms)
                    st = round(cur_channel.codePhase);
                    st = max(1, min(st, Nin1ms));
                    rewindComplexSamples = Nin1ms - (st - 1);
                    rewindBytes = - rewindComplexSamples * settings.size_per_sample;
                    pos0 = ftell(fid);
                    ret = fseek(fid, rewindBytes, 'cof');
                    pos1 = ftell(fid);
                    fprintf(['\tREACQ OK PRN%02d @loop %d fseek %d->%d' ...
                        ' rewindSamples=%d (post-REACQ re-INIT + frame re-sync in nav)\n'], ...
                        ch.PRN, loopCnt, pos0, pos1, rewindComplexSamples);
                    if ret ~= 0
                        warning('REACQ fseek failed -> handover likely wrong.');
                    end

                    % 4) Full tracking re-init (same as cold start after acq)
                    carrFreq      = ch.acquiredFreq;
                    carrFreqBasis = ch.acquiredFreq;
                    remCodePhase  = 0.0;
                    remCarrPhase  = (ch.polarityRef < 0) * pi;
                    oldCodeNco   = 0.0;
                    oldCodeError = 0.0;
                    codeFreq      = codeFreqFromCarrierAid(settings, carrFreq, 0);
                    d2CarrError  = 0.0;
                    dCarrError   = 0.0;
                    PsumPilot = 0 + 1i*0;
                    pdiCnt = 0;
                    lastCarrError = 0.0;
                    lastCarrNco = 0.0;
                    CNoValue = zeros(1,3);
                    tempCNoValue = -ones(1,3);
                    scintTrackAge_ms = 0;
                    scintWarmReady = false;
                    latestScintResValid = false;
                    if ~isempty(scCal)
                        scCal.reset();
                    end
                    if ~isempty(kf)
                        try, kf.reset(); catch, end %#ok<CTCH>
                    end
                    % Force NH SM back to INIT (frame/Weil re-sync path)
                    nhsm.NeedACQ = false;
                    nhsm.STATE = 'INIT';
                    nhsm.T_init = 0;
                    nhsm.T_long = 0;
                    nhsm.LastCN0 = [-1, -1];
                    nhsm.fllCntOn = 0;
                    nhsm.fllCntOff = 0;
                    % NH Weil / buffer: enter INIT via NeedACQ=false + update below
                    try
                        nhsm.NH_estimator.WeilPhase = -1;
                        nhsm.NH_estimator.Conf = -1;
                        nhsm.NH_estimator.Anchor = -1;
                    catch
                    end
                    % Arm FLL/pull-in window after re-acq (same as first acq)
                    if isfield(settings,'FLLinitT') && ~isempty(settings.FLLinitT) && settings.FLLinitT > 0
                        fllInitRemain_ms = round(settings.FLLinitT);
                    end
                    prevNhStateStr = "INIT";
                    % Marker for postNavigation: last successful REACQ loop index
                    if ~isfield(ch, 'reacqLoopCnt') || isempty(ch.reacqLoopCnt)
                        ch.reacqLoopCnt = loopCnt;
                    else
                        ch.reacqLoopCnt = [ch.reacqLoopCnt, loopCnt]; %#ok<AGROW>
                    end
                    ch.needFrameResync = true;
                else
                    % acquisition failed, keep state
                    nhsm.NeedACQ = true;
                end
                % Clear buffer
                REACQbuff_pointer = 0;
                REACQbuff = zeros(REACQbuff_size,1);
                % update state machine every time after the acq
                nhsm.update(0+1j*0, [-1,-1], loopCnt);
            end
            if nhsm.N_att > settings.REACQ_max % Too much attemp
                warning(['The attemp of re-acquisition has reached' ...
                    ' the limit, Tracking of PRN %02d End...'],ch.PRN)
                break;
            end
            continue;
        end
        %%%%%%%%%%%% End of ReACQ %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        % new in fix2
        % Count scintillation warm-up time only while normal tracking is
        % running. REACQ path continues earlier, so it is excluded here.
        scintTrackAge_ms = scintTrackAge_ms + settings.intTime * 1e3; % [ms] to [s]
        scintWarmReady = (scintTrackAge_ms >= scintWarmup_ms); 

        %% Read next block of data 
        % Sample index at start of this code period (before fread)
        logAbsSample = (ftell(fid)) / settings.size_per_sample;
        logPpre = NaN; logPpost = NaN; logEta = NaN;
        logRemCode = remCodePhase;
        logRemCarr = remCarrPhase;

        codePhaseStep = codeFreq / settings.samplingFreq;
        blksize = ceil((settings.codeLength - remCodePhase) / codePhaseStep);
        [rawSignal, samplesRead] = fread(fid, ...
            dataAdaptCoeff*blksize, settings.dataType);
        rawSignal = rawSignal.';
        if (dataAdaptCoeff==2)
            rawSignalIdat = rawSignal(1:2:end);
            rawSignalQdat = rawSignal(2:2:end);
            rawSignal = rawSignalIdat + 1j * rawSignalQdat;
        end
        if (samplesRead ~= dataAdaptCoeff*blksize)
            warning('Not able to read the specified number of samples for tracking, exiting channel early!')
            break
        end
        if settings.EnablePB
            rawSignal = pb.mitigate(rawSignal);
            logPpre  = pb.Ppre + PwrK;
            logPpost = pb.Ppost + PwrK;
            logEta   = pb.PDC;
        end
        %-------------------------------------------------------------%
        pf = nhsm.pf;

        % Weil(100) NH wipe-off on pilot when LONG*
        if strncmpi(nhsm.STATE,'LONG',4)
            weilIdx = mod(nhsm.NH_estimator.WeilPhase + ...
                (loopCnt - nhsm.NH_estimator.Anchor), 100);
            nh = weil100(weilIdx + 1);
        else
            nh = 1;
        end

        % P2: dual-channel E/P/L correlator (MEX when available)
        [corr, remCodePhase, remCarrPhase] = correlateB2aMs( ...
            rawSignal, B2aData, B2aPliot, ...
            remCodePhase, remCarrPhase, ...
            codeFreq, carrFreq, settings.samplingFreq, ...
            settings.codeLength, el_Spc, nh);
        I_E = corr.I_E; Q_E = corr.Q_E;
        I_P = corr.I_P; Q_P = corr.Q_P;
        I_L = corr.I_L; Q_L = corr.Q_L;
        pilot_I_E = corr.Pilot_I_E; pilot_Q_E = corr.Pilot_Q_E;
        pilot_I_P = corr.Pilot_I_P; pilot_Q_P = corr.Pilot_Q_P;
        pilot_I_L = corr.Pilot_I_L; pilot_Q_L = corr.Pilot_Q_L;

        % Pilot prompt complex (rotate -pi/2 so pilot aligns to data-phase)
        Pp = (pilot_I_P + 1i * pilot_Q_P) * exp(-1i * pi/2);

        % update scintillation calculator
        % state
        % NOTE: any S4-driven KF adaptation should use scintWarmReady,
        % which is counted from the latest successful tracking handover
        scCal.push(pilot_I_P, pilot_Q_P, remCarrPhase,[],isLongState, CNoValue(2));
        if scCal.hasNewResult() % save result.
            S4result = scCal.getResult();
            % save last S4 result
            latestScintRes = S4result; % save last
            latestScintResValid = isstruct(S4result) && isfield(S4result,'valid') && logical(S4result.valid);
            S4 = sqrt(max(0,S4result.S4_ori.^2 - S4result.S4_corr.^2));
            CNoCnt = max(1, ceil(TRii / settings.CNoInterval));
            if ~mod(TRii,settings.CNoInterval)
                trkBuf.writeS4(CNoCnt, S4result.S4_ori, S4result.S4_corr, S4);
            end
        end
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        % --- FLL discriminator (1ms) based on pilot prompt ---
        % fllErrHz estimates residual (incoming - local) frequency error in Hz.
        if useFLL
            if loopCnt == 1
                fllErrHz = 0;
                fllErrHz_filt = 0;
            else
                % discriminate Frequency
                cross = Pp * conj(prevPp_fll);
                dphi = atan2(imag(cross), real(cross)); % rad in (-pi, pi)
                % Optional: fold modulo pi to suppress +/-1 (NH) flips (BPSK ambiguity)
                if useFLLfold
                    dphi = mod(dphi + pi/2, pi) - pi/2;
                end
                % from differential phase to omega
                fllErrHz = dphi / (2*pi*settings.intTime);
                % --- NEW: update LPF coeffs when switching INIT/LONG ---
                isLongState = strncmpi(nhsm.STATE,'LONG',4);
                if loopCnt==1 || (isLongState ~= prevFLLLongFlag)
                    prevFLLLongFlag = isLongState;
                    zetaF = settings.FLL.filtZeta;
                    bwF = settings.FLL.BW_Init_Hz;
                    if isLongState && isfield(settings.FLL,'BW_Long_Hz')
                        bwF = settings.FLL.BW_Long_Hz;
                    end
                    % fs = 1/Ttick
                    fsFLL = 1/settings.intTime;
                    [bFLL, aFLL] = designFLL2ndLPF(bwF, zetaF, fsFLL);
                    % reset memory to avoid transient glitch on mode switch
                    xFLL_1 = 0; xFLL_2 = 0;
                    yFLL_1 = 0; yFLL_2 = 0;
                    fllErrHz_filt = 0;
                end
                % --- NEW: biquad LPF ---
                fllErrHz_filt = bFLL(1)*fllErrHz + bFLL(2)*xFLL_1 + bFLL(3)*xFLL_2 ...
                    - aFLL(2)*yFLL_1 - aFLL(3)*yFLL_2;

                xFLL_2 = xFLL_1; xFLL_1 = fllErrHz;
                yFLL_2 = yFLL_1; yFLL_1 = fllErrHz_filt;
            end
            prevPp_fll = Pp;
        else
            fllErrHz = 0;
            fllErrHz_filt = 0;
        end

        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        % Carrier loop driving signal:
        % - INIT/EST: use DATA prompt (stable, no Weil NH flips) for
        %             pull-in (1ms update)
        % - LONG    : use PILOT prompt (NH wiped) with long coherent 
        %             accumulation
        if strncmpi(nhsm.STATE,'LONG',4)
            Pp_nhsm = nh*Pp;
            PDIcarr_ms = settings.longCoh_ms;
            % Coherent accumulate pilot for carrier discriminator
            PsumPilot = PsumPilot + Pp;
            pdiCnt = pdiCnt + 1;
            % Only update PLL every PDIcarr_ms
            if pdiCnt >= PDIcarr_ms
                carrError = costasPhaseErrCycles(PsumPilot);
                % KF phase measurement (available only at coherent accumulation boundaries)
                kf_phiMeasValid = true;
                kf_phiMeasRad = 2*pi*carrError; % carrier phase error in radius
                kf_phiMeasTcoh = PDIcarr_ms * settings.intTime; % Long Coherent in [s]

                lastCarrError = carrError;

                % Loop filter update (supports 2nd- or 3rd-order, pf is column vector)
                % PLL
                if numel(pf) == 2
                    pf1 = pf(1); pf2 = pf(2);
                    dCarrError = dCarrError + carrError * pf2;
                    carrNco    = dCarrError + carrError * pf1;
                else
                    pf1 = pf(1); pf2 = pf(2); pf3 = pf(3);
                    d2CarrError = d2CarrError + carrError * pf3;
                    dCarrError  = d2CarrError + carrError * pf2 + dCarrError;
                    carrNco     = dCarrError + carrError * pf1;
                end

                lastCarrNco = carrNco;

                % Modify carrier freq based on NCO command
                carrFreq = carrFreqBasis + carrNco;

                % reset coherent accumulator
                PsumPilot = 0 + 1i*0;
                pdiCnt = 0;
            end
        else
            % Use a "folded" discriminator (equivalent to atan(Q/I) near lock, but quadrant-safe):
            % Pd = (I_P + 1i * Q_P);
            % carrError = atan2(imag(Pd), real(Pd)) / (2.0 * pi);
            Pp_nhsm = Pp;
            % Costas discriminator in cycles (quadrant-safe + half-cycle folded)
            % Use PILOT prompt for carrier tracking (data branch may be affected by bits/subcode).
            carrError = costasPhaseErrCycles(Pp);
            % KF phase measurement (1ms)
            kf_phiMeasValid = true;
            kf_phiMeasRad = 2*pi*carrError;
            kf_phiMeasTcoh = settings.intTime;

            lastCarrError = carrError;

            if numel(pf) == 2
                pf1 = pf(1); pf2 = pf(2);
                dCarrError = dCarrError + carrError * pf2;
                carrNco    = dCarrError + carrError * pf1;
            else
                pf1 = pf(1); pf2 = pf(2); pf3 = pf(3);
                d2CarrError = d2CarrError + carrError * pf3;
                dCarrError  = d2CarrError + carrError * pf2 + dCarrError;
                carrNco     = dCarrError + carrError * pf1;
            end

            lastCarrNco = carrNco;
            carrFreq = carrFreqBasis + carrNco;

            % reset coherent accumulator
            PsumPilot = 0 + 1i*0;
            pdiCnt = 0;
        end

        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        %% Find DLL error and update code NCO -------------------------
        % Sync DLL BW with PLL pull-in window (same nhsm.usePullinFilters)
        if nhsm.usePullinFilters()
            tau1code = tau1code_pull;
            tau2code = tau2code_pull;
        else
            tau1code = tau1code_stab;
            tau2code = tau2code_stab;
        end
        % Pilot-only DLL discriminator (E-L / E+L)
        E = sqrt(pilot_I_E * pilot_I_E + pilot_Q_E * pilot_Q_E);
        L = sqrt(pilot_I_L * pilot_I_L + pilot_Q_L * pilot_Q_L);
        codeError_Pilot = (E - L) / (E + L)  ;   % In chips
        codeError_Data = (sqrt(I_E * I_E + Q_E * Q_E) - sqrt(I_L * I_L + Q_L * Q_L)) / ...
            (sqrt(I_E * I_E + Q_E * Q_E) + sqrt(I_L * I_L + Q_L * Q_L)) ;   % In chips
        codeError = (codeError_Pilot + codeError_Data)/2;

        % Implement code loop filter and generate NCO command
        codeNco = oldCodeNco + (tau2code/tau1code) * ...
            (codeError - oldCodeError) + codeError * (PDIcode/tau1code);
        oldCodeNco   = codeNco;
        oldCodeError = codeError;
        % Log the code frequency used for THIS correlation, then update NCO
        % Carrier-aided: f_code = f0 + clamp(-carrFreq*f0/fL) - codeNco
        logCodeFreq = codeFreq;
        codeFreq = codeFreqFromCarrierAid(settings, carrFreq, codeNco);

        % P0: bulk 1-ms log (mutate reusable tick — no struct alloc)
        tick.absoluteSample = logAbsSample;
        tick.codeFreq = logCodeFreq; tick.carrFreq = carrFreq;
        tick.I_E = I_E; tick.I_P = I_P; tick.I_L = I_L;
        tick.Q_E = Q_E; tick.Q_P = Q_P; tick.Q_L = Q_L;
        tick.Pilot_I_E = pilot_I_E; tick.Pilot_I_P = pilot_I_P; tick.Pilot_I_L = pilot_I_L;
        tick.Pilot_Q_E = pilot_Q_E; tick.Pilot_Q_P = pilot_Q_P; tick.Pilot_Q_L = pilot_Q_L;
        tick.dllDiscr = codeError; tick.dllDiscrFilt = codeNco;
        tick.pllDiscr = lastCarrError; tick.pllDiscrFilt = lastCarrNco;
        tick.remCodePhase = logRemCode; tick.remCarrPhase = logRemCarr;
        tick.cur_state = logCurState; tick.trk_state = logTrkState;
        tick.fllDiscrHz = fllErrHz; tick.fllDiscrFiltHz = fllErrHz_filt;
        tick.fllCorrHz = 0; tick.fllAided = logFllAided;
        tick.Ppre = logPpre; tick.Ppost = logPpost; tick.eta = logEta;
        tick.kf_phiRad = NaN; tick.kf_omegaHz = NaN; tick.kf_alphaHzps = NaN;
        tick.kf_corrHz = NaN; tick.kf_nisPhi = NaN; tick.kf_nisOmega = NaN;
        tick.kf_rmsNuPhiRad = NaN; tick.kf_rmsNuOmegaHz = NaN;
        trkBuf.writeTick(TRii, tick);

        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        %% CNo calculation -------------------------------------------
        if (rem(loopCnt,settings.CNoInterval)==0)
            % Computation of CNo and PLL detector output
            try
                [CNoValue, PllDetector] = Calc_CNo_PLD(...
                    trkBuf,settings,TRii);
            catch
                % Legacy helper may require struct input
                [CNoValue, PllDetector] = Calc_CNo_PLD(...
                    trkBuf.toStruct(),settings,TRii);
            end
            CNoCnt = max(1, ceil(TRii / settings.CNoInterval));
            % Save C/No for data channel: a o.5-0.5 filter is used.
            averageCNo = CNoValue/2 + tempCNoValue/2;
            trkBuf.writeCNo(CNoCnt, averageCNo(1), PllDetector(1), ...
                averageCNo(2), PllDetector(2), averageCNo(3));

            tempCNoValue = CNoValue;
            % update KF CN0 cache (use total CN0)
            if isfinite(tempCNoValue(3)) && (tempCNoValue(3) > 0)
                kf_lastCN0dB = tempCNoValue(3);
            end
        end

        % --- NH state machine update ---
        % IMPORTANT: For B2a, data-channel C/No can be unreliable (data bits/subcode not removed),
        % which may cause false REACQ triggers if we use [data,pilot].
        % Use TOTAL C/No (CNo(3)) for both entries to drive REACQ decision more robustly.
        cnoDrive = [-1, -1];
        if all(isfinite(tempCNoValue)) && numel(tempCNoValue) >= 3 && (tempCNoValue(3) > 0)
            cnoDrive = [tempCNoValue(3), tempCNoValue(3)];
        end
        nhsm.update(Pp_nhsm, cnoDrive, loopCnt, fllErrHz_filt);
        % --- NEW: forced INIT aiding window after acquisition/reacquisition ---
        if strlength(prevNhStateStr)==0
            prevNhStateStr = string(nhsm.STATE);
        end
        % on transition into INIT, arm the init-aiding timer
        if ~strcmpi(prevNhStateStr, nhsm.STATE) && strcmpi(nhsm.STATE,'INIT')
            if isfield(settings,'FLLinitT') && ~isempty(settings.FLLinitT) && settings.FLLinitT > 0
                fllInitRemain_ms = round(settings.FLLinitT);
            end
        end
        prevNhStateStr = string(nhsm.STATE);
        forceInitAiding = (fllInitRemain_ms > 0) && strcmpi(nhsm.STATE,'INIT');
        if forceInitAiding
            fllInitRemain_ms = fllInitRemain_ms - 1;
        end


        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        % --- Optional carrier Kalman filter update (1ms tick) ---
        if ~isempty(kf)
            % 1ms prediction
            kf.predict(settings.intTime);

            % Update R based on last valid CN0 (if available)
            CN0dB = kf_lastCN0dB;
            if ~isfinite(CN0dB)
                % fall back to current smoothed value (if available)
                if all(isfinite(tempCNoValue)) && numel(tempCNoValue) >= 3 && (tempCNoValue(3) > 0)
                    CN0dB = tempCNoValue(3);
                end
            end

            % FLL frequency measurement (rad/s)
            omegaMeas = 2*pi*fllErrHz_filt;
            % new in fix2
            % Frequency / phase measurement noise:
            % use baseline CN0-driven model during warm-up, and switch to
            % scintillation-driven adaptation only after scintWarmReady.
            useScintKF = useScintAdaptiveKF && scintWarmReady && latestScintResValid;
            % Baseline frequency measurement noise (rad/s)^2
            
            % Default KF measurement-noise model from CN0 / initial floors
            Romega = (2*pi*settings.KF.RomegaFloor_Hz)^2;
            Rphi = (settings.KF.RphiFloor_deg*pi/180)^2;

            if isfinite(CN0dB) && (CN0dB > 0)
                % derive from phase noise approximation (use 1ms for FLL)
                CN0lin = 10^(CN0dB/10);
                SNRcoh = CN0lin * settings.intTime;
                Rphi_tmp = 1/(2*max(SNRcoh,eps));
                Romega = max(Romega, 2*Rphi_tmp/(settings.intTime^2));
                SNRcoh_phi = CN0lin * kf_phiMeasTcoh;
                Rphi = max(Rphi, 1/(2*max(SNRcoh_phi,eps)));
            end
            % Baseline phase measurement noise (rad^2)
            %%%%%%%% New in fix2 %%%%%%%%%
            % Switch to S4-driven KF tuning only after the warm-up tied to
            % the latest successful tracking segment has completed.
            if useScintKF 
                kfR = scint_calculator.computeKF_R(latestScintRes, settings, nhsm);
                % New in fix2
                % Only use scintillation indicator to update KF when
                % there is amptitude or phase scintillation
                haveScintillation = (latestScintRes.S4_ori>0.3) && (latestScintRes.tau0>0.05) || latestScintRes.phi60 > 0.3;
                if isstruct(kfR) && isfield(kfR,'valid') && logical(kfR.valid) && haveScintillation
                    % Romega = kfR.Romega;
                    Rphi = kfR.Rphi;
                    % if isprop(kf,'qJerk')
                    %     kf.qJerk = scint_calculator.computeKF_qJerk(latestScintRes, kf.qJerk, settings);
                    % end
                end
            end
            kf.updateOmega(omegaMeas, Romega);
            % Phase measurement update when available (short: every ms, long: every PDI boundary)
            if kf_phiMeasValid && isfinite(CN0dB) && (CN0dB > 0)
                kf.updatePhi(kf_phiMeasRad, Rphi);
                % debug
                % fprintf('%.2f,%.2f,%.2f,%.2f\n',omegaMeas, Romega, kf_phiMeasRad, Rphi);
            end

            % log KF states (phi[rad], omega[Hz], alpha[Hz/s]) — patch into tick
            trkBuf.kf_phiRad(TRii)    = kf.x(1);
            trkBuf.kf_omegaHz(TRii)   = kf.x(2)/(2*pi);
            trkBuf.kf_alphaHzps(TRii) = kf.x(3)/(2*pi);
            trkBuf.kf_corrHz(TRii)    = 0;
        end

        % --- Apply aiding correction for NEXT tick (either KF feedback or direct FLL injection) ---
        fllCorrHz = 0; % clear memory
        isFllAidedNext = (strcmpi(nhsm.STATE,'INIT_FLL') ||...
            strcmpi(nhsm.STATE,'LONG_FLL') ||...
            forceInitAiding); % FLL aiding only when needed or the beginning of INIT state

        % Prefer KF feedback (if enabled) over direct FLL injection
        if isFllAidedNext && enKFaided % Kalman result aiding
            deltaHz = kf.feedback(fbGain, fbMaxHz);
            carrFreqBasis = carrFreqBasis + deltaHz;
            carrFreq = carrFreqBasis + lastCarrNco;
            % --- NEW: KF consistency metrics ---
            kfm = kf.getMetrics();
            trkBuf.kf_corrHz(TRii)       = deltaHz;
            trkBuf.kf_nisPhi(TRii)       = kfm.NIS_phi;
            trkBuf.kf_nisOmega(TRii)     = kfm.NIS_omega;
            trkBuf.kf_rmsNuPhiRad(TRii)  = kfm.RMS_nu_phi_rad;
            trkBuf.kf_rmsNuOmegaHz(TRii) = kfm.RMS_nu_omega_rads/(2*pi);

        else % tradional aiding
            doTraditionalAid = isFllAidedNext &&...
                isfield(settings,'FLL') &&...
                isstruct(settings.FLL) &&...
                isfield(settings.FLL,'aidingEnable') &&...
                settings.FLL.aidingEnable;
            if doTraditionalAid 
                if strcmpi(nhsm.STATE,'LONG_FLL')
                    gain = settings.FLL.gainLong;
                else
                    gain = settings.FLL.gainInit;
                end
                fllCorrHz = gain * fllErrHz_filt;
                maxCorr = settings.FLL.maxCorrHz;
                fllCorrHz = max(min(fllCorrHz, maxCorr), -maxCorr); % Bound correction
                carrFreqBasis = carrFreqBasis + fllCorrHz; 
                carrFreq = carrFreqBasis + lastCarrNco;
            end
        end
        trkBuf.fllCorrHz(TRii) = fllCorrHz;
        % reset KF phase-meas flag for next tick
        kf_phiMeasValid = false;
        % save and clear buffer when it is full
        if rem(loopCnt, trkBuf.ChunkCapacity) == 0
            % Full chunk only (capacity, not truncated Nsize)
            succeed = trkBuf.save();
            if ~succeed
                warning('Tracking Result didnot saved.');
            end
        end

    end % for loopCnt
    % Tail partial chunk only when last loopCnt is NOT a full-chunk boundary (BUG-5)
    if rem(loopCnt, trkBuf.ChunkCapacity) ~= 0
        succeed = trkBuf.partsave(settings, TRii);
        if ~succeed
            warning('Tracking Result didnot saved.');
        end
    end

    %% Gather all temporary TR chunks into one final object
    targetPRN = ch.PRN;
    chunkCap = trkBuf.ChunkCapacity;
    if isempty(chunkCap) || chunkCap <= 0
        chunkCap = min(codePeriods, 6e4);
    end
    FileNum = ceil(codePeriods / chunkCap);
    finalTRes = TrackResults2(settings, codePeriods);
    I_start = 1;
    for file_ii = 1:FileNum
        TRfileName = sprintf('Trk_Prn_%02d_%03d.mat', targetPRN, file_ii);
        TRfileName = fullfile(settings.tempdataSvPth, TRfileName);
        if exist(TRfileName, "file")
            tmpTrk = load(TRfileName);
            tmpTrk = tmpTrk.obj;
            succeed = finalTRes.copyFROM(tmpTrk, I_start);
            % Advance by actual sample length, not stale capacity (BUG-6)
            I_start = I_start + numel(tmpTrk.I_P);
            if succeed >= 1
                disp(TRfileName);
            end
        else
            warning('tracking2_v6_fix2:MissingChunk', 'Missing %s', TRfileName);
        end
    end
    finalTRes.PRN = ch.PRN;
    finalTRes.status  = ch.status;
    finalTRes.Nsize = codePeriods;
    %% Extract the time stamp for each measurement (best-effort)
    % Full TOW alignment requires valid B-CNAV2 preamble; short smoke
    % runs may not decode — leave Timestamp as NaN in that case.
    try
        [ephPrn, subFrameStart, towVal] = BCNAV2decoding(finalTRes.I_P);
        if isfield(ephPrn, 'SOW') && isfinite(ephPrn.SOW) ...
                && isfinite(subFrameStart)
            TOW_first_tracking_result = ephPrn.SOW ...
                - subFrameStart * settings.intTime;
            tracking_result_time = TOW_first_tracking_result + settings.intTime : ...
                settings.intTime : ...
                (TOW_first_tracking_result + settings.msToProcess / 1000);
            nTs = min(numel(tracking_result_time), finalTRes.Nsize);
            finalTRes.Timestamp(1:nTs) = tracking_result_time(1:nTs);
        end
    catch ME
        warning('tracking2_v6_fix2:BCnavDecode', ...
            'PRN %d BCNAV2 decode/timestamp skipped: %s', ch.PRN, ME.message);
    end
    % Post-estimate loop thermal noise (sigma_DLL in chips, sigma_PLL in degrees)
    try
        finalTRes.estimateLoopNoise(settings);
    catch ME
        warning('tracking2_v6_fix2:LoopNoise', ...
            'PRN %d estimateLoopNoise skipped: %s', ch.PRN, ME.message);
    end
    % so far so good, try to save the result
    TRfileName = fullfile(settings.tempdataSvPth,sprintf('Trk_Prn_%02d_final.mat', targetPRN));
    try
        save(TRfileName,"finalTRes",'-mat');
        succeed = true;
    catch
        succeed = false;
    end
    if ~succeed
        warning('tracking2_v6_fix2 final result of PRN %d failed', ch.PRN);
    end

    fprintf('Channel %d PRN %02d tracking results collected.\n', c_i, ch.PRN);


end % trackOneChannel

function local_fclose(fid)
    if ~isempty(fid) && fid > 0
        try, fclose(fid); catch, end %#ok<CTCH>
    end
end

function e = costasPhaseErrCycles(P)
if isempty(P) || ~isfinite(real(P)) || ~isfinite(imag(P)) || (real(P)==0 && imag(P)==0)
    e = 0;
    return;
end
e = atan2(imag(P), real(P)) / (2*pi);
if e > 0.25
    e = e - 0.5;
elseif e < -0.25
    e = e + 0.5;
end
end

function [b, a] = designFLL2ndLPF(fc_Hz, zeta, fs_Hz)
if nargin < 2 || isempty(zeta), zeta = 0.707; end
fc_Hz = max(fc_Hz, 0.01);
zeta  = max(zeta, 0.05);
T  = 1/fs_Hz;
wn = 2*pi*fc_Hz;
K  = 2/T;
A0 = K^2 + 2*zeta*wn*K + wn^2;
A1 = 2*(wn^2 - K^2);
A2 = K^2 - 2*zeta*wn*K + wn^2;
b = [wn^2, 2*wn^2, wn^2] / A0;
a = [1, A1/A0, A2/A0];
end
