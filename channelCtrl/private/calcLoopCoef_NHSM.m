function [pf] = calcLoopCoef_NHSM(order, IntT, BW)
%Function finds loop coefficients. The coefficients are used then in PLL-s
%and DLL-s.
IntT = IntT/1e3;
%% For a second order PLL
if order == 2
    % loop constant coefficients
    a2 = 1.414;
    % calculate natural frequency
    Wn = BW / 0.53;
    pf2 = Wn^2 * IntT;
    pf1 = a2 * Wn;
    pf = [pf1;pf2];
elseif order == 3 % For a third order PLL
    % loop constant coefficients
    a3 = 1.1;
    b3 = 2.4;
    % Solve natural frequency
    Wn = BW / 0.7845;
    % solve for [pf3,pf2,pf1]
    pf3 = Wn^3 * IntT^2;
    pf2 = a3 * Wn^2 * IntT;
    pf1 = b3 * Wn;
    pf = [pf1;pf2;pf3];
end

