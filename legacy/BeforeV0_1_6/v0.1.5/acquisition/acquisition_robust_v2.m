function acqResults = acquisition_robust_v2(longSignal, settings, varargin)
%ACQUISITION_ROBUST_V2 Compatibility wrapper -> acquisition_robust_v2fft
acqResults = acquisition_robust_v2fft(longSignal, settings, varargin{:});
end
