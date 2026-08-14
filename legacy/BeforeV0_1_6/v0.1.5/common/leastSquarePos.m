function [pos,el, az, dop, residual] = leastSquarePos(satpos,obs,settings,weights)
%Function calculates the Least Square Solution (optional WLS).
%
%[pos, el, az, dop] = leastSquarePos(satpos, obs, settings);
%[pos, el, az, dop, residual] = leastSquarePos(satpos, obs, settings, weights);
%
%   Inputs:
%       satpos      - Satellites positions (in ECEF system: [X; Y; Z;] -
%                   one column per satellite)
%       obs         - Observations - the pseudorange measurements to each
%                   satellite corrected by SV clock error
%       settings    - receiver settings
%       weights     - optional 1xN positive observation weights (default 1).
%                   Built by lsObservationWeights when elev/C/N0 WLS is on.
%
%   Outputs:
%       pos         - receiver position and receiver clock error
%                   (in ECEF system: [X, Y, Z, dt])
%       el          - Satellites elevation angles (degrees)
%       az          - Satellites azimuth angles (degrees)
%       dop         - Dilutions Of Precision ([GDOP PDOP HDOP VDOP TDOP])
%       residual    - post-fit pseudorange residual omc (m), one per SV

%--------------------------------------------------------------------------
%                           SoftGNSS v3.0
%--------------------------------------------------------------------------
%Based on Kai Borre
%Copyright (c) by Kai Borre
%Updated by Darius Plausinaitis, Peter Rinder and Nicolaj Bertelsen
% Extended: optional weighted LS (elev / C/N0)
%==========================================================================

nmbOfIterations = 10;

dtr     = pi/180;
pos     = zeros(4, 1);
X       = satpos;
nmbOfSatellites = size(satpos, 2);

if nargin < 4 || isempty(weights)
    weights = ones(1, nmbOfSatellites);
else
    weights = weights(:).';
    if numel(weights) ~= nmbOfSatellites
        error('leastSquarePos:WeightSize', ...
            'weights length (%d) must match number of satellites (%d)', ...
            numel(weights), nmbOfSatellites);
    end
    weights(~isfinite(weights) | weights <= 0) = 1;
end
% sqrt weights for left-multiplying design (equiv. to W = diag(w))
sw = sqrt(weights(:));

A       = zeros(nmbOfSatellites, 4);
omc     = zeros(nmbOfSatellites, 1);
az      = zeros(1, nmbOfSatellites);
el      = az;

for iter = 1:nmbOfIterations

    for i = 1:nmbOfSatellites
        if iter == 1
            Rot_X = X(:, i);
            trop = 2;
        else
            rho2 = (X(1, i) - pos(1))^2 + (X(2, i) - pos(2))^2 + ...
                   (X(3, i) - pos(3))^2;
            traveltime = sqrt(rho2) / settings.c ;

            Rot_X = e_r_corr(traveltime, X(:, i));

            [az(i), el(i), ~] = topocent(pos(1:3, :), Rot_X - pos(1:3, :));

            if (settings.useTropCorr == 1)
                trop = tropo(sin(el(i) * dtr), ...
                             0.0, 1013.0, 293.0, 50.0, 0.0, 0.0, 0.0);
            else
                trop = 0;
            end
        end

        omc(i) = ( obs(i) - norm(Rot_X - pos(1:3), 'fro') - pos(4) - trop );

        A(i, :) =  [ (-(Rot_X(1) - pos(1))) / norm(Rot_X - pos(1:3), 'fro') ...
                     (-(Rot_X(2) - pos(2))) / norm(Rot_X - pos(1:3), 'fro') ...
                     (-(Rot_X(3) - pos(3))) / norm(Rot_X - pos(1:3), 'fro') ...
                     1 ];
    end

    if rank(A) ~= 4
        pos     = zeros(1, 4);
        dop     = inf(1, 5);
        residual = omc(:);
        fprintf('Cannot get a converged solotion! \n');
        return
    end

    % Weighted LS: (W^{1/2} A) x = W^{1/2} omc
    Aw = bsxfun(@times, A, sw);
    omcw = omc .* sw;
    x = Aw \ omcw;

    pos = pos + x;

end

pos = pos';
if nargout >= 5
    residual = omc(:);  % unweighted metres (RAIM gates stay in metres)
else
    residual = [];
end

if nargout >= 4
    dop     = zeros(1, 5);
    % Formal DOP from unweighted geometry (standard GDOP definition)
    Q       = inv(A'*A);

    dop(1)  = sqrt(trace(Q));
    dop(2)  = sqrt(Q(1,1) + Q(2,2) + Q(3,3));
    dop(3)  = sqrt(Q(1,1) + Q(2,2));
    dop(4)  = sqrt(Q(3,3));
    dop(5)  = sqrt(Q(4,4));
end
end
