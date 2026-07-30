function  arr =  legendre_arr(N)
%LEGENDRE_ARR
% Version: 0.1
% Author: xiaoyeyimier
% Date: 2024/05/03
% Description :
%   generate an N-bit legendre code for generating the secondary code for
%   B2a pilot component.
% Input : 
%   N: sequence length
% ----------------------------------------------------------------------- %
loopMax = N / 2;% loop-end for inner loop

arr = false(N, 1); % initial legendre array

for kk = 0 : (N - 1) % outer loop

    loopCnt = 1;

    if kk == 0, arr(kk + 1) = false; continue; end % k = 0, L(k) = 0;
    
    while loopCnt <= loopMax % for k > 0

        if mod(loopCnt.^2, N) == kk % ind = k + 1, matlab index start from 1
        
            arr(kk + 1) = true; % set high

            break; % return to outer loop
        
        else

            loopCnt = loopCnt + 1; % self add

        end

    end

end

arr = arr * -2 + 1;