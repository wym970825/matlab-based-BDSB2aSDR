function summary=verify_tf_correlation_fidelity(outputRoot)
%VERIFY_TF_CORRELATION_FIDELITY Known-code diagnostics, separate from tracking.
% Frozen detection weights isolate useful-signal distortion from interference
% residual. This is a synthetic diagnostic, not a calibrated S4 experiment.
    root=setupPaths();
    if nargin<1, outputRoot=fullfile(root,'results','upgrade_v020','correlation'); end
    assert(~isfolder(outputRoot),'Fidelity:OutputExists','Use a fresh output folder.');
    mkdir(outputRoot); rows={}; curves={};
    referenceConfig=fullfile(root,'docs','semiphysical_recompute','configs','04_2700_n50dBm.json');
    config=jsondecode(fileread(referenceConfig));
    halfSpacing=config.dllCorrelatorSpacing; % Receiver uses +/- this value.
    for fs=[25e6 30.69e6]
        N=round(fs/1000); Hmax=1000; periods=20;
        n=-Hmax:periods*N+Hmax-1;
        chips=generateB2aPilotCode(11,struct('codeLength',10230));
        % Match the receiver's ceil convention at exact chip boundaries.
        clean=chips(mod(ceil(mod(n,N)*(10.23e6/fs))-1,10230)+1)*exp(1i*.37);
        pulse=zeros(size(n));
        % Deterministic DME-like pairs; peak/threshold ratio 10, spacing 12 us.
        for t0=.00023:1/2700:.02
            for dt=[0 12e-6]
                pulse=pulse+1000*exp(-.5*((n/fs-t0-dt)/1.5e-6).^2);
            end
        end
        j=pulse.*exp(1i*(2*pi*(-450e3)*n/fs+.81));
        for bw=[400e3 600e3]
            for scenario={'quiet','continuous','gated'}
                label=scenario{1}; r=clean; threshold=100;
                if strcmp(label,'continuous'), threshold=.5; end
                if strcmp(label,'gated'), r=clean+j; end
                s=struct('samplingFreq',fs,'dataType','int16','fileType',2, ...
                    'Frontend',struct('mode','tf_v1','TF',struct( ...
                    'stopbandWidthHz',bw,'thresholdAmplitude',threshold)));
                tf=TFBlankerV1(s); t=tf.Config;
                [z,meta]=tf.applyRange(r,0,Hmax,periods*N);
                g=max(t.K-abs(-t.K:t.K),0)/t.K^2;
                w=conv(movmax(double(abs(r)>=threshold),[t.A t.A]),g,'same');
                core=Hmax+(1:periods*N);
                reference=(1-w).*r+w.*conv(r,tf.Notch,'same');
                relativeError=max(abs(z-reference(core)))/max(abs(r));
                assert(relativeError<1e-12,'Fidelity:Reference','Independent branch reference mismatch.');
                useful=(1-w).*clean+w.*conv(clean,tf.Notch,'same');
                base=clean(core); useful=useful(core);
                [metric,curve]=measure(useful,base,N,fs,halfSpacing);
                [totalMetric,~]=measure(z,base,N,fs,halfSpacing);
                [shifted,~]=measure(circshift(useful,1),base,N,fs,halfSpacing);
                assert(abs(shifted.peakSamples-metric.peakSamples-1)<.07, ...
                    'Fidelity:NegativeControl','One-sample shift must be detected.');
                if strcmp(label,'quiet'), assert(isequal(z,base)); end
                metric.fs=fs; metric.bandwidthHz=bw; metric.scenario=label;
                metric.meanWeight=meta.meanWeight; metric.relativeReferenceError=relativeError;
                metric.observedWithResidual=totalMetric; metric.shiftedPeakSamples=shifted.peakSamples;
                rows{end+1}=metric; curves{end+1}=curve; %#ok<AGROW>
            end
        end
    end
    summary=struct('prn',11,'durationMs',20,'oversampling',32, ...
        'configPath',referenceConfig,'dllHalfSpacingChips',halfSpacing, ...
        'scriptHash',frontendHash(fileread([mfilename('fullpath') '.m'])), ...
        'note','Frozen-weight useful component; no receiver loops/noise/S4 truth.', ...
        'cases',{rows});
    fid=fopen(fullfile(outputRoot,'correlation_summary.json'),'w','n','UTF-8');
    cl=onCleanup(@() fclose(fid)); fprintf(fid,'%s\n',jsonencode(summary,'PrettyPrint',true)); clear cl
    save(fullfile(outputRoot,'correlation_curves.mat'),'summary','curves');
    f=figure('Visible','off','Position',[100 100 1100 700]); cl=onCleanup(@() close(f));
    tiledlayout(2,2);
    for k=1:2
        nexttile; hold on;
        for ix=[6*k-5 6*k-3 6*k]
            c=curves{ix}; plot(c.lagChips,c.magnitude,'DisplayName', ...
                sprintf('%s / %g kHz',rows{ix}.scenario,rows{ix}.bandwidthHz/1000));
        end
        xlim([-1 1]); grid on; legend('Location','best');
        title(sprintf('Useful correlation, %.2f MHz',rows{6*k}.fs/1e6)); xlabel('Lag (chips)'); ylabel('Normalized magnitude');
        nexttile; hold on;
        for ix=[6*k-5 6*k-3 6*k]
            c=curves{ix}; plot(c.dllLag,c.dll,'DisplayName', ...
                sprintf('%s / %g kHz',rows{ix}.scenario,rows{ix}.bandwidthHz/1000));
        end
        grid on; legend('Location','best'); xlabel('Lag (chips)'); ylabel('(E-L)/(E+L)');
        title(sprintf('DLL, %.2f-chip total spacing',2*halfSpacing));
    end
    exportgraphics(f,fullfile(outputRoot,'correlation_fidelity.png'),'Resolution',150);
end

function [m,c]=measure(y,reference,N,fs,halfSpacing)
    folded=mean(reshape(y,N,[]),2).'; ref=reference(1:N);
    corr=ifft(fft(folded).*conj(fft(ref)))/N;
    M=32; dense=fftshift(interpft(corr,N*M));
    lag=(-N*M/2:N*M/2-1)/M;
    center=abs(lag)<4;
    selected=lag(center); [~,i]=max(abs(dense(center))); peak=selected(i);
    chips=lag*10.23e6/fs; tau=-.8:.001:.8;
    e=interp1(chips,abs(dense),tau+halfSpacing); l=interp1(chips,abs(dense),tau-halfSpacing);
    dll=(e-l)./max(e+l,eps);
    crossings=find(dll(1:end-1).*dll(2:end)<=0);
    [~,k]=min(abs(tau(crossings))); ix=crossings(k);
    zero=tau(ix)-dll(ix)*(tau(ix+1)-tau(ix))/(dll(ix+1)-dll(ix));
    if ~isfinite(zero), zero=tau(ix); end
    m=struct('peakSamples',peak,'dllZeroChips',zero, ...
        'promptPhaseRad',angle(corr(1)),'promptGainDb',20*log10(abs(corr(1))));
    keep=abs(chips)<=1.5;
    c=struct('lagChips',chips(keep),'magnitude',abs(dense(keep)), ...
        'dllLag',tau,'dll',dll);
end
