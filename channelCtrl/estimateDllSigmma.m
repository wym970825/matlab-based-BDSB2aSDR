function [sigmma] = estimateDllSigmma(D, B_fe, T_code, T_coh, B_l,  CN_0)
%ESTIMATEDLLSIGMMA 
% input: 
%   D : The distance between two correlators, this value is generally 0.5
%   B_fe : bandwidth of front-end
%   T_code : period of the psudo-range code
%   T_coh : coherent integral time
%   B_l : noise bandwidth of lpf
%   CN_0 : carrier to noise ratio (in fraction)
% output:
%   sigmma = sigma_DLL
range1 = pi / (B_fe * T_code);

range2 = 1 / (B_fe * T_code);

if D <= range2

    sigmma = sqrt((B_l / 2 ./ CN_0) .* D .* (1 + (2 / (2 - D) / T_coh ./ CN_0)));

elseif D > range2 && D < range1

    sigmma = sqrt((B_l / 2 ./ CN_0) .* (range2 + (B_fe * T_code / (pi - 1)) * (D - range2) .^ 2) .* (1 + (2 / (2 - D) / T_coh ./ CN_0)));

elseif D >= range1

    sigmma = sqrt((B_l / 2 ./ CN_0) .* range2 .* (1 + (1 / T_coh ./ CN_0)));

end

