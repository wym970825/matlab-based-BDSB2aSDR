function [w,meta]=tf_soft_weights(mask,fs,triangleUs,tailPadSamples,method)
% Centered offline reference. Unit-sum triangle, optional full-coverage guard.
K=round(triangleUs*1e-6*fs/2);
g=[0:K K-1:-1:0]/K; g=g/sum(g);
if method=="hard"
    w=double(mask); future=0;
elseif method=="naive"
    z=fftfilt(g,[double(mask) zeros(1,K)]); w=z(K+1:K+numel(mask)); future=K;
elseif method=="guarded"
    % Guarantee w=1 over detector support expanded by the filter tail/pulse margin.
    expanded=movmax(double(mask),[tailPadSamples+K tailPadSamples+K]);
    z=fftfilt(g,[expanded zeros(1,K)]); w=z(K+1:K+numel(mask));
    future=tailPadSamples+2*K;
else
    error('Unknown weight policy.');
end
w=min(1,max(0,real(w))); w(w<1e-12)=0; w(w>1-1e-12)=1;
meta=struct('triangleSamples',numel(g),'triangleSum',sum(g), ...
    'trianglePeak',max(g),'lookaheadSamples',future,'meanWeight',mean(w), ...
    'weightSupportFraction',mean(w>0),'detectedSamplesFullyFiltered',all(w(mask)>1-1e-10));
end
