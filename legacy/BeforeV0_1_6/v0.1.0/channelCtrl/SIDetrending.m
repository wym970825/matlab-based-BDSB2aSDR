function [SI_det_PRN] = SIDetrending(SI_PRN_array, nor_interval)
%This function is to detrending the raw 50Hz signal intensity 
% Input: 
%           SI_PRN_array, the raw 50Hz intensity measurements
%           nor_interval, the interval for the normalization period
%
%Output: 
%           HF_PRN, detrended 50Hz intensity, including TOW, detrended intensity 
%           SI_PRN, raw signal intensity measurements
%
%% ============================================================
%           By: Kai GUO
%           Contact: kai.guo@nottingham.ac.uk
%           NGI,  the University of Nottingham
%
%           08 Feb 2019
%% ============================================================

%Extract the measurements
HF_PRN_tow_raw = SI_PRN_array(:, 1); % time

SI = SI_PRN_array(:, 2);  % signal power

IQRate = 1 / mean(diff(HF_PRN_tow_raw)); % auto calculate frequency of input data

%% Signal intensity measurement detrending
%Pass the signal intensity measurement to low pass fileter to obtain the trend of the signal intensity
% Define the filter pars 
f_cut_SI = 0.115;

f_cut_SI = f_cut_SI / IQRate * 2; % define cut off frequency for Butterworth filter

filter_type_SI = 'low';

SI_trend = butterFillDetrending(SI, f_cut_SI, filter_type_SI);      

%Initial the vector to storage the detrended signal intensity measurements
SI_det_PRN = NaN(length(SI), 1);

%The start and end time for the data series
HF_PRN_tow = HF_PRN_tow_raw;

if HF_PRN_tow(1) > HF_PRN_tow(end) % if there is a carry

    new_WN_ind = find(diff(HF_PRN_tow) < 0) + 1; % find the carry index  
    
    HF_PRN_tow(new_WN_ind:end) = HF_PRN_tow(new_WN_ind:end) + 604800; % cancel carry

end

PRN_tow_start = HF_PRN_tow(1); % start time
PRN_tow_end = HF_PRN_tow(end); % end time

%Normalizing the raw signal intensity by the averaged trend in the last minute
current_tow = PRN_tow_start;

while current_tow <= PRN_tow_end

    %Define the edges of the current interval
    interval_left = current_tow;
    
    interval_right = current_tow + nor_interval;
    
    %Search the measurements
    current_interval_index = (HF_PRN_tow >= interval_left & HF_PRN_tow < interval_right);
    
    %Check if there is gap in the high frequency measurements
    if sum(current_interval_index) < nor_interval * IQRate
        %Gaps found in the high frequency measurements
        %figure;
        %plot(HF_PRN_tow(current_interval_index), SI_PRN(current_interval_index), 'r+')
    end
    
    %The raw measurements for the current interval
    SI_cur_interval = SI(current_interval_index); 
    
    %The average signal power in this interval 
    %SI_trend_cur_interval_avgs =  mean(SI_cur_interval); 
    
    %Extract the intensity trend within the interval - for Butterworth filter
    SI_trend_cur_interval = SI_trend(current_interval_index);
    SI_trend_cur_interval_avgs = mean(SI_trend_cur_interval);
    
    %Normalizing the raw intensity by averaged signal intensity trend
    SI_nor_cur_interval = SI_cur_interval / SI_trend_cur_interval_avgs;  
    SI_det_PRN(current_interval_index) = SI_nor_cur_interval;
    
    %Update the tow
    current_tow = current_tow + nor_interval;
end

%% Define the function output
SI_det_PRN = [HF_PRN_tow_raw, SI_det_PRN];

