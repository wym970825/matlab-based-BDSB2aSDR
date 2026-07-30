function [weilCode] = GenWeil(prn)
%GENWEIL
% Version: 0.1
% Author: xiaoyeyimier
% Date: 2024/05/03
% Description :
%   generating the secondary code for B2a pilot component.
% Input:
%   prn: SVID for beidou B2a
% Output:
%   weilCode:  the secondary code for B2a pilot component.
% ----------------------------------------------------------------------- %
%   w: Phase differences
%   p: Intercept position
w_arr = [123,  55,  40, 139,  31, 175, 350, 450, 478,   8,...
  73,  97, 213, 407, 476,   4,  15,  47, 163, 280,...
 322, 353, 375, 510, 332,   7,  13,  16,  18,  25,...
  50,  81, 118, 127, 132, 134, 164, 177, 208, 249,...
 276, 349, 439, 477, 498,  88, 155, 330,   3,  21,...
  84, 111, 128, 153, 197, 199, 214, 256, 265, 291,...
 324, 326, 340]; % phase difference

p_arr = [ 138,  570,  351,   77,  885,  247,  413,  180,    3,   26,...
   17,  172,   30, 1008,  646,  158,  170,   99,   53,  179,...
  925,  114,   10,  584,   60,    3,  684,  263,  545,   22,...
  546,  190,  303,  234,   38,  822,   57,  668,  697,   93,...
   18,   66,  318,  133,   98,   70,  132,   26,  354,   58,...
   41,  182,  944,  205,   23,    1,  792,  641,   83,    7,...
  111,   96,   92]; % Intercept position

if prn > 0 && prn < 63

    w = w_arr(prn);

    p = p_arr(prn);

else

    warning('Invalid satellite prn using default value prn = 1');

    w = w_arr(1);

    p = p_arr(1);

end

Wcode_Len = 100; % Define weil code length

Lcode_Len = 1021;% define legendre code length, for every B2a pilot code N = 1021

Lcode_1 = legendre_arr(Lcode_Len); % generate Legendre code

Lcode_2 = Lcode_1([(w + 1 : Lcode_Len), (1 : w)]); % generate phase-shifted Legendre code

weilCode = Lcode_1 .* Lcode_2;

if p <= Lcode_Len - Wcode_Len

    weilCode = weilCode(p : (p + Wcode_Len -1));

else

    weilCode = weilCode([p : Lcode_Len, 1 : (Wcode_Len - Lcode_Len + p - 1)]); % circular intercept

end

% degug

% start24 = zeros(1,8);
% 
% end24 = zeros(1,8);
% 
% for ii = 1 : 8 
% 
%     startInd = (3 * (ii-1) + 1) : 3 * ii;
% 
%     endInd = ((3 * (ii-1) + 1) : 3 * ii) + Wcode_Len -24;
% 
%     start_cur = weilCode(startInd);
% 
%     start24(ii) = sum(1 * (start_cur == -1) .* [4; 2; 1]);
% 
%     end_cur = weilCode(endInd);
% 
%     end24(ii) = sum(1 * (end_cur == -1) .* [4; 2; 1]);
% end
% 
% disp(start24);
% disp(end24);

end