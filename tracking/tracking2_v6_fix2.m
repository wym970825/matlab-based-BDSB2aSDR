function [Tres, Ch]= tracking2_v6_fix2(fid, Ch, settings)
% Performs code and carrier tracking for B2a signals of all channels.
%
%[trackResults, channel] = tracking(fid, channel, settings)
%
%   Inputs:
%       fid             - file identifier of the signal record.
%       channel         - PRN, carrier frequencies and code phases of all
%                       satellites to be tracked (prepared by preRum.m from
%                       acquisition results).
%       settings        - receiver settings.
%   Outputs:
%       trackResults    - tracking results (structure array). Contains
%                       in-phase prompt outputs and absolute spreading
%                       code's starting positions, together with other
%                       observation data from the tracking loops. All are
%                       saved every millisecond.

%--------------------------------------------------------------------------
%                         CU Multi-GNSS SDR
% (C) Developed for BDS B2a SDR by Yafeng Li, Nagaraj C. Shivaramaiah
% and Dennis M. Akos.
% Based on the original framework for GPS C/A SDR by Darius Plausinaitis,
% Peter Rinder, Nicolaj Bertelsen and Dennis M. Akos
%
%                         KF-FLL-Aided
% Xiaoyeyimier version 6 using FLL aided PLL (try KF)
% work with NH_stateMachine.m TrackResults.m and CarrierKF.m



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Initialization
% basic settings
codePeriods = settings.msToProcess;     % Least update interval = 1ms
%Initialize the multiplier to adjust for the data type
if (settings.fileType==1),dataAdaptCoeff=1;else,dataAdaptCoeff=2;end
% samples amount in 1 ms
Nin1ms = settings.samplingFreq*1e-3; 

% new in version 6 KF enalble
useKF = false;
if isfield(settings,'KF')
    if isstruct(settings.KF)
        if isfield(settings.KF,'enable')
            useKF = settings.KF.enable;
        end
    end
end

if isfield(settings,'FLL')
    if isstruct(settings.FLL)
        if isfield(settings.FLL,'enable')
            useFLL = settings.FLL.enable;
        end
    end
end

useFLLfold = false;
if isfield(settings.FLL,'useBpskFold')
    useFLLfold = settings.FLL.useBpskFold;
end

% ---------- DLL variables ---------- %
% Define early-late offset (in chips)
el_Spc = settings.dllCorrelatorSpacing;% 0.5 chips
% Summation interval
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

% ---------- PLL variables ---------- %
% Long coherent carrier update length (ms)
if ~isfield(settings,'longCoh_ms'),settings.longCoh_ms = 20;end
% Get Number of acquired signals
TrkedNr = 0 ;
for c_i = 1:settings.numberOfChannels
    if Ch(c_i).status == 'T'
        TrkedNr = TrkedNr+1;
    end
end
% Initialize result container (one slot per channel; inactive keep status '-')
% FIX (refactor): original code overwrote Tres each channel and never returned
% the assembled finalTRes to the caller — navigation was disconnected.
Tres = TrackResults2.createArray(settings, settings.numberOfChannels);

% Power convert

