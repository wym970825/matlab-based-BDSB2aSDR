classdef scint_calculator < handle
    % scint_calculator  Real-time ionospheric scintillation index calculator.
    %
    % Design principles
    % -----------------
    %   * push() only accumulates raw amplitude & phase into temporary
    %     buffers (ori_A / ori_Phi).  No filtering is performed here.
    %   * tickUpdate() fires every updateInterval ms.  When triggered it
    %     calls flushOriBuf(), which batch-filters the whole pending block
    %     using MATLAB's built-in filter() with persistent state (zi/zf),
    %     then writes the de-trended results into the circular registers.
    %   * computeScint() reads the circular registers and performs purely
    %     statistical operations (S4, phi60, tau0, rho_phi1).  No filtering
    %     is done here.
    %   * S4 thermal-noise correction (Conker et al. 2003) is NOT applied
    %     inside computeScint().  The result struct carries S4_ori and
    %     S4_corr separately.  The caller (computeKF_R) applies the
    %     correction:  S4 = sqrt(max(S4_ori^2 - S4_corr^2 , 0))
    %
    % S4 thermal-noise correction formula
    % ------------------------------------
    %   S4_corr = sqrt( (100/CN0) * (1 + 500/(19*CN0)) )
    %   where CN0 is in Hz (linear).
    %   Corrected S4 = sqrt( max(S4_ori^2 - S4_corr^2, 0) )   [done in caller]
    %
    % Typical usage in tracking2_v6_fix1.m
    % --------------------------------------
    %   scint = scint_calculator(settings);          % init (once per channel)
    %
    %   % inside the 1-ms loop:
    %   scint.push(Ip, Qp, remCarrPhase, carrFreq, isLong, CNoValue(2));
    %
    %   if scint.hasNewResult()
    %       res  = scint.getResult();
    %       kfR  = scint_calculator.computeKF_R(res, settings);
    %       kf.qJerk = scint_calculator.computeKF_qJerk(res, kf.qJerk, settings);
    %       if kfR.valid
    %           % pass kfR.Rphi / kfR.Romega to KF update calls
    %       end
    %   end
    %
    %   scint.reset();   % call on REACQ / loss-of-lock
    %
    % Optional settings fields
    % -------------------------
    %   settings.longCoh_ms       long-coherent integration length (ms), default 1
    %   settings.scint_updateMs   output update interval (ms),          default 50
    %   settings.scint_bufLen     circular buffer length (ms),          default 60000
    %   settings.scint_fCutoff    de-trending cutoff frequency (Hz),    default 0.1

    %% ===== Public properties =====
    properties
        bufLen          double = 60000   % circular buffer length (ms)
        updateInterval  double = 50      % scintillation index update interval (ms)
        fCutoff         double = 0.1     % de-trending IIR cutoff frequency (Hz)
        longCoh_ms      double = 1       % long-coherent integration length (ms)
        result          struct           % latest output result struct
    end

    %% ===== Private properties =====
    properties (Access = private)
        % ---------- Filtered circular registers ----------
        SI_buf          double   % normalised amplitude after de-trending
        phiHP_buf       double   % high-pass carrier phase (rad)
        stateBuf        logical  % LONG / LONG_FLL flag per sample

        % ---------- Circular-buffer bookkeeping ----------
        writeIdx        double = 1
        ptr             double = 0       % valid samples stored (max = bufLen)
        isFull          logical = false

        % ---------- Raw-data temporary batch buffer ----------
        % Filled by push(); consumed (filtered) by flushOriBuf().
        ori_A           double   % raw amplitude     (updateInterval x 1)
        ori_Phi         double   % integrated phase  (updateInterval x 1, rad)
        ori_State       logical  % LONG flag
        oriBufPtr       double = 0   % write pointer into the batch buffer

        % ---------- Carrier-phase integration state ----------
        prevRemCarrPhase    double  = NaN
        accumPhase          double  = 0
        phaseInitialized    logical = false

        % ---------- Full-rate IIR filters  (fs = 1000 Hz) ----------
        % Each filter is a 6th-order Butterworth implemented as 3 cascaded
        % 2nd-order sections (SOS).  MATLAB filter() is called one section
        % at a time so that state (zi / zf) can be maintained across calls.
        %
        % B_lp, A_lp : (3x3) SOS coefficients  [b0 b1 b2] / [1 a1 a2]
        % zi_lp      : (3x2) filter state — one row per section,
        %              compatible with MATLAB filter(b,a,x,zi) where
        %              zi has length max(length(b),length(a))-1 = 2.
        B_lp            double   % amplitude low-pass,  numerator
        A_lp            double   % amplitude low-pass,  denominator
        zi_lp           double   % amplitude low-pass,  state  (3x2)

        B_hp            double   % phase high-pass,     numerator
        A_hp            double   % phase high-pass,     denominator
        zi_hp           double   % phase high-pass,     state  (3x2)

        % ---------- Down-sampled IIR filters  (fs = 1000/longCoh_ms Hz) ----------
        B_lp_ds         double
        A_lp_ds         double
        zi_lp_ds        double   % (3x2)

        B_hp_ds         double
        A_hp_ds         double
        zi_hp_ds        double   % (3x2)

        % ---------- Down-sampling accumulator (longCoh_ms > 1) ----------
        dsCnt           double  = 0
        ampAccum        double  = 0
        phiAccum        double  = 0
        dsStateAccum    logical = false
        accumCnt        double  = 0

        % ---------- Update timing ----------
        tickSinceUpdate double  = 0
        newResultFlag   logical = false

        % ---------- Misc ----------
        lastCN0dB       double  = 45   % most recent CN0 estimate (dB-Hz)
        fs              double  = 1000 % base sample rate (Hz)
    end

    %% ===== Public methods =====
    methods

        % ------------------------------------------------------------------
        function obj = scint_calculator(settings)
            % Constructor.  All parameters have sensible defaults.
            if nargin >= 1 && isstruct(settings)
                if isfield(settings,'longCoh_ms')    && ~isempty(settings.longCoh_ms)
                    obj.longCoh_ms    = settings.longCoh_ms;    
                end
                if isfield(settings,'scint_bufLen')  && ~isempty(settings.scint_bufLen)
                    obj.bufLen        = settings.scint_bufLen;  
                end
                if isfield(settings,'scint_updateMs')&& ~isempty(settings.scint_updateMs)
                    obj.updateInterval= settings.scint_updateMs;
                end
                if isfield(settings,'scint_fCutoff') && ~isempty(settings.scint_fCutoff)
                    obj.fCutoff = settings.scint_fCutoff;
                end
                if isfield(settings,'intTime') && ~isempty(settings.intTime)
                    obj.fs = round(1/settings.intTime);
                else
                    obj.fs = 1e3;
                end
            else
                error('Initialization need a settings struct as input.')
            end
            obj.SI_buf    = nan(obj.bufLen, 1);
            obj.phiHP_buf = nan(obj.bufLen, 1);
            obj.stateBuf  = false(obj.bufLen, 1);

            % Allocate raw batch buffer (size = updateInterval)
            obj.ori_A     = nan(obj.updateInterval, 1);
            obj.ori_Phi   = nan(obj.updateInterval, 1);
            obj.ori_State = false(obj.updateInterval, 1);

            % Design full-rate filters (fs = 1000 Hz)
            [obj.B_lp, obj.A_lp] = scint_calculator.designLP6sos(obj.fs, obj.fCutoff);
            [obj.B_hp, obj.A_hp] = scint_calculator.designHP6sos(obj.fs, obj.fCutoff);
            obj.zi_lp = zeros(3, 2);   % 3 sections x order-2 state
            obj.zi_hp = zeros(3, 2);

            % Design down-sampled filters (fs = 1000/longCoh_ms Hz)
            fs_ds = obj.fs / max(obj.longCoh_ms, 1);
            [obj.B_lp_ds, obj.A_lp_ds] = scint_calculator.designLP6sos(fs_ds, obj.fCutoff);
            [obj.B_hp_ds, obj.A_hp_ds] = scint_calculator.designHP6sos(fs_ds, obj.fCutoff);
            obj.zi_lp_ds = zeros(3, 2);
            obj.zi_hp_ds = zeros(3, 2);

            obj.result = scint_calculator.emptyResult();
        end

        % ------------------------------------------------------------------
        function push(obj, Ip, Qp, remCarrPhase, ~, isLong, CN0dB)
            % push  Called every 1 ms.  Only accumulates raw data; no filtering.
            %
            % Inputs:
            %   Ip, Qp          pilot prompt correlator outputs
            %   remCarrPhase    residual carrier phase from the tracking loop (rad)
            %   ~               carrFreq placeholder (unused, kept for API compat)
            %   isLong          true when state is LONG or LONG_FLL
            %   CN0dB           current CN0 estimate (dB-Hz)

            % Update CN0 estimate
            if nargin >= 7 && isfinite(CN0dB) && CN0dB > 0
                obj.lastCN0dB = CN0dB;
            end

            % Validity check — NaN marks a gap/loss-of-lock
            if ~isfinite(Ip) || ~isfinite(Qp) || ~isfinite(remCarrPhase)
                obj.appendOriBuf(NaN, NaN, isLong);
                obj.resetPhaseTracking();
            else
                A   = sqrt(Ip*Ip + Qp*Qp);
                phi = obj.integratePhase(remCarrPhase);
                obj.appendOriBuf(A, phi, isLong);
            end

            % Advance tick counter; batch-filter + compute when interval reached
            obj.tickUpdate();
        end

        % ------------------------------------------------------------------
        function flag = hasNewResult(obj)
            % Returns true when a fresh result is ready since the last getResult().
            flag = obj.newResultFlag;
        end

        % ------------------------------------------------------------------
        function res = getResult(obj)
            % Returns the latest result struct and clears the new-result flag.
            res = obj.result;
            obj.newResultFlag = false;
        end

        % ------------------------------------------------------------------
        function reset(obj)
            % Full reset — call on REACQ or loss-of-lock.
            obj.SI_buf(:)    = NaN;
            obj.phiHP_buf(:) = NaN;
            obj.stateBuf(:)  = false;
            obj.writeIdx     = 1;
            obj.ptr          = 0;
            obj.isFull       = false;

            obj.ori_A(:)     = NaN;
            obj.ori_Phi(:)   = NaN;
            obj.ori_State(:) = false;
            obj.oriBufPtr    = 0;

            % Zero IIR filter states
            obj.zi_lp        = zeros(3, 2);
            obj.zi_hp        = zeros(3, 2);
            obj.zi_lp_ds     = zeros(3, 2);
            obj.zi_hp_ds     = zeros(3, 2);

            % Reset down-sampling accumulator
            obj.dsCnt        = 0;
            obj.ampAccum     = 0;
            obj.phiAccum     = 0;
            obj.dsStateAccum = false;
            obj.accumCnt     = 0;

            obj.resetPhaseTracking();
            obj.tickSinceUpdate = 0;
            obj.newResultFlag   = false;
            obj.result          = scint_calculator.emptyResult();
        end

    end % public methods

    %% ===== Private methods =====
    methods (Access = private)

        % ------------------------------------------------------------------
        function phi = integratePhase(obj, remCarrPhase)
            % Accumulate continuous carrier phase from the residual phase
            % provided by the tracking loop.  Phase wraps are resolved by
            % restricting the 1-ms difference to [-pi, pi].
            if ~obj.phaseInitialized
                obj.prevRemCarrPhase = remCarrPhase;
                obj.accumPhase       = remCarrPhase;
                obj.phaseInitialized = true;
                phi = obj.accumPhase;
                return;
            end
            dPhi = mod(remCarrPhase - obj.prevRemCarrPhase + pi, 2*pi) - pi;
            obj.accumPhase       = obj.accumPhase + dPhi;
            obj.prevRemCarrPhase = remCarrPhase;
            phi = obj.accumPhase;
        end

        % ------------------------------------------------------------------
        function resetPhaseTracking(obj)
            obj.prevRemCarrPhase = NaN;
            obj.phaseInitialized = false;
        end

        % ------------------------------------------------------------------
        function appendOriBuf(obj, A, phi, isLong)
            % Append one raw sample to the batch buffer.
            % The buffer is sized to updateInterval; it is consumed (and its
            % pointer reset to 0) each time tickUpdate() fires.
            obj.oriBufPtr = obj.oriBufPtr + 1;
            if obj.oriBufPtr <= obj.updateInterval
                obj.ori_A(obj.oriBufPtr)     = A;
                obj.ori_Phi(obj.oriBufPtr)   = phi;
                obj.ori_State(obj.oriBufPtr) = logical(isLong);
            end
        end

        % ------------------------------------------------------------------
        function tickUpdate(obj)
            % Advance the tick counter.  When updateInterval ticks have
            % elapsed: batch-filter the raw buffer, write results into the
            % circular registers, then compute scintillation statistics.
            obj.tickSinceUpdate = obj.tickSinceUpdate + 1;
            if obj.tickSinceUpdate >= obj.updateInterval
                obj.tickSinceUpdate = 0;
                obj.flushOriBuf();       % IIR-filter the batch + write registers
                obj.oriBufPtr    = 0;   % reset raw-buffer write pointer
                obj.computeScint();     % statistical computation
            end
        end

        % ------------------------------------------------------------------
        function flushOriBuf(obj)
            % Batch-filter the raw samples accumulated since the last flush,
            % then append the filtered (SI, phiHP) pairs to the circular
            % registers.
            %
            % MATLAB's built-in filter() is used for all IIR operations:
            %   [y, zf] = filter(b, a, x, zi)
            % where zi / zf carry the filter memory across successive calls,
            % ensuring correct IIR behaviour over the whole recording.
            %
            % For a 6th-order filter decomposed into 3 cascaded 2nd-order
            % sections, filter() is called once per section; the output of
            % one section is the input of the next.

            n = obj.oriBufPtr;
            if n <= 0, return; end

            A_batch     = obj.ori_A(1:n);
            phi_batch   = obj.ori_Phi(1:n);
            state_batch = obj.ori_State(1:n);

            % Detect NaN gaps so we can skip IIR updates on invalid samples
            nanMask = isnan(A_batch) | isnan(phi_batch);

            if obj.longCoh_ms <= 1
                % ============================================================
                % Full-rate mode (1 ms per sample)
                % ============================================================
                % Strategy: process the batch as one contiguous block wherever
                % possible.  When the block is NaN-free we can push all n
                % samples through filter() in a single call (vectorised).
                % Otherwise we fall back to a sample-by-sample loop.

                if ~any(nanMask)
                    % --- Fast path: no NaN in this batch ---
                    % Run the 3-section cascade for both amplitude LP and phase HP.
                    % filter() preserves the zi state between batches.

                    % Amplitude low-pass (extract trend)
                    A_trend = A_batch;
                    for s = 1:3
                        [A_trend, obj.zi_lp(s,:)] = ...
                            filter(obj.B_lp(s,:), obj.A_lp(s,:), A_trend, obj.zi_lp(s,:));
                    end

                    % Phase high-pass (remove slow drift)
                    phi_hp = phi_batch;
                    for s = 1:3
                        [phi_hp, obj.zi_hp(s,:)] = ...
                            filter(obj.B_hp(s,:), obj.A_hp(s,:), phi_hp, obj.zi_hp(s,:));
                    end

                    % Normalised amplitude: SI = A / A_trend
                    SI = A_batch ./ max(abs(A_trend), 1e-12);

                    % Write all n samples to the circular register at once
                    for k = 1:n
                        obj.writeSample(SI(k), phi_hp(k), state_batch(k));
                    end

                else
                    % --- Slow path: NaN gaps present — process sample by sample ---
                    % NaN samples are written as NaN (gap marker) without updating
                    % the IIR state, preserving filter memory across valid segments.
                    for k = 1:n
                        if nanMask(k)
                            obj.writeSample(NaN, NaN, state_batch(k));
                            % Do NOT update zi — preserves memory for next valid run
                        else
                            % Single-sample IIR step: pass a length-1 vector
                            a_k = A_batch(k);
                            p_k = phi_batch(k);

                            % Amplitude low-pass cascade
                            for s = 1:3
                                [a_k, obj.zi_lp(s,:)] = ...
                                    filter(obj.B_lp(s,:), obj.A_lp(s,:), a_k, obj.zi_lp(s,:));
                            end
                            A_trend_k = a_k;

                            % Phase high-pass cascade
                            for s = 1:3
                                [p_k, obj.zi_hp(s,:)] = ...
                                    filter(obj.B_hp(s,:), obj.A_hp(s,:), p_k, obj.zi_hp(s,:));
                            end
                            phi_hp_k = p_k;

                            SI_k = A_batch(k) / max(abs(A_trend_k), 1e-12);
                            obj.writeSample(SI_k, phi_hp_k, state_batch(k));
                        end
                    end
                end

            else
                % ============================================================
                % Down-sampled mode (longCoh_ms > 1)
                % ============================================================
                % The full-rate filters are still driven every 1 ms to maintain
                % their memory, but their output is discarded.  Every longCoh_ms
                % samples are averaged (amplitude) / last-valued (phase) and
                % pushed through the dedicated down-sampled filters.

                for k = 1:n
                    if nanMask(k)
                        % Gap: reset down-sampling accumulator, write NaN marker
                        obj.dsCnt        = 0;
                        obj.ampAccum     = 0;
                        obj.phiAccum     = 0;
                        obj.dsStateAccum = false;
                        obj.accumCnt     = 0;
                        obj.writeSample(NaN, NaN, state_batch(k));
                        % Full-rate filter states are NOT updated (preserve memory)
                    else
                        Ak   = A_batch(k);
                        phik = phi_batch(k);

                        % Drive full-rate filters (state maintenance only)
                        tmp_a = Ak;
                        tmp_p = phik;
                        for s = 1:3
                            [~, obj.zi_lp(s,:)] = ...
                                filter(obj.B_lp(s,:), obj.A_lp(s,:), tmp_a, obj.zi_lp(s,:));
                            [~, obj.zi_hp(s,:)] = ...
                                filter(obj.B_hp(s,:), obj.A_hp(s,:), tmp_p, obj.zi_hp(s,:));
                        end

                        % Accumulate for the down-sampled point
                        obj.dsCnt        = obj.dsCnt + 1;
                        obj.ampAccum     = obj.ampAccum + Ak;
                        obj.phiAccum     = phik;                    % keep last value
                        obj.dsStateAccum = obj.dsStateAccum || state_batch(k);
                        obj.accumCnt     = obj.accumCnt + 1;

                        if obj.dsCnt >= obj.longCoh_ms
                            % Form the down-sampled point
                            A_mean = obj.ampAccum / max(obj.accumCnt, 1);
                            phi_ds = obj.phiAccum;
                            st_ds  = obj.dsStateAccum;

                            % Pass through down-sampled filters (one step each)
                            a_ds = A_mean;
                            p_ds = phi_ds;
                            for s = 1:3
                                [a_ds, obj.zi_lp_ds(s,:)] = ...
                                    filter(obj.B_lp_ds(s,:), obj.A_lp_ds(s,:), a_ds, obj.zi_lp_ds(s,:));
                                [p_ds, obj.zi_hp_ds(s,:)] = ...
                                    filter(obj.B_hp_ds(s,:), obj.A_hp_ds(s,:), p_ds, obj.zi_hp_ds(s,:));
                            end
                            A_trend_ds = a_ds;
                            phi_hp_ds  = p_ds;

                            SI_ds = A_mean / max(abs(A_trend_ds), 1e-12);
                            obj.writeSample(SI_ds, phi_hp_ds, st_ds);

                            % Reset accumulator
                            obj.dsCnt        = 0;
                            obj.ampAccum     = 0;
                            obj.phiAccum     = 0;
                            obj.dsStateAccum = false;
                            obj.accumCnt     = 0;
                        end
                    end
                end
            end
        end % flushOriBuf

        % ------------------------------------------------------------------
        function writeSample(obj, SI, phiHP, isLong)
            % Append one processed sample to the circular registers.
            obj.SI_buf(obj.writeIdx)    = SI;
            obj.phiHP_buf(obj.writeIdx) = phiHP;
            obj.stateBuf(obj.writeIdx)  = logical(isLong);
            obj.writeIdx = mod(obj.writeIdx, obj.bufLen) + 1;
            if obj.ptr < obj.bufLen
                obj.ptr = obj.ptr + 1;
            else
                obj.isFull = true;
            end
        end

        % ------------------------------------------------------------------
        function computeScint(obj)
            % Compute scintillation indices from the circular registers.
            %
            % Outputs stored in obj.result:
            %   S4_ori   — raw S4 (not noise-corrected)
            %   S4_corr  — thermal-noise correction term (Conker et al. 2003)
            %              Correction:  S4 = sqrt(max(S4_ori^2 - S4_corr^2, 0))
            %              This step is performed by the CALLER (computeKF_R).
            %   phi60    — RMS of high-pass phase (>fCutoff Hz), rad
            %   tau0     — amplitude de-correlation time (1/e), s
            %   rho_phi1 — lag-1 phase autocorrelation coefficient

            if obj.ptr < 200, return; end   % need at least 200 samples

            % Read the circular buffer in chronological order
            if obj.isFull
                idx = mod((obj.writeIdx-1 : obj.writeIdx + obj.bufLen - 2), obj.bufLen) + 1;
            else
                idx = 1 : obj.ptr;
            end

            SI_seq    = obj.SI_buf(idx);
            phiHP_seq = obj.phiHP_buf(idx);
            st_seq    = obj.stateBuf(idx);

            % Any NaN in the window → suppress output (gap contamination)
            if any(isnan(SI_seq)) || any(isnan(phiHP_seq))
                obj.result        = scint_calculator.emptyResult();
                obj.newResultFlag = true;
                return;
            end

            allLong = all(st_seq);

            % ---- S4_ori  (raw amplitude scintillation index) ----
            % S4^2 = Var(SI) / E[SI]^2 = (E[SI^2] - E[SI]^2) / E[SI]^2
            mSI2     = mean(SI_seq .^ 2);
            mSI      = mean(SI_seq);
            S4sq_ori = max((mSI2 - mSI^2) / max(mSI^2, 1e-12), 0);
            S4_ori   = sqrt(S4sq_ori);

            % ---- S4_corr  (Conker et al. 2003 thermal-noise term) ----
            % S4_corr = sqrt( (100/CN0) * (1 + 500/(19*CN0)) )
            CN0_lin  = 10^(obj.lastCN0dB / 10);
            S4corrsq = (100 / max(CN0_lin, 1e-6)) * ...
                       (1 + 500 / max(19 * CN0_lin, 1e-6));
            S4_corr  = sqrt(max(S4corrsq, 0));

            % ---- phi60  (phase RMS above fCutoff, rad) ----
            phi60 = std(phiHP_seq);

            % ---- tau0  (amplitude de-correlation time, s) ----
            tau0 = obj.estimateTau0(SI_seq, allLong);

            % ---- rho_phi1  (lag-1 phase autocorrelation) ----
            rho_phi1 = obj.computeRhoPhi1(phiHP_seq);

            % Pack result
            res.valid    = true;
            res.S4_ori   = S4_ori;
            res.S4_corr  = S4_corr;
            res.phi60    = phi60;
            res.tau0     = tau0;
            res.rho_phi1 = rho_phi1;
            res.nSamples = numel(SI_seq);
            res.allLong  = allLong;
            res.CN0dB    = obj.lastCN0dB;

            obj.result        = res;
            obj.newResultFlag = true;
        end

        % ------------------------------------------------------------------
        function tau0 = estimateTau0(obj, SI, allLong)
            % Estimate the de-correlation time tau0 from the amplitude
            % autocorrelation function (ACF).  tau0 is defined as the lag
            % at which the ACF first falls below 1/e.
            N = numel(SI);
            if N < 20, tau0 = NaN; return; end

            si_zm = SI - mean(SI);
            v0    = sum(si_zm .^ 2);
            if v0 < 1e-20, tau0 = NaN; return; end

            maxLag = min(N - 1, 500);
            acf    = zeros(maxLag + 1, 1);
            acf(1) = 1.0;
            for lag = 1:maxLag
                acf(lag+1) = sum(si_zm(1:end-lag) .* si_zm(lag+1:end)) / v0;
            end

            thr      = exp(-1);
            crossIdx = find(acf < thr, 1, 'first');

            if isempty(crossIdx)
                tau0_samp = maxLag;
            else
                % Linear interpolation around the crossing point
                l0   = max(crossIdx - 2, 1);
                l1   = crossIdx - 1;
                acf0 = acf(l0 + 1);
                acf1 = acf(l1 + 1);
                if abs(acf0 - acf1) < 1e-12
                    tau0_samp = l1;
                else
                    tau0_samp = l0 + (thr - acf0) / (acf1 - acf0);
                end
            end

            % Convert from sample lag to seconds
            dt = 1e-3;
            if allLong && obj.longCoh_ms > 1
                dt = obj.longCoh_ms * 1e-3;
            end
            tau0 = tau0_samp * dt;
        end

        % ------------------------------------------------------------------
        function rho = computeRhoPhi1(~, phi_hp)
            % Lag-1 phase autocorrelation coefficient.
            % rho = 1 - Var(diff(phi)) / (2 * Var(phi))
            % This is used to correct the KF frequency-measurement variance.
            if numel(phi_hp) < 4, rho = 0; return; end
            vPhi  = var(phi_hp);
            vDiff = var(diff(phi_hp));
            if vPhi < 1e-20, rho = 0; return; end
            rho = max(min(1 - vDiff / (2 * vPhi), 1), -1);
        end

    end % private methods

    %% ===== Static methods =====
    methods (Static)

        % ------------------------------------------------------------------
        function kfR = computeKF_R(scintRes, settings, SM)
            % computeKF_R  Compute KF measurement noise covariance from scintillation.
            %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
            % New in V2
            % computeKF_R  Compute KF measurement covariance using Conker Eq. (5).
            %  Q is not changed here.  Since this receiver has no high-stability
            % clock / external phase-scintillation spectral estimator, the
            % phase-scintillation PSD term in Conker Eq. (5) is omitted.  The
            % retained term is the amplitude-scintillation-modified thermal
            % The S4 correction is applied here:
            %   S4 = sqrt( max(S4_ori^2 - S4_corr^2, 0) )
            %   %   R_phi = Bn * (1 + 1/(2*Tcoh*CN0*(1 - 2*S4^2))) ...
            %           / (CN0*(1 - S4^2))                         [rad^2]
            % ---------------------NOTICE-------------------------
            %    formula is valid below S4 < 0.707, so S4 is capped below the
            % singularity.  R_omega is propagated from differenced phase noise.
            % ----------------------------------------------------------
            %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
            % The S4 correction is applied here:
            %   S4 = sqrt( max(S4_ori^2 - S4_corr^2, 0) )
            % 
            % Phase measurement variance:
            %   R_phi = sigma_phi0^2 * F_A(S4)
            %   sigma_phi0^2 = 1 / (2 * CN0 * Tcoh)
            %   F_A = 1 + 0.75 * S4^2            (conservative scaling)
            %
            % Frequency measurement variance (using lag-1 phase autocorrelation):
            %   R_omega = 2 * R_phi * (1 - rho_phi1) / Tcoh^2
            %
            % Outputs:
            %   kfR.S4      corrected S4
            %   kfR.Rphi    phase measurement variance   (rad^2)
            %   kfR.Romega  frequency measurement variance ((rad/s)^2)
            %   kfR.valid

            kfR.valid  = false;
            kfR.S4     = 0;
            kfR.Rphi   = (5 * pi / 180)^2;    % default 5 deg
            kfR.Romega = (2 * pi * 3)^2;       % default 3 Hz


            if ~scintRes.valid, return; end

            % modified in V2
            % Apply S4 thermal-noise correction 
            % ([1] Conker RS, El‐Arini MB, Hegarty CJ, Hsiao T. 
            % Modeling the effects of ionospheric scintillation on 
            % GPS/Satellite‐Based Augmentation System availability.
            % Radio Science 2003;38. https://doi.org/10.1029/2000RS002604.)
            S4maxConkerModel = 0.7;
            S4 = min(sqrt(max(scintRes.S4_ori^2 - scintRes.S4_corr^2, 0)), S4maxConkerModel);
            % keep safe
            if ~isfinite(scintRes.S4_ori),return;end
            kfR.S4 = S4;
            % new -- Carrier to Noise Ratio check
            if ~isfield(scintRes,'CN0dB') || ~isfinite(scintRes.CN0dB) || scintRes.CN0dB <= 0
                return;
            else
                CN0_lin = 10^(scintRes.CN0dB / 10);
            end
            Tcoh    = 1e-3;
            if scintRes.allLong && isfield(settings, 'longCoh_ms')
                Tcoh = settings.longCoh_ms * 1e-3;
            end
            % Equivalent PLL bandwidth.  Prefer explicit KF setting; otherwise
            % use the tracking-loop setting as a practical equivalent Bn.
            Bn = 10;
            S_BW = 15;
            P_BW = 40;
            if isfield(settings, 'pllNoiseBandwidth_stab')
                S_BW = settings.pllNoiseBandwidth_stab;
            end
            if isfield(settings, 'pllNoiseBandwidth_pull')
                P_BW = settings.pllNoiseBandwidth_pull;
            end
            if nargin >= 2 && isstruct(settings)
                if isequal(SM.pf, SM.PF_arr.pf_init)
                    Bn = P_BW;
                elseif isequal(SM.pf, SM.PF_arr.pf_pull)
                    Bn = S_BW;
                elseif isequal(SM.pf, SM.PF_arr.pf_long)
                    Bn = S_BW;
                end
            end
            if nargin >= 2 && isstruct(settings)
                if isfield(settings,'pllNoiseBandwidth_stab') && ~isempty(settings.pllNoiseBandwidth_stab)
                    Bn = settings.pllNoiseBandwidth_stab;
                elseif isfield(settings,'pllNoiseBandwidth') && ~isempty(settings.pllNoiseBandwidth)
                    Bn = settings.pllNoiseBandwidth;
                end
            end
            Bn = max(Bn, eps);
            % New in Version 2
            % see equation 5 in [1].
            denomAmp  = 1 - S4^2;
            denomFade = 1 - 2*S4^2;
            Rphi = Bn * (1 + 1/(2*Tcoh*CN0_lin*denomFade)) / (CN0_lin*denomAmp);

            % old version 1
            % Phase measurement variance with amplitude-scintillation scaling
            % sigma_phi0_sq = 1 / max(2 * CN0_lin * Tcoh, 1e-10);
            % FA   = 1 + 0.75 * min(S4, 0.707)^2;
            % Rphi = sigma_phi0_sq * FA;
            % SNRcoh_phi = CN0lin * kf_phiMeasTcoh;
            % Rphi = max(Rphi, 1/(2*max(SNRcoh_phi,eps)));

            % modified in V2
            % Apply floor (and ceil (new in v2))
            % Floor -----------------------------------------------------
            RphiFloor = (3 * pi / 180)^2;
            if isfield(settings,'KF') && isfield(settings.KF,'RphiFloor_deg')
                RphiFloor = (settings.KF.RphiFloor_deg * pi / 180)^2;
            end
            Rphi = max(Rphi, RphiFloor);
            % Ceil -------------------------------------------------------
            RphiCeil = (60 * pi / 180)^2;
            if nargin >= 2 && isstruct(settings) && isfield(settings,'KF') && ...
                    isstruct(settings.KF) && isfield(settings.KF,'RphiCeil_deg') && ...
                    ~isempty(settings.KF.RphiCeil_deg)
                RphiCeil = (settings.KF.RphiCeil_deg * pi / 180)^2;
            end
            Rphi = min(max(Rphi, RphiFloor), RphiCeil);


            % Frequency measurement variance
            % 2*Rphi_tmp/(settings.intTime^2)
            % Romega = 2 * Rphi * (1 - scintRes.rho_phi1) / (Tcoh^2);
            Romega = 2 * Rphi / (Tcoh^2);
            
            if isfield(settings,'KF') && isfield(settings.KF,'RomegaFloor_Hz')
                RomegaFloor = (2 * pi * settings.KF.RomegaFloor_Hz)^2;
            else
                RomegaFloor = (2 * pi * 3)^2;
            end
            Romega = max(Romega, RomegaFloor);

            kfR.Rphi   = Rphi;
            kfR.Romega = Romega;
            kfR.valid  = true;
        end

        % ------------------------------------------------------------------
        function qJerk = computeKF_qJerk(scintRes, qJerk_old, settings)
            % computeKF_qJerk  Adaptive KF process noise (jerk) estimation.
            %
            % Estimates the dynamic frequency process variance from phi60 and
            % tau0, then smooths with an EWMA (lambda = 0.05):
            %   omega_rms  = phi60 * 2*pi * f_char       f_char = 1/tau0
            %   qJerk_new  = 3 * omega_rms^2 / Tcoh^3
            %   qJerk      = 0.95*qJerk_old + 0.05*qJerk_new

            qJerk = qJerk_old;
            if ~scintRes.valid, return; end

            f_char = 1.0;   % Hz fallback
            if isfinite(scintRes.tau0) && scintRes.tau0 > 1e-4
                f_char = 1 / scintRes.tau0;
            end

            Vproc = (scintRes.phi60 * 2 * pi * f_char)^2;

            Tu = 1e-3;
            if scintRes.allLong && isfield(settings, 'longCoh_ms')
                Tu = settings.longCoh_ms * 1e-3;
            end

            qJerk_new = max(3 * Vproc / max(Tu^3, 1e-12), 0);
            qJerk_new = max(qJerk_new, (2 * pi * 0.1)^2);   % floor

            qJerk = 0.95 * qJerk_old + 0.05 * qJerk_new;
        end

        % ------------------------------------------------------------------
        function [B, A] = designLP6sos(fs, fc)
            % Design a 6th-order Butterworth low-pass filter and return it as
            % 3 cascaded 2nd-order sections (SOS).
            %
            % Returns:
            %   B : (3x3) numerator   coefficients  [b0 b1 b2] per row
            %   A : (3x3) denominator coefficients  [1  a1 a2] per row

            Wn = min(max(2 * fc / fs, 1e-6), 0.9999);
            try
                [z, p, k] = butter(6, Wn, 'low');
                sos = zp2sos(z, p, k);   % returns (3x6): [b0 b1 b2  1 a1 a2]
                B   = sos(:, 1:3);
                A   = sos(:, 4:6);
            catch
                % Fallback: manual bilinear transform (no Signal Processing Toolbox)
                wc   = 2 * pi * fc;
                damp = [sqrt(2 + sqrt(3)), sqrt(2), sqrt(2 - sqrt(3))];
                B = zeros(3, 3);  A = zeros(3, 3);
                for i = 1:3
                    [bz, az] = bilinear([1 0 0], [1 damp(i)*wc wc^2], fs);
                    B(i,:) = bz(:)';  A(i,:) = az(:)';
                end
            end
        end

        % ------------------------------------------------------------------
        function [B, A] = designHP6sos(fs, fc)
            % Design a 6th-order Butterworth high-pass filter (SOS form).
            Wn = min(max(2 * fc / fs, 1e-6), 0.9999);
            try
                [z, p, k] = butter(6, Wn, 'high');
                sos = zp2sos(z, p, k);
                B   = sos(:, 1:3);
                A   = sos(:, 4:6);
            catch
                % Fallback: manual bilinear transform
                wc   = 2 * pi * fc;
                damp = [sqrt(2 + sqrt(3)), sqrt(2), sqrt(2 - sqrt(3))];
                B = zeros(3, 3);  A = zeros(3, 3);
                for i = 1:3
                    [bz, az] = bilinear([1 0 0], [1 damp(i)*wc wc^2], fs);
                    % Normalise so DC gain → 0  (high-pass characteristic)
                    bz = bz * (sum(az) / sum(bz));
                    B(i,:) = bz(:)';  A(i,:) = az(:)';
                end
            end
        end

        % ------------------------------------------------------------------
        function res = emptyResult()
            % Return a valid-=false placeholder result struct.
            res.valid    = false;
            res.S4_ori   = NaN;
            res.S4_corr  = NaN;
            res.phi60    = NaN;
            res.tau0     = NaN;
            res.rho_phi1 = NaN;
            res.nSamples = 0;
            res.allLong  = false;
            res.CN0dB    = NaN;
        end

    end % static methods

end
