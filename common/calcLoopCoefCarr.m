function [pf_pullin, pf_stable, pf_trans] = calcLoopCoefCarr(settings)
%Function finds loop coefficients. The coefficients are used then in PLL-s
%and DLL-s.
%
%[tau1, tau2] = calcLoopCoef(LBW, zeta, k)
%
%   Inputs:
%       LBW           - Loop noise bandwidth
%       zeta          - Damping ratio
%       k             - Loop gain
%
%   Outputs:
%       tau1, tau2   - Loop filter coefficients 
 
%--------------------------------------------------------------------------
%                           SoftGNSS v3.0
% 
% Copyright (C) Darius Plausinaitis and Dennis M. Akos
% Written by Darius Plausinaitis and Dennis M. Akos
%--------------------------------------------------------------------------
%This program is free software; you can redistribute it and/or
%modify it under the terms of the GNU General Public License
%as published by the Free Software Foundation; either version 2
%of the License, or (at your option) any later version.
%
%This program is distributed in the hope that it will be useful,
%but WITHOUT ANY WARRANTY; without even the implied warranty of
%MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%GNU General Public License for more details.
%
%You should have received a copy of the GNU General Public License
%along with this program; if not, write to the Free Software
%Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-130aa1,
%USA.
%--------------------------------------------------------------------------

%CVS record:
%$Id: calcLoopCoef.m,v 1.1.2.2 2006/08/14 11:38:22 dpl Exp $
% Loop noise bandwidth

Bw_stable = settings.pllNoiseBandwidth;
Bw_init = settings.pllNoiseBandwidth_init;
% Summation interval
initCoh = settings.intTime;
if isfield(settings,'longCoh_ms')
    LongCoh = settings.longCoh_ms/1e3;
else
    LongCoh = settings.intTime;
end
%% For a second order PLL
if settings.pllOrder == 2

pf_stable = design_order2(Bw_stable,LongCoh);

pf_pullin = design_order2(Bw_init,initCoh);

if nargout == 3
    pf_trans = design_order2(Bw_stable,initCoh);
end

%% For a third order PLL
elseif settings.pllOrder == 3

pf_stable = design_order3(Bw_stable,LongCoh);

pf_pullin = design_order3(Bw_init,initCoh);

if nargout == 3
    pf_trans = design_order3(Bw_stable,initCoh);
end

end
end

%-------------------------------------------------------------------------%
% designe second order loop filter
function pf = design_order2(Bw,intTime)

% loop constant coefficients
a2 = 1.414;
% calculate natural frequency
Wn = Bw / 0.53;

pf2 = Wn^2 * intTime;
pf1 = a2 * Wn;

pf = [pf1;pf2];

end
% designe 3 order loop filter
function pf = design_order3(Bw,intTime)

% loop constant coefficients
a3 = 1.1;
b3 = 2.4;

% Solve natural frequency
Wn = Bw / 0.7845;
% solve for [pf3,pf2,pf1]
pf3 = Wn^3 * intTime^2;
pf2 = a3 * Wn^2 * intTime;
pf1 = b3 * Wn;

pf = [pf1;pf2;pf3];

end