% acq_fineshed_absPos = ftell(fid);
%% Start processing channels ==============================================
for c_i = 1:settings.numberOfChannels
    % Only process if PRN is non zero (acquisition was successful)
    if (Ch(c_i).PRN ~= 0)
        trkBuf = TrackResults2(settings); % per-channel rolling buffer (chunked save)
        trkBuf.PRN     = Ch(c_i).PRN;
        % Move the starting point of processing. Can be used to start the
        % signal processing at any point in the data record (e.g. for long
        % records). In addition skip through that data file to start at the
        % appropriate sample (corresponding to code phase).
        fseek(fid, ...
            (settings.skipNumberOfBytes + settings.size_per_sample*(Ch(c_i).codePhase-1)), ...
            'bof');
        ftell(fid);
        %-----------------------------------------------------------------%
        % Local spreading code
        % Get a vector with the B2a data code sampled 1x/chip
        B2aData = generateB2aDataCode(Ch(c_i).PRN);
        % Then make it possible to do early and late versions
        B2aData = [B2aData(settings.codeLength) B2aData B2aData(1)]; %#ok<AGROW>
        % Get a vector with the B2a pilot code sampled 1x/chip
        B2aPliot = generateB2aPilotCode(Ch(c_i).PRN,settings); % (always enabled)
        B2aPliot = [B2aPliot(settings.codeLength) B2aPliot B2aPliot(1)]; %#ok<AGROW>

        % --- Pilot Weil(100) subcode (1ms-per-chip) handling ---
        % generate NH code (+/-1) and align with acquisition-estimated Weil phase.
        weil100 = GenWeil(Ch(c_i).PRN); % length 100, +/-1
        if isfield(Ch(c_i),'polarityRef'),polarityRef = Ch(c_i).polarityRef; % +/-1
        else,polarityRef = 1;
        end

        %--- Perform various initializations ------------------------------
        codeFreq = codeFreqFromCarrierAid(settings, Ch(c_i).acquiredFreq, 0); % define initial (+carrier aid) code frequency basis of NCO
        remCodePhase  = 0.0;                % Define residual code phase (in chips)
        carrFreq      = Ch(c_i).acquiredFreq ; % Define carrier frequency which is used over whole tracking period
        carrFreqBasis = Ch(c_i).acquiredFreq ;
        remCarrPhase  = 0.0 + (polarityRef < 0) * pi; % Define residual carrier phase (apply acquisition polarity reference)
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
        nhsm = NH_stateMachine(settings,Ch(c_i).PRN);
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
                %     loopCnt*settings.intTime, c_i, TrkedNr, Ch(c_i).PRN,...
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
                    loopCnt*settings.intTime, c_i, TrkedNr, Ch(c_i).PRN,...
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
                if REACQbuff_pointer >= REACQbuff_size
                    % do acquisition (use v2fft; legacy acquisition_robust_v2 not required)
                    try
                        acqResults = acquisition_robust_v2fft(REACQbuff, settings, ...
                            'STA', 'SING', 'PRN', Ch(c_i).PRN, 'ISSILENT', true);
                    catch ME
                        warning('tracking2_v6_fix2:REACQ', ...
                            'REACQ acquisition failed for PRN %d: %s', Ch(c_i).PRN, ME.message);
                        acqResults = struct('carrFreq', NaN);
                    end
                    if isfield(acqResults, 'carrFreq') && any(isfinite(acqResults.carrFreq(:))) ...
                            && any(acqResults.carrFreq(:) ~= 0)
                        % --- Minimal-intrusion REACQ->tracking handover fix ---
                        % 1) Ensure preRun2 PRN mapping is correct in STA='SING'
                        tmpSettings = settings;
                        tmpSettings.numberOfChannels = 1;
                        tmpSettings.acqSatelliteList = Ch(c_i).PRN;
                        cur_channel = preRun2(acqResults, tmpSettings);
                        cur_channel = cur_channel(1);

                        % 2) Sync channel struct baseline with re-acquisition result
                        Ch(c_i).PRN          = cur_channel.PRN;
                        Ch(c_i).acquiredFreq = cur_channel.acquiredFreq;
                        Ch(c_i).codePhase    = cur_channel.codePhase;
                        Ch(c_i).codeFreq     = cur_channel.codeFreq;
                        Ch(c_i).status       = cur_channel.status;
                        Ch(c_i).weilPhase    = cur_channel.weilPhase;
                        Ch(c_i).polarityRef  = cur_channel.polarityRef;

                        % 3) Rewind file pointer to align stream to the detected code boundary
                        %    (avoid remCodePhase mismatch after REACQ)
                        % 3) Align file pointer to the detected code start within the *latest* 1ms.
                        % acquisition_robust_fix_tail returns codePhase within the tail 1ms (1..samplesIn1Ms).
                        st = round(cur_channel.codePhase);
                        st = max(1, min(st, Nin1ms));
                        rewindComplexSamples = Nin1ms - (st - 1);

                        % bytes per raw sample element
                        rewindBytes = - rewindComplexSamples * settings.size_per_sample;
                        pos0 = ftell(fid);
                        ret = fseek(fid, rewindBytes, 'cof');
                        pos1 = ftell(fid);
                        fprintf(['\tREACQ fseek ret=%d, pos %d -> %d,' ...
                            ' rewindSamples=%d\n'], ret, pos0, pos1, rewindComplexSamples);
                        if ret ~= 0
                            warning('REACQ fseek failed -> handover likely wrong.');
                        end
                        % 4) Reset loop states using the re-acquired baselines
                        codeFreq = codeFreqFromCarrierAid(settings, Ch(c_i).acquiredFreq, 0);
        remCodePhase  = 0.0;
                        carrFreq      = Ch(c_i).acquiredFreq;
                        carrFreqBasis = Ch(c_i).acquiredFreq;
                        remCarrPhase  = (Ch(c_i).polarityRef < 0) * pi;
                        oldCodeNco   = 0.0;
                        oldCodeError = 0.0;
                        d2CarrError  = 0.0;
                        dCarrError   = 0.0;
                        PsumPilot = 0 + 1i*0;
                        pdiCnt = 0;
                        lastCarrError = 0.0;
                        lastCarrNco = 0.0;
                        CNoValue = zeros(1,3);
                        tempCNoValue = -ones(1,3);
                        % new in fix 2
                        % reset scintillation warm-up age after successful
                        % REACQ handover, so S4-based adaptation will re-warm
                        scintTrackAge_ms = 0;
                        scintWarmReady = false;
                        latestScintResValid = false;
                        if ~isempty(scCal)
                            scCal.reset();
                        end
                        nhsm.NeedACQ = false;
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
                        ' the limit, Tracking of PRN %02d End...'],Ch(c_i).PRN)
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
                warning('Not able to read the specified number of samples for tracking, exiting!')
                fclose(fid);
                return
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
        targetPRN = Ch(c_i).PRN;
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
        finalTRes.PRN = Ch(c_i).PRN;
        finalTRes.status  = Ch(c_i).status;
        finalTRes.Nsize = codePeriods;
        %% Extract the time stamp for each measurement (best-effort)
        % Full TOW alignment requires valid B-CNAV2 preamble; short smoke
        % runs may not decode — leave Timestamp as NaN in that case.
        try
            [eph(finalTRes.PRN), subFrameStart(c_i), TOW(c_i)] = ...
                BCNAV2decoding(finalTRes.I_P);  %#ok<AGROW>
            if isfield(eph(finalTRes.PRN), 'SOW') && isfinite(eph(finalTRes.PRN).SOW) ...
                    && isfinite(subFrameStart(c_i))
                TOW_first_tracking_result = eph(finalTRes.PRN).SOW ...
                    - subFrameStart(c_i) * settings.intTime;
                tracking_result_time = TOW_first_tracking_result + settings.intTime : ...
                    settings.intTime : ...
                    (TOW_first_tracking_result + settings.msToProcess / 1000);
                nTs = min(numel(tracking_result_time), finalTRes.Nsize);
                finalTRes.Timestamp(1:nTs) = tracking_result_time(1:nTs);
            end
        catch ME
            warning('tracking2_v6_fix2:BCnavDecode', ...
                'PRN %d BCNAV2 decode/timestamp skipped: %s', Ch(c_i).PRN, ME.message);
        end
        % Post-estimate loop thermal noise (sigma_DLL in chips, sigma_PLL in degrees)
        try
            finalTRes.estimateLoopNoise(settings);
        catch ME
            warning('tracking2_v6_fix2:LoopNoise', ...
                'PRN %d estimateLoopNoise skipped: %s', Ch(c_i).PRN, ME.message);
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
            warning('tracking2_v6_fix2 final result of PRN %d failed', Ch(c_i).PRN);
        end

        % Collect into return array (channel index aligned with Ch / preRun2)
        % This restores the trackResults -> postNavigation pipeline.
        Tres(c_i) = finalTRes;
        fprintf('Channel %d PRN %02d tracking results collected into Tres(%d).\n', ...
            c_i, Ch(c_i).PRN, c_i);

    end % if a PRN is assigned
