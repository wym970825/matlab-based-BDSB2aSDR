function varargout = phiDetrending(Phi_PRN, sample_rate)
%This function is to detrending the raw 50Hz signal carrier phase
%
%Input:  Phi_PRN, the raw high frequency carrier phase measurements
%           receiver_type, the type of receiver
%           sample_rate, sample rate of the carrier phase measurements, in Hz
%Output: HF_PRN, detrended 50Hz phase, including TOW, detrended phase
%
%% ============================================================
%           By: Kai GUO
%           Contact: kai.guo@nottingham.ac.uk
%           NGI,  the University of Nottingham
%
%           08 Feb 2019
%
%           The input is modified to [TOW, phase_instant]
%           23 Nov 2020
%
%           1. modify the jump repair, a 2-order interp method is involved
%           2. Speed up
%           By: Xiaoyeyimier
%           Contact: xiaoyeyimier@163.com
%           07 Aug 2024

%% ============================================================

if nargin < 2
    sample_rate = 50;
end

%Obtain the carrier phase measurements
phi = Phi_PRN(:, 2);              % Carrier Phase, in cycles

%Extract the TOW
HF_PRN_tow = Phi_PRN(:, 1);

%% Pass the corrected carrier phase measurements through filter
%Define the cut off frequency for Butterworth filter
f_cut = 1;
%Detrend by Butterworh filter
%First stage filter
%numerator of analog filter transfer function
b = [1 0 0];
% denominator of first AJ filter
a = [1 sqrt(2 + sqrt(3) ) * f_cut * 2 * pi (f_cut * 2 * pi ) ^ 2];
%bilinear trasformation from analogic to digital-provides coeffs of equivalent digital filter
[numd1, dend1] =bilinear(b, a, sample_rate);
%Second stage filter
% denominator of second AJ filter
a = [1 sqrt(2) * f_cut * 2 * pi (f_cut * 2 * pi ) ^ 2];
[numd2, dend2] = bilinear(b, a, sample_rate);
%Third stage filter
% denominator of third AJ filter
a = [1 sqrt(2 - sqrt(3) ) * f_cut * 2 * pi (f_cut * 2 * pi ) ^ 2];
[numd3, dend3] = bilinear(b, a, sample_rate);

% [numd, dend] = cascade_filters(numd1, dend1, numd2, dend2, numd3, dend3);

%The start and end time for the data series
WN_overtake = false;
time_diff = diff(HF_PRN_tow);

if nnz(time_diff<0) %Over the gap of Week Number
    WN_update = find((time_diff<0))+1;
    for ii = 1:length(WN_update)
    HF_PRN_tow(WN_update(ii):end) = HF_PRN_tow(WN_update(ii):end) + 604800;
    end
    WN_overtake = true;
end


% new function here
% Detect if there is a gap of nan in the input data
% I 've scaled this step up to an integer range to avoid floating point
% errors. <tesk ok>

PRN_tow_start = HF_PRN_tow(1); % shold be ascend after repair TOW carry
PRN_tow_end = HF_PRN_tow(end);
t_step = round(100/sample_rate); % max sample rate of sep is 100, should change in SDR
time_axis = (round(PRN_tow_start*100): t_step: round(PRN_tow_end*100)).';
index = ismember(time_axis,round(HF_PRN_tow*100));
old_Phi = nan(length(time_axis),1);% Insert nan at the gap
old_Phi(index) = phi;
phi = old_Phi;
time_axis = time_axis/100; % rescale

if WN_overtake
    WN_update = find(time_axis == 0);
end
%Convert from cycles to rad
phi = phi * 2 * pi;

% Initial a vector to put the detrended carrier phase measurements
phi_det_PRN = NaN(length(time_axis), 1);


% Each loop must be a complete arc with no breaks, thus we need to find
% the gaps here :
% arc_l, length of arcs
% arc_s, start index of arcs
[arc_l,arc_s] = find_consecutive_true(~isnan(phi));
% minimum length
BUFLEN = 4 * 60 * sample_rate;

% loop to deal arc
for arc_i = 1:length(arc_l)
    % No need to continue when data is insufficient
    if arc_l(arc_i)<BUFLEN
        continue;
    end
    % index of arc
    arc_ind = arc_s(arc_i) : arc_s(arc_i) + arc_l(arc_i) -1;
    arc_phi = phi(arc_ind);
    % Check if there is jumps in the carrier phase measurements (maybe due to cycle slip)
    [arc_phi] = repair_cycleslip_rawdata(arc_phi); % new function here

    % start loop
    arc_phi = filter(numd1, dend1, arc_phi);
    arc_phi = filter(numd2, dend2, arc_phi);
    arc_phi = filter(numd3, dend3, arc_phi);
    phi_det_PRN(arc_ind) = arc_phi;
end


%Define the output of the function
if WN_overtake %Over the gap of Week Number
    time_axis(WN_update : end) = time_axis(WN_update : end) - 604800;
end

varargout{1} = [time_axis, phi_det_PRN];
if nargout == 2
    varargout{2} = old_Phi;
end

end

