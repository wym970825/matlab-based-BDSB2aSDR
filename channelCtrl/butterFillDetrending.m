function S_out= butterFillDetrending(S_in, f_cutoff, filter_type)
%% Butterworth filter to detrend amplitude and phase measurements
% 
%  Input:
%           S_in: the input signal need to be filtered 
%           f_cutoff: the cutoff frequency of the filter, 0.1Hz
%           filter_type: 'high' pass or 'low' pass filter
%
%  Output: 
%           S_out: the detrended signal 
%
%  Note: This is a 6 order filer
%
%%        By: Kai GUO
%           kai.guo@nottingham.ac.uk
%           NGI,  the University of Nottingham
%
%           8 Mar 2018
%% ========================================================

filter_order = 2;
[B, A] = butter(filter_order, f_cutoff, filter_type);     %Create a Butterworth filter
S_out1 = filter(B, A, S_in);         %Apply the filter to the sequence
S_out2 = filter(B, A, S_out1);
S_out = filter(B, A, S_out2);