end % for channelNr


end % function 

% ===== Local helper: Costas phase discriminator (cycles), folded for BPSK =====
function e = costasPhaseErrCycles(P)
% Return phase error in cycles within [-0.25, 0.25] (half-cycle ambiguity for BPSK Costas).
if isempty(P) || ~isfinite(real(P)) || ~isfinite(imag(P)) || (real(P)==0 && imag(P)==0)
    e = 0;
    return;
end
e = atan2(imag(P), real(P)) / (2*pi);     % cycles in [-0.5, 0.5]
% Fold to half-cycle for BPSK (Costas): map to [-0.25, 0.25]
if e > 0.25
    e = e - 0.5;
elseif e < -0.25
    e = e + 0.5;
end
end

function [b, a] = designFLL2ndLPF(fc_Hz, zeta, fs_Hz)
% designFLL2ndLPF: 2nd-order low-pass biquad via Tustin
% H(s) = wn^2 / (s^2 + 2*zeta*wn*s + wn^2), wn=2*pi*fc
% y[n] = b0 x[n] + b1 x[n-1] + b2 x[n-2] - a1 y[n-1] - a2 y[n-2]

if nargin < 2 || isempty(zeta), zeta = 0.707; end
fc_Hz = max(fc_Hz, 0.01);
zeta  = max(zeta, 0.05);

T  = 1/fs_Hz;
wn = 2*pi*fc_Hz;
K  = 2/T;

A0 = K^2 + 2*zeta*wn*K + wn^2;
A1 = 2*(wn^2 - K^2);
A2 = K^2 - 2*zeta*wn*K + wn^2;

B0 = wn^2;
B1 = 2*wn^2;
B2 = wn^2;

b0 = B0 / A0;
b1 = B1 / A0;
b2 = B2 / A0;
a1 = A1 / A0;
a2 = A2 / A0;

b = [b0 b1 b2];
a = [1 a1 a2];
end

