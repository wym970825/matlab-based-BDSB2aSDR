classdef TFBlankerV1 < handle
%TFBLANKERV1 Deterministic finite-neighborhood complex FIR pulse mitigation.
% Indices are zero-based physical complex-sample indices. No PRN/loop state.
    properties (SetAccess=private)
        Config
        Bandpass
        Notch
        Triangle
        Info
    end
    properties (Access=private)
        CachedFftLength = 0
        BandpassSpectrum
    end
    methods
        function obj = TFBlankerV1(settings)
            settings = resolveFrontendSettings(settings);
            assert(strcmp(settings.Frontend.mode,'tf_v1'),'Frontend:InvalidMode','TF v1 mode required.');
            t = settings.Frontend.TF; fs = settings.samplingFreq;
            low = fir1(t.effectiveTaps-1,(t.stopbandWidthHz/2+t.transitionEachSideHz/2)/(fs/2), ...
                kaiser(t.effectiveTaps,t.kaiserBeta));
            obj.Config = t;
            obj.Bandpass = low.*exp(1i*2*pi*t.centerHz/fs*(-t.D:t.D));
            obj.Notch = -obj.Bandpass; obj.Notch(t.D+1) = obj.Notch(t.D+1)+1;
            obj.Triangle = max(t.K-abs(-t.K:t.K),0)/t.K^2;
            obj.Info = settings.Frontend;
            obj.Info.coefficientHash = frontendHash(struct('real',real(obj.Notch),'imag',imag(obj.Notch)));
            frequencies = linspace(t.centerHz-t.stopbandWidthHz/2,t.centerHz+t.stopbandWidthHz/2,4001);
            response = freqz(obj.Notch,1,2*pi*frequencies/fs);
            obj.Info.worstStopbandDbOnGrid = 20*log10(max(abs(response)));
            obj.Info.notchReal = real(obj.Notch); obj.Info.notchImag = imag(obj.Notch);
        end

        function [z,meta] = applyRange(obj,raw,rawStartAbs,coreStartAbs,coreLength)
            t = obj.Config; raw = double(raw(:).');
            assert(all(isfinite(raw)),'Frontend:InvalidInput','Nonfinite IF samples are invalid.');
            assert(all(isfinite([rawStartAbs coreStartAbs coreLength])) && ...
                all([rawStartAbs coreStartAbs coreLength]>=0) && ...
                all(mod([rawStartAbs coreStartAbs coreLength],1)==0), ...
                'Frontend:InvalidRange','Sample indices and counts must be nonnegative integers.');
            p = coreStartAbs-rawStartAbs+(1:coreLength);
            assert(isempty(p) || (p(1)>=1 && p(end)<=numel(raw)), ...
                'Frontend:MissingCore','Core samples must exist in the raw input.');
            m = abs(raw)>=t.effectiveThresholdAmplitude;
            w = zeros(size(raw));
            if any(m)
                % A zero-padded linear convolution for the FIR. Cache only
                % coefficient spectra (never signal/history/weights). Large
                % probe blocks use overlap-add to bound temporary memory.
                fftLength=2^nextpow2(numel(raw)+t.effectiveTaps-1);
                useFullFft=fftLength<=2^20;
                if useFullFft && obj.CachedFftLength~=fftLength
                    obj.BandpassSpectrum=fft(obj.Bandpass,fftLength);
                    obj.CachedFftLength=fftLength;
                end
                expanded = movmax(double(m),[t.A t.A]);
                % g has zero endpoints and equals two length-K box kernels.
                % Two causal sliding sums implement the same centered linear
                % convolution in O(N), including zero extension at boundaries.
                v=movsum([expanded zeros(1,t.K-1)],[t.K-1 0]);
                v=movsum(v,[t.K-1 0])/t.K^2;
                w = v(t.K:t.K+numel(raw)-1);
                assert(min(w)>-1e-10 && max(w)<1+1e-10,'Frontend:BadWeights','Weights exceed rounding tolerance.');
                w = min(1,max(0,w)); w(w<1e-12)=0; w(w>1-1e-12)=1;
            end
            valid = p>t.H & p<=numel(raw)-t.H;
            z = raw(p); weights = w(p); use = valid & weights>0;
            if any(use)
                if useFullFft
                    q=ifft(fft(raw,fftLength).*obj.BandpassSpectrum);
                else
                    q = fftfilt(obj.Bandpass,[raw zeros(1,t.D)]);
                end
                z(use) = z(use)-weights(use).*q(p(use)+t.D);
            end
            weights(~valid) = 0; % Actual applied weights, raw boundary bypass.
            meta = struct('logicalStartAbs',coreStartAbs,'logicalCount',coreLength, ...
                'valid',valid,'validCount',nnz(valid),'boundaryFlag',any(~valid), ...
                'detectorDuty',mean(m(p)),'meanWeight',mean(weights), ...
                'meanWeightSquared',mean(weights.^2),'weightSupportFraction',mean(weights>0));
        end
    end
end
