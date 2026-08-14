classdef CarrierKF2 < handle
    % CarrierKF - simple Kalman filter for carrier phase/frequency tracking (1ms tick).
    %
    % State:
    %   x = [phi_err; omega_err; alpha_err]
    %     phi_err   [rad]
    %     omega_err [rad/s]
    %     alpha_err [rad/s^2]
    %
    % Measurements (scalar):
    %   z_phi   = phi_err   + v_phi
    %   z_omega = omega_err + v_omega
    %
    % Metrics:
    %   lastNIS_phi / lastNIS_omega : NIS of last update
    %   rmsNuPhi / rmsNuOmega       : EWMA RMS innovation

    properties
        x double = zeros(3,1);
        P double = eye(3);

        % jerk PSD driving alpha (process noise)
        qJerk double = (2*pi*0.5)^2;

        % --- Metrics ---
        lastNIS_phi double = NaN;
        lastNIS_omega double = NaN;

        rmsNuPhi double = NaN;      % [rad]
        rmsNuOmega double = NaN;    % [rad/s]
        rmsBeta double = 0.98;      % EWMA factor
    end

    methods
        function obj = CarrierKF2(settings)
            if nargin < 1, return; end

            if isfield(settings,'KF') && isstruct(settings.KF)
                if isfield(settings.KF,'qJerk') && ~isempty(settings.KF.qJerk)
                    obj.qJerk = settings.KF.qJerk;
                end
                if isfield(settings.KF,'rmsBeta') && ~isempty(settings.KF.rmsBeta)
                    obj.rmsBeta = settings.KF.rmsBeta;
                end
            end

            % Initial covariance (configurable)
            sigPhi = 30*pi/180;
            sigF   = 50;   % Hz
            sigA   = 10;   % Hz/s

            if isfield(settings,'KF') && isstruct(settings.KF)
                if isfield(settings.KF,'initSigmaPhi_deg'),        sigPhi = settings.KF.initSigmaPhi_deg*pi/180; end
                if isfield(settings.KF,'initSigmaFreq_Hz'),        sigF   = settings.KF.initSigmaFreq_Hz; end
                if isfield(settings.KF,'initSigmaFreqRate_Hzps'),  sigA   = settings.KF.initSigmaFreqRate_Hzps; end
            end

            obj.P = diag([sigPhi^2, (2*pi*sigF)^2, (2*pi*sigA)^2]);
        end

        function reset(obj)
            obj.x = zeros(3,1);
            obj.P = eye(3);

            obj.lastNIS_phi = NaN;
            obj.lastNIS_omega = NaN;
            obj.rmsNuPhi = NaN;
            obj.rmsNuOmega = NaN;
        end

        function predict(obj, dt)
            if ~isfinite(dt) || dt <= 0, return; end

            F = [1, dt, 0.5*dt^2;
                 0,  1,      dt;
                 0,  0,       1];

            q = obj.qJerk;
            Q = q * [dt^5/20, dt^4/8,  dt^3/6;
                     dt^4/8,  dt^3/3,  dt^2/2;
                     dt^3/6,  dt^2/2,  dt];

            obj.x = F * obj.x;
            obj.P = F * obj.P * F.' + Q;

            obj.x(1) = mod(obj.x(1) + pi, 2*pi) - pi;
        end

        function updatePhi(obj, zPhi, Rphi)
            if ~isfinite(zPhi) || ~isfinite(Rphi) || Rphi <= 0, return; end
            H = [1, 0, 0];
            [nis, nu] = obj.scalarUpdate(zPhi, H, Rphi, true);
            obj.lastNIS_phi = nis;
            obj.updateRmsPhi(nu);
        end

        function updateOmega(obj, zOmega, Romega)
            if ~isfinite(zOmega) || ~isfinite(Romega) || Romega <= 0, return; end
            H = [0, 1, 0];
            [nis, nu] = obj.scalarUpdate(zOmega, H, Romega, false);
            obj.lastNIS_omega = nis;
            obj.updateRmsOmega(nu);
        end

        function deltaHz = feedback(obj, gain, maxCorrHz)
            if nargin < 2 || isempty(gain), gain = 1.0; end
            if nargin < 3 || isempty(maxCorrHz), maxCorrHz = inf; end
            if ~isfinite(gain), gain = 1.0; end
            gain = max(min(gain,1.0), 0.0);

            omegaCorr = gain * obj.x(2);      % rad/s
            deltaHz   = omegaCorr / (2*pi);   % Hz

            if isfinite(maxCorrHz)
                deltaHz = max(min(deltaHz, maxCorrHz), -maxCorrHz);
                omegaCorr = 2*pi*deltaHz;
            end

            obj.x(2) = obj.x(2) - omegaCorr;  % reduce residual
        end

        function m = getMetrics(obj)
            m = struct();
            m.NIS_phi = obj.lastNIS_phi;
            m.NIS_omega = obj.lastNIS_omega;
            m.RMS_nu_phi_rad = obj.rmsNuPhi;
            m.RMS_nu_omega_rads = obj.rmsNuOmega;
        end
    end

    methods (Access = private)
        function [nis, nu] = scalarUpdate(obj, z, H, R, wrapPhase)
            nis = NaN; nu = NaN;

            H = H(:).';
            zhat = H * obj.x;
            nu = z - zhat;
            if wrapPhase
                nu = mod(nu + pi, 2*pi) - pi;
            end

            S = H * obj.P * H.' + R;
            if ~isfinite(S) || S <= 0, return; end

            nis = (nu^2) / S;

            K = (obj.P * H.') / S;
            obj.x = obj.x + K * nu;
            obj.P = obj.P - K * H * obj.P;

            obj.x(1) = mod(obj.x(1) + pi, 2*pi) - pi;
        end

        function updateRmsPhi(obj, nu)
            if ~isfinite(nu), return; end
            if ~isfinite(obj.rmsNuPhi)
                obj.rmsNuPhi = abs(nu);
            else
                b = obj.rmsBeta;
                obj.rmsNuPhi = sqrt(b*(obj.rmsNuPhi^2) + (1-b)*(nu^2));
            end
        end

        function updateRmsOmega(obj, nu)
            if ~isfinite(nu), return; end
            if ~isfinite(obj.rmsNuOmega)
                obj.rmsNuOmega = abs(nu);
            else
                b = obj.rmsBeta;
                obj.rmsNuOmega = sqrt(b*(obj.rmsNuOmega^2) + (1-b)*(nu^2));
            end
        end
    end
end
