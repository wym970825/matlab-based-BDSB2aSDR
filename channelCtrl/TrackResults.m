classdef TrackResults < handle
    % TrackResults - tracking results container class (BDS B2a)
    %
    % This class is a "class-version" of the original tracking2_v4 trackResults struct.
    % It keeps the same field names (as public properties) to be compatible with legacy
    % helper functions that use dot-indexing.
    %
    % Key additions for V5:
    %   - cur_state : logical vector (1ms), 1 when nhsm.STATE == 'LONG', else 0
    %   - sigma_DLL : DLL thermal jitter (chips), updated at CNoInterval epochs
    %   - sigma_PLL : PLL thermal jitter (degrees), updated at CNoInterval epochs
    %
    % Typical usage in tracking:
    %   tr = TrackResults.createArray(settings, settings.numberOfChannels);
    %   tr(ch).PRN = PRN;
    %   tr(ch).cur_state(k) = strcmpi(nhsm.STATE,'LONG');
    %   ...
    %   tr(ch).estimateLoopNoise(settings);

    properties
        % ---- Identification / status ----
        PRN double = 0
        status char = '-'

        % ---- 1ms (per loopCnt) fields ----
        absoluteSample double
        codeFreq double
        carrFreq double

        I_P double
        I_E double
        I_L double

        Q_E double
        Q_P double
        Q_L double

        Pilot_I_P double
        Pilot_Q_P double
        Pilot_I_E double
        Pilot_Q_E double
        Pilot_I_L double
        Pilot_Q_L double

        dllDiscr double
        dllDiscrFilt double
        pllDiscr double
        pllDiscrFilt double

        remCodePhase double
        remCarrPhase double

        Timestamp double

        % NEW: NH state record (1ms)
        cur_state logical

        % NEW: tracking state id (1ms)
        %  1=INIT(short PLL), 2=INIT_FLL(short FLL-aided PLL),
        %  3=LONG(long PLL), 4=LONG_FLL(long FLL-aided PLL),
        %  9=REACQ
        trk_state uint8

        % NEW: FLL discriminator & aiding (1ms)
        fllDiscrHz double
        fllDiscrFiltHz double
        fllCorrHz double
        fllAided logical

        % NEW: KF carrier filter logs (1ms)
        kf_phiRad double
        kf_omegaHz double
        kf_alphaHzps double
        kf_corrHz double
        

        % ---- CNoInterval fields ----
        DataCNo double
        DataPLD double
        PilotCNo double
        PilotPLD double
        B2a_CNo double

        % NEW: loop thermal noise (CNoInterval)
        sigma_DLL double
        sigma_PLL double
    end

    methods
        function obj = TrackResults(settings)
            if nargin < 1 || isempty(settings)
                return;
            end

            msToProcess = settings.msToProcess;

            if isfield(settings,'CNoInterval') && ~isempty(settings.CNoInterval)
                cnoInt = settings.CNoInterval;
            else
                cnoInt = 1;
            end
            nCNo = floor(msToProcess / cnoInt);

            % Preallocate (matching tracking2_v4 defaults as much as possible)
            obj.absoluteSample = nan(1, msToProcess);
            obj.codeFreq       = nan(1, msToProcess);
            obj.carrFreq       = nan(1, msToProcess);

            obj.I_P = nan(1, msToProcess);
            obj.I_E = nan(1, msToProcess);
            obj.I_L = nan(1, msToProcess);

            obj.Q_E = nan(1, msToProcess);
            obj.Q_P = nan(1, msToProcess);
            obj.Q_L = nan(1, msToProcess);

            obj.Pilot_I_P = nan(1, msToProcess);
            obj.Pilot_Q_P = nan(1, msToProcess);
            obj.Pilot_I_E = nan(1, msToProcess);
            obj.Pilot_Q_E = nan(1, msToProcess);
            obj.Pilot_I_L = nan(1, msToProcess);
            obj.Pilot_Q_L = nan(1, msToProcess);

            obj.dllDiscr     = inf(1, msToProcess);
            obj.dllDiscrFilt = inf(1, msToProcess);
            obj.pllDiscr     = inf(1, msToProcess);
            obj.pllDiscrFilt = inf(1, msToProcess);

            obj.remCodePhase = inf(1, msToProcess);
            obj.remCarrPhase = inf(1, msToProcess);

            obj.Timestamp    = nan(1, msToProcess);

            obj.cur_state    = false(1, msToProcess);

            obj.trk_state    = zeros(1, msToProcess, 'uint8');

            obj.fllDiscrHz      = nan(1, msToProcess);
            obj.fllDiscrFiltHz  = nan(1, msToProcess);
            obj.fllCorrHz       = nan(1, msToProcess);
            obj.fllAided        = false(1, msToProcess);

            obj.kf_phiRad       = nan(1, msToProcess);
            obj.kf_omegaHz      = nan(1, msToProcess);
            obj.kf_alphaHzps    = nan(1, msToProcess);
            obj.kf_corrHz       = nan(1, msToProcess);

            obj.DataCNo   = nan(1, nCNo);
            obj.DataPLD   = nan(1, nCNo);
            obj.PilotCNo  = nan(1, nCNo);
            obj.PilotPLD  = nan(1, nCNo);
            obj.B2a_CNo   = nan(1, nCNo);

            obj.sigma_DLL = nan(1, nCNo);
            obj.sigma_PLL = nan(1, nCNo);
        end

        function update(obj, loopCnt, varargin)
            % update - generic writer for per-ms values using name-value pairs.
            %
            % Example:
            %   tr.update(k,'I_P',I_P,'Q_P',Q_P,'codeFreq',codeFreq,'cur_state',true);
            %
            if nargin < 3
                return;
            end
            if mod(numel(varargin),2) ~= 0
                error('TrackResults:update','Name-value pairs required.');
            end

            for i = 1:2:numel(varargin)
                name = varargin{i};
                value = varargin{i+1};

                if ~(ischar(name) || isstring(name))
                    error('TrackResults:update','Property name must be char/string.');
                end
                pname = char(name);

                if ~isprop(obj, pname)
                    warning('TrackResults:update:UnknownProp','Unknown property "%s" ignored.', pname);
                    continue;
                end

                propVal = obj.(pname);

                if (isnumeric(propVal) || islogical(propVal)) && isvector(propVal) && numel(propVal) >= loopCnt
                    obj.(pname)(loopCnt) = value;
                else
                    obj.(pname) = value;
                end
            end
        end

        function s = toStruct(obj)
            % toStruct - convert object(s) to struct array for legacy compatibility.
            if numel(obj) > 1
                s = arrayfun(@(x) x.toStruct(), obj);
                return;
            end
            p = properties(obj);
            s = struct();
            for i = 1:numel(p)
                s.(p{i}) = obj.(p{i});
            end
        end

        function [sigmaDLL, sigmaPLL] = estimateLoopNoise(obj, settings)
            % estimateLoopNoise - estimate DLL/PLL thermal noise (CNoInterval rate).
            %
            % DLL thermal noise:
            %   estimateDllSigmma(D, B_fe, T_code, T_coh, B_l, CN0_lin)
            % mapping:
            %   D      <- settings.dllCorrelatorSpacing
            %   B_fe   <- settings.IFBandwidth (fallback to settings.samplingFreq/2)
            %   T_code <- 1/settings.codeFreqBasis
            %   T_coh  <- (LONG) settings.longCoh_m*1e-3 or settings.longCoh_ms*1e-3, else 1e-3
            %   B_l    <- settings.dllNoiseBandwidth
            %   CN0    <- 10^(trackResults.B2a_CNo/10)  (B2a_CNo stored as dB-Hz)
            %
            % PLL thermal noise:
            %   sigma_t_PLL = 180/pi * sqrt( (B_L/CN0) * (1 + 1/(2*T_coh*CN0)) )
            % where B_L is selected with the user's backtracking rule.
            %
            if nargin < 2 || isempty(settings)
                error('TrackResults:estimateLoopNoise','settings required.');
            end

            % CNo interval
            if isfield(settings,'CNoInterval') && ~isempty(settings.CNoInterval)
                cnoInt = settings.CNoInterval;
            else
                cnoInt = 1;
            end

            nCNo = numel(obj.B2a_CNo);
            sigmaDLL = nan(1, nCNo);
            sigmaPLL = nan(1, nCNo);

            % Map 1ms state -> CNo state (sample at k*CNoInterval)
            curStateCNo = false(1, nCNo);
            for k = 1:nCNo
                msIdx = min(k * cnoInt, numel(obj.cur_state));
                curStateCNo(k) = logical(obj.cur_state(msIdx));
            end

            % DLL constants from settings (with safe fallbacks)
            if isfield(settings,'dllCorrelatorSpacing') && ~isempty(settings.dllCorrelatorSpacing)
                D = settings.dllCorrelatorSpacing;
            else
                D = 0.5;
            end

            if isfield(settings,'IFBandwidth') && ~isempty(settings.IFBandwidth)
                B_fe = settings.IFBandwidth;
            elseif isfield(settings,'samplingFreq') && ~isempty(settings.samplingFreq)
                B_fe = settings.samplingFreq/2;
            else
                B_fe = 10e6;
            end

            if isfield(settings,'codeFreqBasis') && ~isempty(settings.codeFreqBasis)
                T_code = 1/settings.codeFreqBasis;
            else
                T_code = 1/10.23e6;
            end

            if isfield(settings,'dllNoiseBandwidth') && ~isempty(settings.dllNoiseBandwidth)
                B_l_dll = settings.dllNoiseBandwidth;
            else
                B_l_dll = 2;
            end

            % PLL bandwidths (pull/stab)
            if isfield(settings,'pllNoiseBandwidth_pull') && ~isempty(settings.pllNoiseBandwidth_pull)
                B_l_pull = settings.pllNoiseBandwidth_pull;
            elseif isfield(settings,'pllNoiseBandwidth') && ~isempty(settings.pllNoiseBandwidth)
                B_l_pull = settings.pllNoiseBandwidth;
            else
                B_l_pull = 25;
            end

            if isfield(settings,'pllNoiseBandwidth_stab') && ~isempty(settings.pllNoiseBandwidth_stab)
                B_l_stab = settings.pllNoiseBandwidth_stab;
            elseif isfield(settings,'pllNoiseBandwidth') && ~isempty(settings.pllNoiseBandwidth)
                B_l_stab = settings.pllNoiseBandwidth;
            else
                B_l_stab = 15;
            end

            if isfield(settings,'filter_pullinMS') && ~isempty(settings.filter_pullinMS)
                pullinMS = settings.filter_pullinMS;
            else
                pullinMS = 50;
            end
            pullinK_th = pullinMS / cnoInt; % user spec: compare with K directly

            % coherent time
            longCoh_ms = [];
            if isfield(settings,'longCoh_m') && ~isempty(settings.longCoh_m)
                longCoh_ms = settings.longCoh_m;
            elseif isfield(settings,'longCoh_ms') && ~isempty(settings.longCoh_ms)
                longCoh_ms = settings.longCoh_ms;
            else
                longCoh_ms = 20;
            end
            Tcoh_long = longCoh_ms * 1e-3;
            Tcoh_init = 1e-3;

            CN0_dB = obj.B2a_CNo(:).';

            for k = 1:nCNo
                if ~isfinite(CN0_dB(k)) || (CN0_dB(k) <= 0) || (CN0_dB(k) == -1)
                    continue;
                end

                CN0_lin = 10.^(CN0_dB(k)/10); % Hz

                if curStateCNo(k)
                    T_coh = Tcoh_long;
                else
                    T_coh = Tcoh_init;
                end

                % DLL sigma (chips)
                try
                    sigmaDLL(k) = estimateDllSigmma(D, B_fe, T_code, T_coh, B_l_dll, CN0_lin);
                catch ME
                    warning('TrackResults:estimateLoopNoise:DllFail','estimateDllSigmma failed at k=%d: %s', k, ME.message);
                    sigmaDLL(k) = nan;
                end

                % PLL bandwidth selection rule (per user requirement)
                if curStateCNo(k)
                    B_l_pll = B_l_stab;
                else
                    % K: consecutive non-LONG epochs ending at k with valid CN0 (exclude -1)
                    K = 0;
                    kk = k;
                    while kk >= 1
                        if curStateCNo(kk)
                            break;
                        end
                        if ~isfinite(CN0_dB(kk)) || (CN0_dB(kk) <= 0) || (CN0_dB(kk) == -1)
                            break;
                        end
                        K = K + 1;
                        kk = kk - 1;
                    end

                    if K >= pullinK_th
                        B_l_pll = B_l_pull;
                    else
                        B_l_pll = B_l_stab;
                    end
                end

                sigmaPLL(k) = (180/pi) * sqrt( (B_l_pll ./ CN0_lin) .* (1 + 1 ./ (2 .* T_coh .* CN0_lin)) );
            end

            obj.sigma_DLL = sigmaDLL;
            obj.sigma_PLL = sigmaPLL;
        end

        function [phaseCycles, dopplerHz] = deriveCarrierPhase(obj, settings)
            % deriveCarrierPhase - derive carrier phase observable in cycles and Doppler in Hz.
            % The phase is formed from remCarrPhase accumulation (unwrap), with IF removed,
            % and sign chosen so that DopplerHz = -d(phaseCycles)/dt (RINEX convention).
            if nargin < 2 || isempty(settings)
                error('TrackResults:deriveCarrierPhase','settings required.');
            end

            N = numel(obj.remCarrPhase);
            phaseCycles = nan(1,N);
            dopplerHz = nan(1,N);

            if isfield(settings,'intTime') && ~isempty(settings.intTime)
                dt = settings.intTime;
            else
                dt = 1e-3;
            end

            if isfield(settings,'IF') && ~isempty(settings.IF)
                IF = settings.IF;
            else
                IF = 0;
            end

            % Doppler (Hz) = estimated carrier freq - IF
            cf = obj.carrFreq;
            dopplerHz = cf - IF;
            dopplerHz(~isfinite(dopplerHz)) = nan;

            t = (0:N-1) .* dt;

            phi = obj.remCarrPhase;
            phi(~isfinite(phi)) = nan;

            finiteMask = isfinite(phi);
            if ~any(finiteMask)
                return;
            end
            idx = find(finiteMask);

            runStart = 1;
            while runStart <= numel(idx)
                runEnd = runStart;
                while runEnd < numel(idx) && idx(runEnd+1) == idx(runEnd)+1
                    runEnd = runEnd + 1;
                end
                runIdx = idx(runStart:runEnd);
                phiRun = phi(runIdx);
                phiUnw = unwrap(phiRun);

                phaseCycles(runIdx) = -(phiUnw./(2*pi) - IF .* t(runIdx));
                runStart = runEnd + 1;
            end
        end

        function writeRinex304(objArray, outFile, settings, startDateTime, varargin)
            % writeRinex304 - write single-frequency (BDS B2a) RINEX 3.04 observation file.
            %
            % Default obs types: C5X L5X D5X S5X
            %
            % Required:
            %   outFile       - output filename (char/string)
            %   settings      - receiver settings (needs intTime, IF, CNoInterval)
            %   startDateTime - datetime, receiver time of the FIRST tracking result (epoch #1)
            %
            % Optional:
            %   'IntervalMS'   - output interval in ms (default settings.CNoInterval)
            %   'TimeSystem'   - 'BDT' (default) or 'GPST' (used to compute SOW)
            %   'SignalFreqHz' - default 1176.45e6 (B2a)
            %
            if nargin < 4
                error('TrackResults:writeRinex304','Need outFile, settings, startDateTime.');
            end
            if isstring(outFile), outFile = char(outFile); end
            if ischar(startDateTime) || isstring(startDateTime)
                startDateTime = datetime(startDateTime);
            end
            if ~isdatetime(startDateTime)
                error('TrackResults:writeRinex304','startDateTime must be datetime (or convertible).');
            end

            % Defaults
            if isfield(settings,'CNoInterval') && ~isempty(settings.CNoInterval)
                intervalMS = settings.CNoInterval;
            else
                intervalMS = 1000;
            end
            timeSystem = 'BDT';
            fSignal = 1176.45e6;

            % Parse varargin
            if ~isempty(varargin)
                for i = 1:2:numel(varargin)
                    key = varargin{i};
                    val = varargin{i+1};
                    if isstring(key), key = char(key); end
                    switch lower(key)
                        case 'intervalms'
                            intervalMS = val;
                        case 'timesystem'
                            timeSystem = upper(char(string(val)));
                        case 'signalfreqhz'
                            fSignal = val;
                        otherwise
                            warning('TrackResults:writeRinex304:UnknownParam','Unknown parameter "%s".', key);
                    end
                end
            end

            if isfield(settings,'intTime') && ~isempty(settings.intTime)
                dt = settings.intTime;
            else
                dt = 1e-3;
            end

            % Epoch indices
            msLens = arrayfun(@(x) numel(x.I_P), objArray);
            Nms = min(msLens);
            step = max(1, round((intervalMS*1e-3)/dt));
            epochIdx = 1:step:Nms;

            % Constants
            c = 299792458;
            lambda = c / fSignal;

            % SOW0 from startDateTime
            [~, rxSOW0] = TrackResults.datetime2weekSOW(startDateTime, timeSystem);

            % Open file
            fid = fopen(outFile, 'w');
            if fid < 0
                error('TrackResults:writeRinex304','Cannot open file: %s', outFile);
            end
            cleaner = onCleanup(@() fclose(fid)); %#ok<NASGU>

            % Header (minimal)
            fprintf(fid, '%-60s%-20s\n', '     3.04           OBSERVATION DATA    C                   ', 'RINEX VERSION / TYPE');
            fprintf(fid, '%-20s%-20s%-20s%-20s\n', 'TrackResults', 'MATLAB', datestr(now,'yyyymmdd HHMMSS'), 'PGM / RUN BY / DATE');
            fprintf(fid, '%-60s%-20s\n', 'BDS B2a single-frequency from TrackResults', 'COMMENT');
            fprintf(fid, '%-60s%-20s\n', 'UNKNOWN', 'MARKER NAME');

            obsTypes = {'C5X','L5X','D5X','S5X'};
            fprintf(fid, 'C%5d', numel(obsTypes));
            for i = 1:numel(obsTypes)
                fprintf(fid, ' %3s', obsTypes{i});
            end
            fprintf(fid, '%*s%-20s\n', 60-(1+5+4*numel(obsTypes)), '', 'SYS / # / OBS TYPES');

            fprintf(fid, '%6d%6d%6d%6d%6d%13.7f %-3s %-20s\n', ...
                year(startDateTime), month(startDateTime), day(startDateTime), ...
                hour(startDateTime), minute(startDateTime), second(startDateTime), ...
                timeSystem, 'TIME OF FIRST OBS');

            fprintf(fid, '%10.3f%-50s%-20s\n', intervalMS*1e-3, '', 'INTERVAL');
            fprintf(fid, '%-60s%-20s\n', '', 'END OF HEADER');

            % Precompute carrier observables and per-sat phase alignment flags
            nSat = numel(objArray);
            phAll = cell(1,nSat);
            dopAll = cell(1,nSat);
            aligned = false(1,nSat);
            for s = 1:nSat
                [ph, dop] = objArray(s).deriveCarrierPhase(settings);
                phAll{s} = ph;
                dopAll{s} = dop;
            end

            % Body
            for e = 1:numel(epochIdx)
                k = epochIdx(e);
                epochTime = startDateTime + seconds((k-1)*dt);

                % select sats
                satList = [];
                for s = 1:nSat
                    if isempty(objArray(s).PRN) || objArray(s).PRN == 0
                        continue;
                    end
                    if objArray(s).status ~= 'T'
                        continue;
                    end
                    if k > numel(objArray(s).carrFreq) || ~isfinite(objArray(s).carrFreq(k))
                        continue;
                    end
                    satList(end+1) = s; %#ok<AGROW>
                end
                ns = numel(satList);
                if ns == 0
                    continue;
                end

                fprintf(fid, '> %4d %2d %2d %2d %2d %11.7f  0%3d\n', ...
                    year(epochTime), month(epochTime), day(epochTime), ...
                    hour(epochTime), minute(epochTime), second(epochTime), ns);

                rxSOW = rxSOW0 + (k-1)*dt;

                for ii = 1:ns
                    s = satList(ii);
                    prn = objArray(s).PRN;
                    satStr = sprintf('C%02d', prn);

                    % CNo mapping
                    cnoIdx = 1;
                    if isfield(settings,'CNoInterval') && ~isempty(settings.CNoInterval)
                        cnoIdx = floor((k-1)/settings.CNoInterval) + 1;
                        cnoIdx = min(cnoIdx, numel(objArray(s).B2a_CNo));
                    end
                    S = objArray(s).B2a_CNo(cnoIdx);
                    if ~isfinite(S) || S <= 0
                        S = nan;
                    end

                    % Doppler & phase
                    D = dopAll{s}(k);
                    L = phAll{s}(k);

                    % Pseudorange (if Timestamp available)
                    Cobs = nan;
                    if ~isempty(objArray(s).Timestamp) && numel(objArray(s).Timestamp) >= k && isfinite(objArray(s).Timestamp(k))
                        txSOW = objArray(s).Timestamp(k);
                        dtS = rxSOW - txSOW;
                        dtS = dtS - round(dtS/604800)*604800;
                        Cobs = dtS * c;

                        if ~aligned(s) && isfinite(Cobs) && isfinite(L)
                            phOffset = (Cobs/lambda) - L;
                            phAll{s} = phAll{s} + phOffset;
                            aligned(s) = true;
                            L = phAll{s}(k);
                        end
                    end

                    % Write observation line
                    fprintf(fid, '%-3s', satStr);
                    fprintf(fid, '%s', TrackResults.rnxField(Cobs));
                    fprintf(fid, '%s', TrackResults.rnxField(L));
                    fprintf(fid, '%s', TrackResults.rnxField(D));
                    fprintf(fid, '%s', TrackResults.rnxField(S));
                    fprintf(fid, '\n');
                end
            end
        end
    end

    methods (Static)
        function arr = createArray(settings, nChan)
            % createArray - create an array of independent TrackResults objects.
            if nargin < 2 || isempty(nChan)
                nChan = 1;
            end
            arr(1,nChan) = TrackResults(settings); %#ok<AGROW>
            for k = 1:nChan
                arr(k) = TrackResults(settings);
            end
        end

        function fld = rnxField(val)
            % rnxField - 16-char observation field (F14.3 + 2 blanks)
            if isempty(val) || ~isfinite(val)
                fld = repmat(' ', 1, 16);
            else
                fld = sprintf('%14.3f  ', val);
            end
        end

        function [week, sow] = datetime2weekSOW(dt, timeSystem)
            % datetime2weekSOW - convert datetime to (week, seconds-of-week).
            % Assumes dt is already in the specified time system scale.
            if nargin < 2 || isempty(timeSystem)
                timeSystem = 'BDT';
            end
            timeSystem = upper(string(timeSystem));
            if timeSystem == "GPST"
                t0 = datetime(1980,1,6,0,0,0,'TimeZone','UTC');
            else
                % BDT epoch (commonly used): 2006-01-01 00:00:00
                t0 = datetime(2006,1,1,0,0,0,'TimeZone','UTC');
            end

            if isempty(dt.TimeZone)
                dt.TimeZone = 'UTC';
            end
            dt.TimeZone = 'UTC';

            dtsec = seconds(dt - t0);
            week = floor(dtsec / 604800);
            sow  = dtsec - week*604800;
        end
    end
end
