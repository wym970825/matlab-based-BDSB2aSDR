classdef CarrierKF < handle
    % CarrierKF - simple 1ms Kalman filter for carrier phase/frequency tracking.
    %
    % State (continuous meaning):
    %   x = [phi_err; omega_err; alpha_err]
    %     phi_err   [rad]      residual phase error (incoming - local)
    %     omega_err [rad/s]    residual angular frequency error
    %     alpha_err [rad/s^2]  residual angular frequency rate
    %
    % Discrete-time model (constant acceleration, driven by white jerk):
    %   phi_{k+1}   = phi_k + omega_k*dt + 0.5*alpha_k*dt^2
    %   omega_{k+1} = omega_k + alpha_k*dt
    %   alpha_{k+1} = alpha_k + w_k
    %
    % Measurements (scalar updates):
    %   z_phi    = phi_err   + v_phi
    %   z_omega  = omega_err + v_omega
    %
    % This class is intentionally lightweight for integration into an existing PLL.

    properties
        x double = zeros(3,1);      % state
        P double = eye(3);          % covariance
        qJerk double = (2*pi*0.5)^2; % jerk PSD [rad^2/s^5]
    end

    methods
        function obj = CarrierKF(settings)
            % Constructor with optional settings.KF fields
            if nargin < 1
                return;
            end
            if isfield(settings,'KF') && isstruct(settings.KF)
                if isfield(settings.KF,'qJerk') && ~isempty(settings.KF.qJerk)
                    obj.qJerk = settings.KF.qJerk;
                end
            end

            % Initial covariance (configurable)
            sigPhi = 30*pi/180;   % 30 deg
            sigF   = 50;          % 50 Hz
            sigA   = 10;          % 10 Hz/s
            if isfield(settings,'KF') && isstruct(settings.KF)
                if isfield(settings.KF,'initSigmaPhi_deg'), sigPhi = settings.KF.initSigmaPhi_deg*pi/180; end
                if isfield(settings.KF,'initSigmaFreq_Hz'),  sigF   = settings.KF.initSigmaFreq_Hz; end
                if isfield(settings.KF,'initSigmaFreqRate_Hzps'), sigA = settings.KF.initSigmaFreqRate_Hzps; end
            end
            sigOmega = 2*pi*sigF;
            sigAlpha = 2*pi*sigA;
            obj.P = diag([sigPhi^2, sigOmega^2, sigAlpha^2]);
        end

        function reset(obj)
            obj.x = zeros(3,1);
            obj.P = eye(3);
        end

        function predict(obj, dt)
            % Predict step with variable dt
            if ~isfinite(dt) || dt <= 0
                return;
            end

            F = [1, dt, 0.5*dt^2;
                 0,  1,      dt;
                 0,  0,       1];

            % Discrete process noise for white jerk driving alpha (phi-omega-alpha)
            q = obj.qJerk;
            Q = q * [dt^5/20, dt^4/8,  dt^3/6;
                     dt^4/8,  dt^3/3,  dt^2/2;
                     dt^3/6,  dt^2/2,  dt];

            obj.x = F * obj.x;
            obj.P = F * obj.P * F.' + Q;

            % keep phi in [-pi, pi) to avoid numeric growth (optional)
            obj.x(1) = mod(obj.x(1) + pi, 2*pi) - pi;
        end

        function updatePhi(obj, zPhi, Rphi)
            % Scalar measurement update for phase
            if ~isfinite(zPhi) || ~isfinite(Rphi) || Rphi <= 0
                return;
            end
            H = [1, 0, 0];
            obj.scalarUpdate(zPhi, H, Rphi, true);
        end

        function updateOmega(obj, zOmega, Romega)
            % Scalar measurement update for omega
            if ~isfinite(zOmega) || ~isfinite(Romega) || Romega <= 0
                return;
            end
            H = [0, 1, 0];
            obj.scalarUpdate(zOmega, H, Romega, false);
        end

        function deltaHz = feedback(obj, gain, maxCorrHz)
            % feedback - return a frequency correction in Hz based on current omega_err
            % and reduce internal omega_err by the applied amount.
            if nargin < 2 || isempty(gain), gain = 1.0; end
            if nargin < 3 || isempty(maxCorrHz), maxCorrHz = inf; end
            if ~isfinite(gain), gain = 1.0; end
            gain = max(min(gain, 1.0), 0.0);

            omegaCorr = gain * obj.x(2); % rad/s
            deltaHz = omegaCorr / (2*pi);

            if isfinite(maxCorrHz)
                deltaHz = max(min(deltaHz, maxCorrHz), -maxCorrHz);
                omegaCorr = 2*pi*deltaHz;
            end

            % Apply feedback to state (reduce residual)
            obj.x(2) = obj.x(2) - omegaCorr;
        end
    end

    methods (Access = private)
        function scalarUpdate(obj, z, H, R, wrapPhase)
            % scalarUpdate - generic scalar KF update
            % wrapPhase: if true, wrap innovation to [-pi,pi)

            H = H(:).';
            % innovation
            zhat = H * obj.x;
            nu = z - zhat;
            if wrapPhase
                nu = mod(nu + pi, 2*pi) - pi;
            end

            S = H * obj.P * H.' + R;
            if ~isfinite(S) || S <= 0
                return;
            end

            K = (obj.P * H.') / S;
            obj.x = obj.x + K * nu;
            obj.P = obj.P - K * H * obj.P;

            % Wrap phi
            obj.x(1) = mod(obj.x(1) + pi, 2*pi) - pi;
        end
    end
end
