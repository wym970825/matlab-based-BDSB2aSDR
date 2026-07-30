classdef NH_stateMachine < handle
    % NH_stateMachine - tracking/NH state machine (extended with optional FLL-aided states)
    %
    % Main goals:
    %   1) Manage INIT->ESTI->LONG transitions for Weil(100) phase estimation
    %   2) Provide PLL loop filter coefficients (pf) per state
    %   3) Provide REACQ trigger on low CN0
    %   4) (NEW) Provide 1ms FLL-aided substates for frequency-aiding:
    %        INIT  <-> INIT_FLL
    %        LONG  <-> LONG_FLL
    %
    % Usage:
    %   nh = NH_stateMachine(settings, PRN);
    %   nh.update(Pp_for_NH, [dataCN0, pilotCN0], loopCnt, fllErrHz_filt);


    properties
        % state / timers (units: ms)
        STATE char                = 'INIT';   % 'INIT'|'INIT_FLL'|'LONG'|'LONG_FLL'|'ESTI'|'REACQ'
        T_init double             = 0;        % ms, current INIT duration
        T_long double             = 0;        % ms, current LONG duration

        % thresholds (ms) - set at initialization
        T_th_init double = 0;
        T_th_long double = 0;
        T_th_pullin double = 0;  % must be < T_th_init

        % NH estimator sub-structure (will be a struct)
        NH_estimator struct

        % Last CN0 (dB-Hz): [data, pilot]
        LastCN0 double = [-1, -1];

        % CN0 threshold for REACQ
        CN0_Th double = 35; % default; overwritten from settings

        % Filter coefficient storage (PF_arr struct)
        PF_arr struct

        % current selected pf (3x1 double)
        pf double = [0;0;0];

        % re-acquisition attempts & flag
        N_att double = 0;
        NeedACQ logical = false;    % externally writable

        % ---------------- FLL aiding (V6) ----------------
        FLL_enable logical = false;      % allow INIT_FLL/LONG_FLL switching
        LastFllErrHz double = 0;         % last provided (filtered) FLL frequency error [Hz]

        FLL_thInitOn_Hz  double = 40;
        FLL_thInitOff_Hz double = 20;
        FLL_thLongOn_Hz  double = 15;
        FLL_thLongOff_Hz double = 8;
        FLL_N_on  double = 3;
        FLL_N_off double = 10;
    end

    properties (Access = private)
        % internal: used to hold a fallback pf if calc fails
        fallback_pf_pull double = [0.1; 0.01; 0.001];
        fallback_pf_init double = [0.2; 0.02; 0.002];
        fallback_pf_long double = [0.05; 0.005; 0.0005];

        % FLL hysteresis counters
        fllCntOn  double = 0;
        fllCntOff double = 0;
    end

    methods
        function obj = NH_stateMachine(settings, PRN)
            % NH_stateMachine constructor
            % usage: obj = NH_stateMachine(settings, PRN)

            % --- basic argument checks ---
            if nargin < 1
                error('NH_stateMachine: missing settings input');
            end
            if nargin < 2
                PRN = []; % allow empty PRN (GenWeil fallback will be used)
            end

            % --- set thresholds from settings with safe defaults ---
            if isfield(settings, 'trackInit_MS')
                obj.T_th_init = settings.trackInit_MS;
            else
                obj.T_th_init = 200;
            end
            if isfield(settings, 'reEstimateMS')
                obj.T_th_long = settings.reEstimateMS;
            else
                obj.T_th_long = 1000;
            end
            if isfield(settings, 'filter_pullinMS')
                obj.T_th_pullin = settings.filter_pullinMS;
            else
                obj.T_th_pullin = 50;
            end
            if isfield(settings, 'TrkCN0Th')
                obj.CN0_Th = settings.TrkCN0Th;
            else
                obj.CN0_Th = 35;
            end

            % --- FLL config (optional) ---
            if isfield(settings,'FLL') && isstruct(settings.FLL)
                if isfield(settings.FLL,'enable')
                    obj.FLL_enable = logical(settings.FLL.enable);
                end
                if isfield(settings.FLL,'errThInitOn_Hz'),  obj.FLL_thInitOn_Hz  = settings.FLL.errThInitOn_Hz; end
                if isfield(settings.FLL,'errThInitOff_Hz'), obj.FLL_thInitOff_Hz = settings.FLL.errThInitOff_Hz; end
                if isfield(settings.FLL,'errThLongOn_Hz'),  obj.FLL_thLongOn_Hz  = settings.FLL.errThLongOn_Hz; end
                if isfield(settings.FLL,'errThLongOff_Hz'), obj.FLL_thLongOff_Hz = settings.FLL.errThLongOff_Hz; end
                if isfield(settings.FLL,'N_on'),  obj.FLL_N_on  = settings.FLL.N_on; end
                if isfield(settings.FLL,'N_off'), obj.FLL_N_off = settings.FLL.N_off; end
            end

            % --- Ensure struct properties exist BEFORE any dot-assignment ---
            obj.PF_arr = struct();
            obj.NH_estimator = struct();

            % --- NH estimator defaults and buffer init ---
            if isfield(settings, 'weilEstBuffLen')
                W = settings.weilEstBuffLen;
            else
                W = 200; % default buffer length (safe fallback)
            end
            if isfield(settings, 'weilConfTh')
                Wth = settings.weilConfTh;
            else
                Wth = 6; % default confidence threshold
            end

            % create NH_estimator struct in one call
            obj.NH_estimator = struct( ...
                'W', W, ...
                'Th', Wth, ...
                'Buffer', complex(zeros(W,1)), ...
                'BufferCnt', 0, ...
                'IsBufferFilled', false, ...
                'Target', [], ...
                'WeilPhase', -1, ...
                'Conf', -1, ...
                'Anchor', -1 ...
                );

            % --- Try to populate Target using GenWeil(PRN), fallback if missing ---
            if ~isempty(PRN)
                try
                    tgt = GenWeil(PRN); % user-provided function
                    obj.NH_estimator.Target = tgt(:);
                    % Ensure Target is long enough for (phaseShift + bufferCnt) indexing
                    minLen = obj.NH_estimator.W + 100;
                    if numel(obj.NH_estimator.Target) < minLen
                        rep = ceil(minLen / max(numel(obj.NH_estimator.Target),1));
                        obj.NH_estimator.Target = repmat(obj.NH_estimator.Target, rep, 1);
                    end
                catch ME
                    warning('NH_stateMachine:GenWeilFailed',...
                        'GenWeil(PRN) failed: %s\nUsing placeholder Target (all ones).', ME.message);
                    obj.NH_estimator.Target = ones(max(64, W),1);
                    minLen = obj.NH_estimator.W + 100;
                    if numel(obj.NH_estimator.Target) < minLen
                        rep = ceil(minLen / max(numel(obj.NH_estimator.Target),1));
                        obj.NH_estimator.Target = repmat(obj.NH_estimator.Target, rep, 1);
                    end
                end
            else
                obj.NH_estimator.Target = ones(max(64, W),1);
            end

            % --- Initialize PF_arr from settings bandwidths (config-driven) ---
            % pf_pull : INIT while T_init < filter_pullinMS  (wider, e.g. 50 Hz)
            % pf_init : INIT after pull-in window              (stab BW, e.g. 30 Hz)
            % pf_long : LONG / LONG_FLL                       (stab BW, longCoh_ms)
            try
                if isfield(settings, 'pllOrder')
                    K = settings.pllOrder;
                else
                    K = 3;
                end
                % Defaults match initSettings (50 pull / 30 stab) if fields missing
                S_BW = 30;
                if isfield(settings, 'pllNoiseBandwidth_stab') && ~isempty(settings.pllNoiseBandwidth_stab)
                    S_BW = settings.pllNoiseBandwidth_stab;
                elseif isfield(settings, 'pllNoiseBandwidth') && ~isempty(settings.pllNoiseBandwidth)
                    S_BW = settings.pllNoiseBandwidth;
                end
                P_BW = 50;
                if isfield(settings, 'pllNoiseBandwidth_pull') && ~isempty(settings.pllNoiseBandwidth_pull)
                    P_BW = settings.pllNoiseBandwidth_pull;
                elseif isfield(settings, 'pllNoiseBandwidth_init') && ~isempty(settings.pllNoiseBandwidth_init)
                    P_BW = settings.pllNoiseBandwidth_init;
                end
                if isfield(settings, 'longCoh_ms')
                    LT = settings.longCoh_ms;
                else
                    LT = 1;
                end

                ST = 1; % 1 ms update during INIT

                pf_init = calcLoopCoef_NHSM(K, ST, S_BW);
                pf_pull = calcLoopCoef_NHSM(K, ST, P_BW);
                pf_long = calcLoopCoef_NHSM(K, LT, S_BW);

                pf_init = reshape(pf_init(:), min(numel(pf_init),3), 1);
                pf_pull = reshape(pf_pull(:), min(numel(pf_pull),3), 1);
                pf_long = reshape(pf_long(:), min(numel(pf_long),3), 1);

                pad_to_3 = @(v) ([v; zeros(3-numel(v),1)]);
                if numel(pf_init) < 3, pf_init = pad_to_3(pf_init); end
                if numel(pf_pull) < 3, pf_pull = pad_to_3(pf_pull); end
                if numel(pf_long) < 3, pf_long = pad_to_3(pf_long); end

                obj.PF_arr.pf_init = pf_init(1:3);
                obj.PF_arr.pf_pull = pf_pull(1:3);
                obj.PF_arr.pf_long = pf_long(1:3);
            catch ME
                warning('NH_stateMachine:calcLoopCoefFail',...
                    'calcLoopCoef_NHSM failed or missing: %s\nUsing fallback PF arrays.', ME.message);
                obj.PF_arr.pf_pull = obj.fallback_pf_pull;
                obj.PF_arr.pf_init = obj.fallback_pf_init;
                obj.PF_arr.pf_long = obj.fallback_pf_long;
            end

            % --- initial pf / timing states ---
            obj.pf = obj.PF_arr.pf_pull;
            obj.STATE = 'INIT';
            obj.T_init = 0;
            obj.T_long = 0;
            obj.LastCN0 = [-1, -1];
            obj.N_att = 0;
            obj.NeedACQ = false;

            obj.LastFllErrHz = 0;
            obj.fllCntOn  = 0;
            obj.fllCntOff = 0;
        end


        function update(obj, Pp, LastCN0_in, loopCnt, varargin)
            % update - main state machine update, called each external loop tick (ms)
            % Pp: complex pilot prompt for this tick (for NH estimator)
            % LastCN0_in: [dataCN0, pilotCN0] (dB-Hz)
            % loopCnt: current ms tick count (used for Anchor marking)
            % varargin{1}: fllErrHz (filtered) - optional

            if nargin < 4
                error('update requires Pp, LastCN0_in, loopCnt');
            end

            % --- optional FLL metric ---
            fllErrHz = 0;
            if ~isempty(varargin)
                fllErrHz = varargin{1};
            end
            if isempty(fllErrHz) || ~isfinite(fllErrHz)
                fllErrHz = 0;
            end
            obj.LastFllErrHz = fllErrHz;
            absF = abs(fllErrHz);

            % store CN0
            obj.LastCN0 = LastCN0_in;

            % -------- state machine --------
            switch obj.STATE
                case {'INIT','INIT_FLL'}
                    obj.T_init = obj.T_init + 1;

                    % pf scheduling during INIT
                    if obj.T_init >= obj.T_th_pullin
                        obj.pf = obj.PF_arr.pf_init;
                    else
                        obj.pf = obj.PF_arr.pf_pull;
                    end

                    % REACQ trigger (only when CN0 valid)
                    if any(obj.LastCN0 < obj.CN0_Th) && all(obj.LastCN0 > 0)
                        obj.enterReacq();
                        return;
                    end

                    % INIT -> ESTI time trigger (Weil estimation)
                    if obj.T_init >= obj.T_th_init
                        obj.STATE = 'ESTI';
                        obj.T_init = 0;
                        obj.LastCN0 = [-1,-1];
                        obj.fllCntOn = 0; obj.fllCntOff = 0;
                        % buffer update happens below; ESTI will be handled after switch
                    else
                        % FLL-aided substate switching (optional)
                        if obj.FLL_enable
                            if strcmp(obj.STATE,'INIT')
                                % enter INIT_FLL
                                if absF >= obj.FLL_thInitOn_Hz
                                    obj.fllCntOn = obj.fllCntOn + 1;
                                else
                                    obj.fllCntOn = 0;
                                end
                                if obj.fllCntOn >= obj.FLL_N_on
                                    obj.STATE = 'INIT_FLL';
                                    obj.fllCntOn = 0;
                                    obj.fllCntOff = 0;
                                end
                            else
                                % exit INIT_FLL
                                if absF <= obj.FLL_thInitOff_Hz
                                    obj.fllCntOff = obj.fllCntOff + 1;
                                else
                                    obj.fllCntOff = 0;
                                end
                                if obj.fllCntOff >= obj.FLL_N_off
                                    obj.STATE = 'INIT';
                                    obj.fllCntOn = 0;
                                    obj.fllCntOff = 0;
                                end
                            end
                        end
                    end

                    % update buffer (for Weil estimation)
                    obj.update_buffer(Pp);

                case {'LONG','LONG_FLL'}
                    obj.T_long = obj.T_long + 1;
                    obj.pf = obj.PF_arr.pf_long;

                    % REACQ trigger
                    if any(obj.LastCN0 < obj.CN0_Th) && all(obj.LastCN0 > 0)
                        obj.enterReacq();
                        return;
                    end

                    % LONG -> ESTI time trigger (re-estimate Weil)
                    if obj.T_long >= obj.T_th_long
                        obj.STATE = 'ESTI';
                        obj.T_long = 0;
                        obj.LastCN0 = [-1,-1];
                        obj.fllCntOn = 0; obj.fllCntOff = 0;
                    else
                        % FLL-aided substate switching (optional)
                        if obj.FLL_enable
                            if strcmp(obj.STATE,'LONG')
                                % enter LONG_FLL
                                if absF >= obj.FLL_thLongOn_Hz
                                    obj.fllCntOn = obj.fllCntOn + 1;
                                else
                                    obj.fllCntOn = 0;
                                end
                                if obj.fllCntOn >= obj.FLL_N_on
                                    obj.STATE = 'LONG_FLL';
                                    obj.fllCntOn = 0;
                                    obj.fllCntOff = 0;
                                end
                            else
                                % exit LONG_FLL
                                if absF <= obj.FLL_thLongOff_Hz
                                    obj.fllCntOff = obj.fllCntOff + 1;
                                else
                                    obj.fllCntOff = 0;
                                end
                                if obj.fllCntOff >= obj.FLL_N_off
                                    obj.STATE = 'LONG';
                                    obj.fllCntOn = 0;
                                    obj.fllCntOff = 0;
                                end
                            end
                        end
                    end

                    obj.update_buffer(Pp);

                case 'REACQ'
                    if obj.NeedACQ
                        obj.N_att = obj.N_att + 1;
                    else
                        % returned from external ACQ -> go back to INIT
                        obj.STATE = 'INIT';
                        obj.T_init = 0;
                        obj.LastCN0 = [-1,-1];
                        obj.pf = obj.PF_arr.pf_pull;
                        obj.clearBuffer();
                        obj.fllCntOn = 0; obj.fllCntOff = 0;
                    end

                otherwise
                    error('Unknown state: %s', obj.STATE);
            end

            % ------------------ ESTI handling (executed in same update call) ------------------
            if strcmp(obj.STATE, 'ESTI')
                obj.estimateWeilPhase(loopCnt);

                if obj.NH_estimator.Conf >= obj.NH_estimator.Th
                    % success -> LONG (or LONG_FLL if FLL error large)
                    if obj.FLL_enable && (absF >= obj.FLL_thLongOn_Hz)
                        obj.STATE = 'LONG_FLL';
                    else
                        obj.STATE = 'LONG';
                    end
                    obj.T_long = 0;
                    obj.LastCN0 = [-1, -1];
                    obj.pf = obj.PF_arr.pf_long;
                else
                    % failure -> INIT
                    obj.NH_estimator.WeilPhase = -1;
                    obj.NH_estimator.Conf = -1;
                    obj.NH_estimator.Anchor = -1;
                    obj.STATE = 'INIT';
                    obj.T_init = 0;
                    obj.LastCN0 = [-1, -1];
                    obj.pf = obj.PF_arr.pf_pull;
                end

                obj.clearBuffer();
            end
        end % update


        function id = getStateId(obj)
            % Map state string to a compact numeric id (for logging)
            switch upper(string(obj.STATE))
                case "INIT"
                    id = uint8(1);
                case "INIT_FLL"
                    id = uint8(2);
                case "LONG"
                    id = uint8(3);
                case "LONG_FLL"
                    id = uint8(4);
                case "REACQ"
                    id = uint8(9);
                otherwise
                    id = uint8(0);
            end
        end

        function tf = usePullinFilters(obj)
            %USEPULLINFILTERS True while INIT* and still inside filter_pullinMS.
            % Used to switch PLL pf and DLL Bn together (same timeline).
            if strcmpi(obj.STATE, 'INIT') || strcmpi(obj.STATE, 'INIT_FLL')
                tf = obj.T_init < obj.T_th_pullin;
            else
                tf = false;
            end
        end

    end % methods


    methods (Access = private)
        function enterReacq(obj)
            obj.STATE = 'REACQ';
            obj.T_init = 0;
            obj.T_long = 0;
            obj.LastCN0 = [-1,-1];
            obj.NeedACQ = true;
            obj.N_att = 0;
            obj.pf = obj.PF_arr.pf_pull;
            obj.fllCntOn = 0; obj.fllCntOff = 0;
        end

        function clearBuffer(obj)
            obj.NH_estimator.Buffer = complex(zeros(obj.NH_estimator.W,1));
            obj.NH_estimator.BufferCnt = 0;
            obj.NH_estimator.IsBufferFilled = false;
        end

        function update_buffer(obj, Pp)
            if ~obj.NH_estimator.IsBufferFilled
                obj.NH_estimator.BufferCnt = obj.NH_estimator.BufferCnt + 1;
                idx = obj.NH_estimator.BufferCnt;
                if idx <= obj.NH_estimator.W
                    obj.NH_estimator.Buffer(idx) = Pp;
                else
                    obj.NH_estimator.Buffer = [obj.NH_estimator.Buffer(2:end); Pp];
                    obj.NH_estimator.BufferCnt = obj.NH_estimator.W;
                    obj.NH_estimator.IsBufferFilled = true;
                end
                if obj.NH_estimator.BufferCnt >= obj.NH_estimator.W
                    obj.NH_estimator.IsBufferFilled = true;
                end
            else
                obj.NH_estimator.Buffer = [obj.NH_estimator.Buffer(2:end); Pp];
            end
        end

        function estimateWeilPhase(obj, loopCnt)
            % Estimate Weil(100) phase by enumeration (keep legacy behavior)
            bufferCnt = min(obj.NH_estimator.BufferCnt, obj.NH_estimator.W);
            if bufferCnt <= 0
                obj.NH_estimator.WeilPhase = -1;
                obj.NH_estimator.Conf = -1;
                obj.NH_estimator.Anchor = -1;
                return;
            end

            curBuf = obj.NH_estimator.Buffer(1:bufferCnt);
            target = obj.NH_estimator.Target(:);

            % ensure Target long enough
            if numel(target) < (bufferCnt + 100)
                rep = ceil((bufferCnt + 100) / max(numel(target),1));
                target = repmat(target, rep, 1);
            end

            Corr = complex(zeros(100,1));
            for phaseShift = 0:99
                tgtSeg = target(phaseShift+1 : phaseShift+bufferCnt);
                Corr(phaseShift+1) = sum(curBuf .* conj(tgtSeg));
            end

            mags = abs(Corr);
            [bestZ, bestIdx] = max(mags);
            bestPhase = bestIdx - 1;

            mags(bestIdx) = -inf;
            secondZ = max(mags);

            conf = bestZ / (secondZ + eps);

            obj.NH_estimator.WeilPhase = bestPhase;
            obj.NH_estimator.Conf = conf;
            obj.NH_estimator.Anchor = loopCnt - bufferCnt + 1;
        end
    end
end
