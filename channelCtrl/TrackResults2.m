classdef TrackResults2 < handle
% TrackResults2 - tracking results container class (BDS B2a)
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
%   tr = TrackResults2.createArray(settings, settings.numberOfChannels);
%   tr(ch).PRN = PRN;
%   tr(ch).cur_state(k) = strcmpi(nhsm.STATE,'LONG');
%   ...
%   tr(ch).estimateLoopNoise(settings);
% ======================================================================= %
% Version Track from v2.0.2
%   2.0.2
% --------------------------------------------------%
% (1) New interface added for S4 calculation
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
        % NEW: KF consistency metrics (1ms)
        kf_nisPhi double
        kf_nisOmega double
        kf_rmsNuPhiRad double
        kf_rmsNuOmegaHz double


        % ---- CNoInterval fields ----
        DataCNo double
        DataPLD double
        PilotCNo double
        PilotPLD double
        B2a_CNo double

        % Version 2.0.1
        % NEW: loop thermal noise (CNoInterval)
        sigma_DLL double
        sigma_PLL double

        % Version 2.0.2
        % NEW: scintillation records (CNoInterval)
        % Reserved for future integration with scint_calculator.m.
        % Keep these fields in the result container first, even if the
        % current tracking loop does not populate them yet.
        S4_ori double
        S4_corr double
        S4 double

        % Version 2.0.3
        % NEW: Pulse blanker log
        Ppre double % Power before pulse blanker(input) [dBm]
        Ppost double % Power after pulse blanker(output) [dBm]
        eta double % pulse blanker duty cycle [demensionless]

        % New: auto save
        Nsize double % Size of TR

    end
    properties (Access = private)
        % New: auto save
        Svtimes double
        SvPth string
    end

    methods
        function obj = TrackResults2(settings, varargin)
            % input check
            if nargin < 1 || isempty(settings)
                return;
            elseif  nargin == 2
                enForceSize = true;
                ForceSize = varargin{1};
            else % settings is the only input
                enForceSize = false;
                ForceSize = 6e4;
            end

            msToProcess = settings.msToProcess;

            % auto save and Tres size control
            % has a maximum size of 60[s] = 6e4ms
            if ~enForceSize
                Nsize = min(msToProcess, 6e4);
            else
                Nsize = ForceSize;
            end
            % track result savepath [tempdataSvPth]
            if isfield(settings,'tempdataSvPth')
                if ~isempty(settings.tempdataSvPth)
                    obj.SvPth = settings.tempdataSvPth;
                else
                    try
                        mkdir(settings.tempdataSvPth)
                        obj.SvPth = settings.tempdataSvPth;
                    catch
                        error('The field ''tempdataSvPth'' is not a direction')
                    end
                end
            else
                error(['The field ''tempdataSvPth'' for saving' ...
                    ' the file path is essential.'])
            end

            cnoInt = 1e3;
            if isfield(settings,'CNoInterval')
                if ~isempty(settings.CNoInterval)
                    cnoInt = settings.CNoInterval;
                end
            end

            nCNo = floor(Nsize / cnoInt);

            % Preallocate (matching tracking2_v4 defaults as much as possible)
            obj.absoluteSample = nan(1, Nsize);
            obj.codeFreq       = nan(1, Nsize);
            obj.carrFreq       = nan(1, Nsize);

            obj.I_P = nan(1, Nsize);
            obj.I_E = nan(1, Nsize);
            obj.I_L = nan(1, Nsize);

            obj.Q_E = nan(1, Nsize);
            obj.Q_P = nan(1, Nsize);
            obj.Q_L = nan(1, Nsize);

            obj.Pilot_I_P = nan(1, Nsize);
            obj.Pilot_Q_P = nan(1, Nsize);
            obj.Pilot_I_E = nan(1, Nsize);
            obj.Pilot_Q_E = nan(1, Nsize);
            obj.Pilot_I_L = nan(1, Nsize);
            obj.Pilot_Q_L = nan(1, Nsize);

            obj.dllDiscr     = inf(1, Nsize);
            obj.dllDiscrFilt = inf(1, Nsize);
            obj.pllDiscr     = inf(1, Nsize);
            obj.pllDiscrFilt = inf(1, Nsize);

            obj.remCodePhase = inf(1, Nsize);
            obj.remCarrPhase = inf(1, Nsize);

            obj.Timestamp    = nan(1, Nsize);

            obj.cur_state    = false(1, Nsize);

            obj.trk_state    = zeros(1, Nsize, 'uint8');

            obj.fllDiscrHz      = nan(1, Nsize);
            obj.fllDiscrFiltHz  = nan(1, Nsize);
            obj.fllCorrHz       = nan(1, Nsize);
            obj.fllAided        = false(1, Nsize);

            obj.kf_phiRad       = nan(1, Nsize);
            obj.kf_omegaHz      = nan(1, Nsize);
            obj.kf_alphaHzps    = nan(1, Nsize);
            obj.kf_corrHz       = nan(1, Nsize);

            obj.kf_nisPhi       = nan(1, Nsize);
            obj.kf_nisOmega     = nan(1, Nsize);
            obj.kf_rmsNuPhiRad  = nan(1, Nsize);
            obj.kf_rmsNuOmegaHz = nan(1, Nsize);

            obj.Ppre  = nan(1,Nsize);
            obj.Ppost = nan(1,Nsize);
            obj.eta   = nan(1,Nsize);


            obj.DataCNo   = nan(1, nCNo);
            obj.DataPLD   = nan(1, nCNo);
            obj.PilotCNo  = nan(1, nCNo);
            obj.PilotPLD  = nan(1, nCNo);
            obj.B2a_CNo   = nan(1, nCNo);

            obj.sigma_DLL = nan(1, nCNo);
            obj.sigma_PLL = nan(1, nCNo);

            % Version 2.0.2
            % NEW: scintillation records (CNoInterval)
            % Pre-allocate scintillation logging fields (CNoInterval-level).
            % These remain NaN until tracking2_v6_fix1 actively pushes
            % scint_calculator outputs into TrackResults2.
            obj.S4_ori   = nan(1, nCNo);
            obj.S4_corr  = nan(1, nCNo);
            obj.S4       = nan(1, nCNo);

            % for auto save
            obj.Nsize = Nsize;
            obj.Svtimes = 0;
        end

        function update(obj, loopCnt, varargin)
            % update - generic writer for per-ms values using name-value pairs.
            %
            % Example:
            %   tr.update(k,'I_P',I_P,'Q_P',Q_P,'codeFreq',codeFreq,'cur_state',true);
            %
            if nargin < 4
                return;
            end
            if mod(numel(varargin),2) ~= 0
                error('TrackResults2:update','Name-value pairs required.');
            end

            for i = 1:2:numel(varargin)
                name = varargin{i};
                value = varargin{i+1};

                if ~(ischar(name) || isstring(name))
                    error('TrackResults2:update','Property name must be char/string.');
                end
                pname = char(name);

                if ~isprop(obj, pname)
                    warning('TrackResults2:update:UnknownProp','Unknown property "%s" ignored.', pname);
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

        function succeed = save(obj)
            sv_tg = fullfile(obj.SvPth, sprintf('Trk_Prn_%02d_%03d.mat',...
                obj.PRN, obj.Svtimes+1));
            try
                save(sv_tg,"obj",'-mat');
                succeed = true;
            catch
                succeed = false;
            end
            if succeed
                obj.Svtimes = obj.Svtimes+1;
                % auto save and Tres size control
                % has a maximum size of 60[s] = 6e4ms
                Nn = obj.Nsize;
                cnoInt = 1e3;
                if isfield(settings,'CNoInterval')
                    if ~isempty(settings.CNoInterval)
                        cnoInt = settings.CNoInterval;
                    end
                end
                nCNo = floor(Nn / cnoInt);
                obj.absoluteSample = nan(1, Nn);
                obj.codeFreq       = nan(1, Nn);
                obj.carrFreq       = nan(1, Nn);
                obj.I_P = nan(1, Nn);
                obj.I_E = nan(1, Nn);
                obj.I_L = nan(1, Nn);
                obj.Q_E = nan(1, Nn);
                obj.Q_P = nan(1, Nn);
                obj.Q_L = nan(1, Nn);
                obj.Pilot_I_P = nan(1, Nn);
                obj.Pilot_Q_P = nan(1, Nn);
                obj.Pilot_I_E = nan(1, Nn);
                obj.Pilot_Q_E = nan(1, Nn);
                obj.Pilot_I_L = nan(1, Nn);
                obj.Pilot_Q_L = nan(1, Nn);
                obj.dllDiscr     = inf(1, Nn);
                obj.dllDiscrFilt = inf(1, Nn);
                obj.pllDiscr     = inf(1, Nn);
                obj.pllDiscrFilt = inf(1, Nn);
                obj.remCodePhase = inf(1, Nn);
                obj.remCarrPhase = inf(1, Nn);
                obj.Timestamp    = nan(1, Nn);
                obj.cur_state    = false(1, Nn);
                obj.trk_state    = zeros(1, Nn, 'uint8');
                obj.fllDiscrHz      = nan(1, Nn);
                obj.fllDiscrFiltHz  = nan(1, Nn);
                obj.fllCorrHz       = nan(1, Nn);
                obj.fllAided        = false(1, Nn);
                obj.kf_phiRad       = nan(1, Nn);
                obj.kf_omegaHz      = nan(1, Nn);
                obj.kf_alphaHzps    = nan(1, Nn);
                obj.kf_corrHz       = nan(1, Nn);
                obj.kf_nisPhi       = nan(1, Nn);
                obj.kf_nisOmega     = nan(1, Nn);
                obj.kf_rmsNuPhiRad  = nan(1, Nn);
                obj.kf_rmsNuOmegaHz = nan(1, Nn);
                obj.DataCNo   = nan(1, nCNo);
                obj.DataPLD   = nan(1, nCNo);
                obj.PilotCNo  = nan(1, nCNo);
                obj.PilotPLD  = nan(1, nCNo);
                obj.B2a_CNo   = nan(1, nCNo);
                obj.sigma_DLL = nan(1, nCNo);
                obj.sigma_PLL = nan(1, nCNo);
            end
        end

        function succeed = copyFROM(obj,other_obj,I_start)
            % copy data from other_obj with a start index I_start otherwise
            % the copy process will start from 1
            if isscalar(I_start) && isnumeric(I_start)
                I_start = min(length(obj.I_P),I_start);
            else
                warning('TrackResults2:copyFROM','The third iput should be a numerical scalar!');
                I_start = 1;
            end
            % calculate start index of CNo value
            cnoInt = 1e3;
            if isfield(settings,'CNoInterval')
                if ~isempty(settings.CNoInterval)
                    cnoInt = settings.CNoInterval;
                end
            end
            I_start_CNo = 1 + floor((I_start-1) / cnoInt);
            all_properties = properties(obj);
            copied_prop = 0;
            for p_ii = 1:length(all_properties)
                % no such prop in 'other_obj';
                if ~isprop(other_obj,all_properties{p_ii})
                    warning('TrackResult2:copyFROM',...
                        'No such property %s', all_properties{p_ii});
                    continue;
                end
                if ismember(all_properties{p_ii},{'PRN','status','Nsize'})
                    copied_prop = copied_prop + 1;
                    continue;
                end
                % for display copy info
                copied_prop = copied_prop + 1;
                % data length of right value
                Len_r = length(other_obj.(all_properties{p_ii}));
                if Len_r == other_obj.Nsize
                    % values @ 1000Hz
                    obj.(all_properties{p_ii})(I_start:I_start+Len_r-1) = ...
                        other_obj.(all_properties{p_ii});
                else
                    % values @ 1000/X Hz
                    obj.(all_properties{p_ii})(I_start_CNo:I_start_CNo+Len_r-1) =...
                        other_obj.(all_properties{p_ii});
                end
            end
            succeed = copied_prop/length(all_properties);
            fprintf('TrackingResult2:copyFROM\t%3d%% properties have been copied\n',...
                round(succeed*100));
        end

        function succeed = partsave(obj,settings,idx)
            % calculate start index of CNo value
            cnoInt = 1e3;
            if isfield(settings,'CNoInterval')
                if ~isempty(settings.CNoInterval)
                    cnoInt = settings.CNoInterval;
                end
            end
            idx = min(idx, obj.Nsize);
            idxCNo = floor(idx / cnoInt);
            all_properties = properties(obj);
            for p_ii = 1:length(all_properties)
                if ismember(all_properties{p_ii},{'PRN','status','Nsize'})
                    continue;
                end
                % cut off
                if length(obj.(all_properties{p_ii})) == obj.Nsize
                    % values @ 1000Hz
                    obj.(all_properties{p_ii})(idx+1:obj.Nsize) = [];
                else
                    % values @ 1000/X Hz
                    obj.(all_properties{p_ii})(idxCNo+1:end) = [];
                end
            end
            sv_tg = fullfile(obj.SvPth, sprintf('Trk_Prn_%02d_%03d.mat',...
                obj.PRN, obj.Svtimes+1));
            try
                save(sv_tg,"obj",'-mat');
                succeed = true;
            catch
                succeed = false;
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
                error('TrackResults2:estimateLoopNoise','settings required.');
            end

            % CNo interval
            if isfield(settings,'CNoInterval') && ~isempty(settings.CNoInterval)
                cnoInt = settings.CNoInterval;
            else
                cnoInt = 1e3;
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
                    warning('TrackResults2:estimateLoopNoise:DllFail','estimateDllSigmma failed at k=%d: %s', k, ME.message);
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
                error('TrackResults2:deriveCarrierPhase','settings required.');
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
                error('TrackResults2:writeRinex304','Need outFile, settings, startDateTime.');
            end
            if isstring(outFile), outFile = char(outFile); end
            if ischar(startDateTime) || isstring(startDateTime)
                startDateTime = datetime(startDateTime);
            end
            if ~isdatetime(startDateTime)
                error('TrackResults2:writeRinex304','startDateTime must be datetime (or convertible).');
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
                            warning('TrackResults2:writeRinex304:UnknownParam','Unknown parameter "%s".', key);
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
            [~, rxSOW0] = TrackResults2.datetime2weekSOW(startDateTime, timeSystem);

            % Open file
            fid = fopen(outFile, 'w');
            if fid < 0
                error('TrackResults2:writeRinex304','Cannot open file: %s', outFile);
            end
            cleaner = onCleanup(@() fclose(fid));

            % Header (minimal)
            fprintf(fid, '%-60s%-20s\n', '     3.04           OBSERVATION DATA    C                   ', 'RINEX VERSION / TYPE');
            fprintf(fid, '%-20s%-20s%-20s%-20s\n', 'TrackResults2', 'MATLAB', datestr(now,'yyyymmdd HHMMSS'), 'PGM / RUN BY / DATE');
            fprintf(fid, '%-60s%-20s\n', 'BDS B2a single-frequency from TrackResults2', 'COMMENT');
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
                    fprintf(fid, '%s', TrackResults2.rnxField(Cobs));
                    fprintf(fid, '%s', TrackResults2.rnxField(L));
                    fprintf(fid, '%s', TrackResults2.rnxField(D));
                    fprintf(fid, '%s', TrackResults2.rnxField(S));
                    fprintf(fid, '\n');
                end
            end
        end
    end

    methods (Static)
        function arr = createArray(settings, nChan)
            % createArray - create an array of independent TrackResults2 objects.
            if nargin < 2 || isempty(nChan)
                nChan = 1;
            end
            arr(1,nChan) = TrackResults2(settings); %#ok<AGROW>
            for k = 1:nChan
                arr(k) = TrackResults2(settings);
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
