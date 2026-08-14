
classdef CarrierKF2 < handle
    % IAKF-based Carrier Tracking Kalman Filter

    properties
        x; P;
        F; Q; H;
        R; Rphi; Romega;

        alpha = 0.95;

        Rphi_min; Rphi_max;
        Romega_min; Romega_max;

        CN0_min_dB = 25;
    end

    methods
        function obj = CarrierKF2(settings)
            T = settings.intTime;

            obj.F = [1 T 0.5*T^2;
                     0 1 T;
                     0 0 1];

            obj.H = [1 0 0;
                     0 1 0];

            q = settings.kf_qJerk;
            obj.Q = q * [T^5/20 T^4/8 T^3/6;
                         T^4/8  T^3/3 T^2/2;
                         T^3/6  T^2/2 T];

            obj.x = zeros(3,1);
            obj.P = eye(3);

            obj.Rphi_min   = (1*pi/180)^2;
            obj.Rphi_max   = (40*pi/180)^2;
            obj.Romega_min = (1)^2;
            obj.Romega_max = (200)^2;

            obj.R = diag([obj.Rphi_min obj.Romega_min]);
        end

        function predict(obj)
            obj.x = obj.F * obj.x;
            obj.P = obj.F * obj.P * obj.F' + obj.Q;
        end

        function update(obj, z, CN0_dB, Tcoh)
            z_pred = obj.H * obj.x;
            nu = z - z_pred;

            nu(1) = atan2(sin(nu(1)), cos(nu(1)));

            nu_phi = nu(1);
            nu_omega = nu(2);

            CN0 = 10^(CN0_dB/10);
            Rphi_th = 1/(2*CN0*Tcoh);
            Romega_th = 2*Rphi_th/(Tcoh^2);

            Rphi_est = nu_phi^2;
            Romega_est = nu_omega^2;

            obj.Rphi = obj.alpha * obj.R(1,1) + (1-obj.alpha)*Rphi_est;
            obj.Romega = obj.alpha * obj.R(2,2) + (1-obj.alpha)*Romega_est;

            obj.Rphi = max(obj.Rphi, Rphi_th);
            obj.Romega = max(obj.Romega, Romega_th);

            if CN0_dB < obj.CN0_min_dB
                obj.Rphi = obj.Rphi_max;
                obj.Romega = obj.Romega_max;
            end

            obj.Rphi = min(max(obj.Rphi, obj.Rphi_min), obj.Rphi_max);
            obj.Romega = min(max(obj.Romega, obj.Romega_min), obj.Romega_max);

            obj.R = diag([obj.Rphi obj.Romega]);

            S = obj.H * obj.P * obj.H' + obj.R;
            K = obj.P * obj.H' / S;

            obj.x = obj.x + K * nu;
            obj.P = (eye(3) - K * obj.H) * obj.P;
        end
    end
end
