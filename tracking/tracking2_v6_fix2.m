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
% Calculate filter coefficient values
[tau1code, tau2code] = calcLoopCoef(settings.dllNoiseBandwidth, ...
    settings.dllDampingRatio, ...
    1.0);

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
        codeFreq      = Ch(c_i).codeFreq;   % define initial code frequency basis of NCO
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
        % power scale
        % + k + gain - 10*log10(fs);
        PwrK = settings.usrp.scaleK + settings.usrp.gain - 10*log10(settings.samplingFreq);
        %=== Process the number of specified code periods =================
        for loopCnt =  1 : codePeriods
            
            % Record NH state (update from v5(3 state) to v6 (5-state))
            % Record tracking state at current 1ms tick
            TRii = rem(loopCnt-1, trkBuf.Nsize)+1; 
            isLongState = strncmpi(nhsm.STATE,'LONG',4); % LONG or LONG_FLL
            % record state from state machine
            % try method update(obj, loopCnt, varargin)
            trkBuf.update(TRii, 'cur_state', isLongState, 'trk_state', nhsm.getStateId(),...
                'fllAided', (strcmpi(nhsm.STATE,'INIT_FLL') ||...
                strcmpi(nhsm.STATE,'LONG_FLL') || forceInitAiding));
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
                    CNoCnt = TRii/settings.CNoInterval;
                    trkBuf.update(CNoCnt,'DataCNo',-1,'DataPLD',-1,...
                        'PilotCNo',-1,'PilotPLD',-1,'B2a_CNo',-1);
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
                    % do acquisition
                    acqResults = acquisition_robust_v2(REACQbuff, settings,...
                        'STA', 'sing', 'PRN', Ch(c_i).PRN);
                    if any(isfinite(acqResults.carrFreq))
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
                        codeFreq      = Ch(c_i).codeFreq;
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
            % Record sample number (based on 8bit samples) 
            % this index start from 0
            trkBuf.update(TRii,'absoluteSample', (ftell(fid))/settings.size_per_sample);
            % Update the phasestep based on code freq (variable) and
            % sampling frequency (fixed)
            % Identifies how much symbol time a sampling point occupies:
            codePhaseStep = codeFreq/settings.samplingFreq;
            % Find the size of a "block" or code period in whole samples
            blksize = ceil((settings.codeLength-remCodePhase) / codePhaseStep);
            % Read in the appropriate number of samples to process this
            % interation
            [rawSignal, samplesRead] = fread(fid, ...
                dataAdaptCoeff*blksize, settings.dataType);
            rawSignal = rawSignal.';
            % For IQ data, the real and imaginary parts of the
            % data are interleaved.Therefore, it is necessary
            % to split the data read directly in the program
            if (dataAdaptCoeff==2)
                rawSignalIdat=rawSignal(1:2:end);
                rawSignalQdat=rawSignal(2:2:end);
                rawSignal = rawSignalIdat + 1j * rawSignalQdat;
            end
            % If did not read in enough samples, then could be out of
            % data - better exit
            if (samplesRead ~= dataAdaptCoeff*blksize)
                warning('Not able to read the specified number of samples for tracking, exiting!')
                fclose(fid);
                return
            end
            if settings.EnablePB
                rawSignal = pb.mitigate(rawSignalIdat+1j*rawSignalQdat);
                Ppre = pb.Ppre + PwrK;
                Ppost = pb.Ppost + PwrK;
                eta = pb.PDC;
                trkBuf.update(TRii, 'Ppre', Ppre, 'Ppost', Ppost, 'eta', eta);
            end
            %-------------------------------------------------------------%
            % PLL Loop Filter Setting from state-machine
            pf = nhsm.pf;

            %% Set up all the code phase tracking information
            % Save remCodePhase for current correlation
            
            
            % Define index into early code vector
            tcode       = (remCodePhase-el_Spc) : codePhaseStep : ...
                ((blksize-1)*codePhaseStep+remCodePhase-el_Spc);
            tcode2      = ceil(tcode) + 1;
            earlyCode   = B2aData(tcode2);
            % For pilot channel signal tracking (always enabled)
            earlyCodeQ = B2aPliot(tcode2);
            % Define index into late code vector
            tcode       = (remCodePhase+el_Spc) : ...
                codePhaseStep : ...
                ((blksize-1)*codePhaseStep+remCodePhase+el_Spc);
            tcode2      = ceil(tcode) + 1;
            lateCode    = B2aData(tcode2);
            % For pilot channel signal tracking (always enabled)
            lateCodeQ = B2aPliot(tcode2);
            % Define index into prompt code vector
            tcode       = remCodePhase : ...
                codePhaseStep : ...
                ((blksize-1)*codePhaseStep+remCodePhase);
            tcode2      = ceil(tcode) + 1;
            promptCode  = B2aData(tcode2);
            % Apply known B2a data subcode (5ms period) per-ms sign to stabilize data prompt
            % dataNh = dataNH5(mod(loopCnt-1, 5) + 1);
            % earlyCode  = dataNh * earlyCode;
            % promptCode = dataNh * promptCode;
            % lateCode   = dataNh * lateCode;
            % For pilot channel signal tracking (always enabled)
            promptCodeQ = B2aPliot(tcode2);

            % Apply Weil(100) NH chip for this 1ms (remove subcode on pilot)
            if strncmpi(nhsm.STATE,'LONG',4)
                weilIdx = mod(nhsm.NH_estimator.WeilPhase +...
                    (loopCnt-nhsm.NH_estimator.Anchor),100);
                nh = weil100(weilIdx+1);
            else
                nh = 1;
            end
            earlyCodeQ  = nh * earlyCodeQ;
            promptCodeQ = nh * promptCodeQ;
            lateCodeQ   = nh * lateCodeQ;
            trkBuf.update(TRii, 'remCodePhase', remCodePhase, 'remCarrPhase', remCarrPhase);
            remCodePhase = tcode(blksize)+codePhaseStep-settings.codeLength;
            %% Generate the carrier frequency to mix the signal to baseband -----------
            % Save remCarrPhase for current correlation
            % Get the argument to sin/cos functions
            timetick    = (0:blksize) ./ settings.samplingFreq;
            trigarg = ((carrFreq * 2*pi) .* timetick) + remCarrPhase;
            remCarrPhase = rem(trigarg(blksize+1), (2*pi));

            % Finally compute the signal to mix the collected data to
            % bandband
            % carrsig = exp(1j*trigarg(1:blksize));
            % complexLocalSig = cos(...) + 1j*sin(...)
            if (dataAdaptCoeff==2)
                carrsig = exp(1i * trigarg(1:blksize));
            end
            %% Generate the six standard accumulated values ---------------------------
            % First mix to baseband
            baseBandSignal = rawSignal .* carrsig;
            qBasebandSignal = real(baseBandSignal);
            iBasebandSignal = imag(baseBandSignal);

            % Now get early, late, and prompt values for each
            I_E = sum(earlyCode  .* iBasebandSignal);
            Q_E = sum(earlyCode  .* qBasebandSignal);
            I_P = sum(promptCode .* iBasebandSignal);
            Q_P = sum(promptCode .* qBasebandSignal);
            I_L = sum(lateCode   .* iBasebandSignal);
            Q_L = sum(lateCode   .* qBasebandSignal);

            % For pilot channel signal tracking (always enabled)
            pilot_I_E = sum(earlyCodeQ  .* iBasebandSignal);
            pilot_Q_E = sum(earlyCodeQ  .* qBasebandSignal);
            pilot_I_P = sum(promptCodeQ .* iBasebandSignal);
            pilot_Q_P = sum(promptCodeQ .* qBasebandSignal);
            pilot_I_L = sum(lateCodeQ   .* iBasebandSignal);
            pilot_Q_L = sum(lateCodeQ   .* qBasebandSignal);

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
                CNoCnt = TRii/settings.CNoInterval;
                if ~mod(TRii,settings.CNoInterval)
                trkBuf.update(CNoCnt, 'S4_ori',S4result.S4_ori,...
                    'S4_corr',S4result.S4_corr,...
                    'S4',S4);
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
            trkBuf.update(TRii, 'fllDiscrHz', fllErrHz, 'fllDiscrFiltHz', fllErrHz_filt);

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
                % Save carrier frequency for current correlation (hold within PDI)
                trkBuf.update(TRii, 'carrFreq', carrFreq);
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

                trkBuf.update(TRii, 'carrFreq', carrFreq);
                % reset coherent accumulator
                PsumPilot = 0 + 1i*0;
                pdiCnt = 0;
            end

            % Record discriminators (held constant between PLL updates)
            trkBuf.update(TRii, 'pllDiscr', lastCarrError, 'pllDiscrFilt', lastCarrNco);

            %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
            %% Find DLL error and update code NCO -------------------------
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
            %% Record various measures to show in postprocessing ----------------------
            trkBuf.update(TRii, 'codeFreq', codeFreq, 'dllDiscr', codeError, 'dllDiscrFilt', codeNco,...
                'I_E',I_E, 'I_P',I_P, 'I_L',I_L, 'Q_E',Q_E, 'Q_P',Q_P, 'Q_L',Q_L,...
                'Pilot_I_E',pilot_I_E, 'Pilot_I_P',pilot_I_P, 'Pilot_I_L',pilot_I_L,...
                'Pilot_Q_E',pilot_Q_E, 'Pilot_Q_P',pilot_Q_P, 'Pilot_Q_L',pilot_Q_L);

            % Modify code freq based on NCO command
            codeFreq = Ch(c_i).codeFreq - codeNco;

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
                CNoCnt = TRii/settings.CNoInterval;
                % Save C/No for data channel: a o.5-0.5 filter is used.
                % Save PLL lock detector output for data channel
                averageCNo = CNoValue/2 + tempCNoValue/2;
                trkBuf.update(CNoCnt,'DataCNo',averageCNo(1),'DataPLD',PllDetector(1),...
                        'PilotCNo',averageCNo(2),'PilotPLD',PllDetector(2),'B2a_CNo',averageCNo(3));

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

                % log KF states (phi[rad], omega[Hz], alpha[Hz/s])
                trkBuf.update(TRii, 'kf_phiRad',kf.x(1),'kf_omegaHz',kf.x(2)/(2*pi),...
                    'kf_alphaHzps',kf.x(3)/(2*pi),'kf_corrHz',0);
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
                trkBuf.update(TRii,'kf_corrHz',deltaHz,'kf_nisPhi',kfm.NIS_phi,'kf_nisOmega',kfm.NIS_omega,...
                    'kf_rmsNuPhiRad',kfm.RMS_nu_phi_rad,'kf_rmsNuOmegaHz',kfm.RMS_nu_omega_rads/(2*pi));

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
            trkBuf.update(TRii, 'fllCorrHz', fllCorrHz);
            % reset KF phase-meas flag for next tick
            kf_phiMeasValid = false;
            % save and clear buffer when it is full
            if rem(loopCnt,trkBuf.Nsize) == 0
                succeed = trkBuf.save();
                if ~succeed
                    warning('Tracking Result didnot saved.');
                end
            end

        end % for loopCnt
        if rem(loopCnt,trkBuf.Nsize) >= 0
            succeed = trkBuf.partsave(settings, TRii);
            if ~succeed
                warning('Tracking Result didnot saved.');
            end
        end

        %% Gather all tempory TR into 1 variable and save
        targetPRN = Ch(c_i).PRN;
        FileNum = ceil(codePeriods/trkBuf.Nsize);
        % Ultimate track result
        finalTRes = TrackResults2(settings, codePeriods);
        I_start = 1;
        for file_ii = 1:FileNum
            TRfileName = sprintf('Trk_Prn_%02d_%03d.mat', targetPRN, file_ii);
            TRfileName = fullfile(settings.tempdataSvPth,TRfileName);
            if exist(TRfileName,"file")
                tmpTrk = load(TRfileName);
                tmpTrk = tmpTrk.obj;
                succeed = finalTRes.copyFROM(tmpTrk,I_start);
                I_start = tmpTrk.Nsize + I_start;
                if succeed>=1
                    disp(TRfileName);
                end
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

