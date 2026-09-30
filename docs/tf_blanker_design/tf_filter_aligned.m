function y=tf_filter_aligned(x,f)
% Offline, sample-aligned laboratory reference. Future samples are used.
% This is not a causal streaming API; the production design must expose delay.
if f.kind=="fir"
    v=fftfilt(f.b,[x zeros(1,f.delay)]);
    y=v(f.delay+1:f.delay+numel(x));
else
    y=filter(f.b,f.a,x);
end
end
