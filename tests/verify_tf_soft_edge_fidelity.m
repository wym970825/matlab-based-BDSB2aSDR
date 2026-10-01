function summary=verify_tf_soft_edge_fidelity(outputRoot)
%VERIFY_TF_SOFT_EDGE_FIDELITY Separate useful-code loss from DME residual.
% Synthetic frozen weights, no noise/receiver loops/truth-calibrated S4.
    root=setupPaths(); assert(~isfolder(outputRoot)); mkdir(outputRoot);
    cfg=jsondecode(fileread(fullfile(root,'docs','semiphysical_recompute','configs','04_2700_n50dBm.json')));
    fs=cfg.samplingFreq; N=round(fs/1000); periods=20; halo=1000;
    n=-halo:periods*N+halo-1; core=halo+(1:periods*N);
    chips=generateB2aPilotCode(11,struct('codeLength',10230));
    clean=chips(mod(ceil(mod(n,N)*10.23e6/fs)-1,10230)+1)*exp(1i*.37);
    threshold=cfg.PB_settings.Th_static_tracking; envelope=zeros(size(n));
    for t0=.00023:1/2700:.02
        for dt=[0 12e-6]
            envelope=envelope+10*threshold*exp(-.5*((n/fs-t0-dt)/1.5e-6).^2);
        end
    end
    interference=envelope.*exp(1i*(2*pi*(-450e3)*n/fs+.81));
    r=clean+interference; rows={}; curves={};
    for span=[3 6 9 12]
        cfg.Frontend=struct('mode','tf_v1','TF',struct('stopbandWidthHz',600e3,'triangleSpanUs',span));
        tf=TFBlankerV1(cfg); t=tf.Config;
        [z,meta]=tf.applyRange(r,0,halo,periods*N); assert(meta.validCount==periods*N);
        g=max(t.K-abs(-t.K:t.K),0)/t.K^2;
        w=conv(movmax(double(abs(r)>=threshold),[t.A t.A]),g,'same');
        useful=(1-w).*clean+w.*conv(clean,tf.Notch,'same');
        residual=(1-w).*interference+w.*conv(interference,tf.Notch,'same');
        reference=useful+residual;
        relativeError=max(abs(z-reference(core)))/max(abs(r)); assert(relativeError<1e-12);
        [metric,curve]=measure(useful(core),clean(core),N,fs,cfg.dllCorrelatorSpacing);
        [wrong,~]=measure(circshift(useful(core),1),clean(core),N,fs,cfg.dllCorrelatorSpacing);
        assert(abs(wrong.peakSamples-metric.peakSamples-1)<.07);
        metric.outerSpanUs=span; metric.actualOuterSpanUs=t.actualTriangleSpanUs;
        metric.meanWeight=meta.meanWeight; metric.relativeReferenceError=relativeError;
        metric.residualInterferenceEnergyDb=10*log10(sum(abs(residual(core)).^2)/sum(abs(interference(core)).^2));
        metric.shiftedPeakSamples=wrong.peakSamples;
        rows{end+1}=metric; curves{end+1}=curve; %#ok<AGROW>
    end
    summary=struct('samplingFreq',fs,'bandwidthHz',600e3,'prn',11,'durationMs',20, ...
        'pulseRateHz',2700,'pairSpacingUs',12,'gaussianSigmaUs',1.5,'peakToThresholdRatio',10, ...
        'note','Frozen detection weights from clean+synthetic DME; useful and interference components separated algebraically. No thermal noise, loop or S4 truth.', ...
        'scriptHash',frontendHash(fileread([mfilename('fullpath') '.m'])),'cases',{rows});
    fid=fopen(fullfile(outputRoot,'edge_fidelity.json'),'w','n','UTF-8'); assert(fid>=0);
    cleaner=onCleanup(@() fclose(fid)); fprintf(fid,'%s\n',jsonencode(summary,'PrettyPrint',true)); clear cleaner
    save(fullfile(outputRoot,'edge_fidelity.mat'),'summary','curves');
    f=figure('Visible','off','Position',[100 100 1100 750]); cleaner=onCleanup(@() close(f)); tiledlayout(2,2);
    nexttile; hold on;
    for k=1:4, plot(curves{k}.lagChips,curves{k}.magnitude,'DisplayName',sprintf('%g us',rows{k}.outerSpanUs)); end
    xlim([-1 1]); xlabel('Lag (chips)'); ylabel('Useful correlation magnitude'); grid on; legend('Location','best');
    nexttile; hold on;
    for k=1:4, plot(curves{k}.dllLag,curves{k}.dll,'DisplayName',sprintf('%g us',rows{k}.outerSpanUs)); end
    xlabel('Lag (chips)'); ylabel('(E-L)/(E+L)'); grid on; legend('Location','best');
    nexttile; plot([3 6 9 12],cellfun(@(s) s.promptGainDb,rows),'o-');
    xlabel('Nominal outer transition (us)'); ylabel('Useful Prompt gain (dB)'); grid on;
    residualDb=cellfun(@(s) s.residualInterferenceEnergyDb,rows);
    nexttile; plot([3 6 9 12],residualDb,'o-');
    padding=max(.01,.1*(max(residualDb)-min(residualDb)));
    ylim([min(residualDb)-padding max(residualDb)+padding]);
    xlabel('Nominal outer transition (us)'); ylabel('Residual DME / input DME (dB)'); grid on;
    exportgraphics(f,fullfile(outputRoot,'edge_fidelity.png'),'Resolution',150);
end

function [m,c]=measure(y,reference,N,fs,spacing)
    folded=mean(reshape(y,N,[]),2).'; ref=reference(1:N);
    correlation=ifft(fft(folded).*conj(fft(ref)))/N;
    M=32; dense=fftshift(interpft(correlation,N*M)); lag=(-N*M/2:N*M/2-1)/M;
    near=abs(lag)<4; candidates=lag(near); [~,i]=max(abs(dense(near))); peak=candidates(i);
    chips=lag*10.23e6/fs; tau=-.8:.001:.8;
    early=interp1(chips,abs(dense),tau+spacing); late=interp1(chips,abs(dense),tau-spacing);
    dll=(early-late)./max(early+late,eps); crossings=find(dll(1:end-1).*dll(2:end)<=0);
    [~,j]=min(abs(tau(crossings))); ix=crossings(j);
    zero=tau(ix)-dll(ix)*(tau(ix+1)-tau(ix))/(dll(ix+1)-dll(ix));
    if ~isfinite(zero), zero=tau(ix); end
    m=struct('peakSamples',peak,'dllZeroChips',zero,'promptPhaseRad',angle(correlation(1)), ...
        'promptGainDb',20*log10(abs(correlation(1))));
    keep=abs(chips)<=1.5; c=struct('lagChips',chips(keep),'magnitude',abs(dense(keep)),'dllLag',tau,'dll',dll);
end
