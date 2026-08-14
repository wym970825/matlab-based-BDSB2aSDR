function b = IF_notch_FIR(fs,f2,fc,N)
% xiaoyeyimier 4/14/2024
% design a fir notch based on
% https://ww2.mathworks.cn/help/dsp/ug/complex-bandpass-filter-design.html
% fs : sampling frequency
% f2 : stop band
% fc : center frequency
% N : FIR order
% Normalized frequency (split at Nyquist frequency fs/2)
f2_normalized = f2 / (fs / 2);
fc_normalized = fc / (fs / 2);
% Design a highpass fir
b = fir1(N, f2_normalized, 'high');
% Frequency rotation
coeff = exp(1j * fc_normalized * pi * (0 : length(b) - 1));
% Return coeff of fir
b = b .* coeff;
end