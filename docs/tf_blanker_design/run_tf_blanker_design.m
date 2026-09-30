function results=run_tf_blanker_design()
% Reproducible, bounded DESIGN simulations. Does not alter receiver/configs.
% Perfect-code laboratory C/(N+J) and finite-record intensity CV are proxies,
% not the receiver's measured C/N0 or standard 60-second S4 validation.
root=fileparts(fileparts(fileparts(mfilename('fullpath')))); setupPaths;
out=fullfile(root,'results','tf_blanker_design'); if ~isfolder(out), mkdir(out); end
oldRng=rng; restoreRng=onCleanup(@() rng(oldRng)); rng(20260930,'twister');
cfg=jsondecode(fileread(fullfile(root,'docs','semiphysical_recompute','configs','04_2700_n50dBm.json')));
fs=cfg.samplingFreq; fc=-450e3; BW=400e3; duration=.08; N=round(fs*duration);
threshold=cfg.PB_settings.Th_static_tracking; noiseRms=50;
code=generateB2aPilotCode(11,cfg); n=0:N-1;
c=double(code(mod(floor(n*cfg.codeFreqBasis/fs),cfg.codeLength)+1));
signal=sqrt(noiseRms^2*10^(48/10)/fs)*c;
noise=noiseRms/sqrt(2)*(randn(1,N)+1i*randn(1,N));
[jam,centers]=pulses(N,fs,2700,threshold*20,fc);
x=signal+noise+jam; mask=abs(x).^2>=threshold^2;
fir=tf_notch_coefficients('fir',fs,fc,BW,641,150e3);
iir=tf_notch_coefficients('iir',fs,fc,BW);
[wNaive,metaNaive]=tf_soft_weights(mask,fs,12,0,'naive');
[wFir,metaFir]=tf_soft_weights(mask,fs,12,fir.tail+round(2e-6*fs),'guarded');
[wIir,metaIir]=tf_soft_weights(mask,fs,12,iir.tail+round(2e-6*fs),'guarded');
scenarios={struct('name','PB','filter',[],'w',double(mask)), ...
    struct('name','IIR always','filter',iir,'w',ones(1,N)), ...
    struct('name','IIR hard','filter',iir,'w',double(mask)), ...
    struct('name','IIR naive triangle','filter',iir,'w',wNaive), ...
    struct('name','IIR guarded triangle','filter',iir,'w',wIir), ...
    struct('name','FIR hard','filter',fir,'w',double(mask)), ...
    struct('name','FIR naive triangle','filter',fir,'w',wNaive), ...
    struct('name','FIR guarded triangle','filter',fir,'w',wFir)};
rows=cell(size(scenarios));
for k=1:numel(scenarios)
    v=scenarios{k}; rows{k}=evaluate(v.name,signal,noise,jam,c,v.filter,v.w,fs);
    fprintf('%s: IR %.2f dB, useful CV %.5f, equiv C/(N+J) %.2f dB-Hz\n', ...
        v.name,rows{k}.interferenceReductionDb,rows{k}.usefulIntensityCV,rows{k}.equivalentCniDbHz);
end
results=struct('seed',20260930,'matlabVersion',version,'samplingFreq',fs, ...
    'durationSec',duration,'thresholdAmplitude',threshold,'thresholdPower',threshold^2, ...
    'assumedWidthHz',BW,'widthUnitsUnconfirmed',true,'centerHz',fc, ...
    'nominalPulsePairsPerSec',2700,'realizedPulsePairs',numel(centers), ...
    'pulsePeakThresholdRatio',20,'inputPilotCNoDbHz',48, ...
    'maskDuty',mean(mask),'naiveWeight',metaNaive,'firWeight',metaFir, ...
    'iirWeight',metaIir,'comparisons',[rows{:}]);

% Stationary filter response: explicitly different FIR/IIR bandwidth meanings.
freq=linspace(-fs/2,fs/2,65536); S=sinc(freq/cfg.codeFreqBasis).^2; S=S/sum(S);
fi=reshape(freqz(iir.b,iir.a,2*pi*freq/fs),1,[]);
ff=reshape(freqz(fir.b,fir.a,2*pi*freq/fs),1,[]).*exp(1i*2*pi*freq*fir.delay/fs);
results.iir=struct('radius',iir.radius,'settling60dBSamples',iir.tail, ...
    'settling60dBUs',1e6*iir.tail/fs,'stationaryCNoLossDb',-10*log10(abs(sum(fi.*S))^2/sum(abs(fi).^2.*S)));
results.fir=struct('taps',numel(fir.b),'delaySamples',fir.delay,'delayUs',1e6*fir.delay/fs, ...
    'stopWidthHz',BW,'transitionHz',150e3,'stationaryCNoLossDb',-10*log10(abs(sum(ff.*S))^2/sum(abs(ff).^2.*S)));
fig=figure('Visible','off','Color','w','Position',[80 80 1200 780]); cl=onCleanup(@() close(fig));
tl=tiledlayout(fig,2,2,'TileSpacing','compact');
ax=nexttile(tl); plot(ax,(freq-fc)/1e3,20*log10(max(abs(fi),1e-9)),(freq-fc)/1e3,20*log10(max(abs(ff),1e-9))); grid(ax,'on'); xlim(ax,[-1000 1000]); ylim(ax,[-90 3]); xlabel(ax,'Frequency relative to notch (kHz)'); ylabel(ax,'Magnitude (dB)'); legend(ax,'IIR: 400 kHz -3 dB','FIR: 400 kHz stop + 150 kHz transitions');
ax=nexttile(tl); gd=-gradient(unwrap(angle(fi)),2*pi*(freq(2)-freq(1))/fs); gd(abs(fi)<.05)=NaN;
plot(ax,(freq-fc)/1e3,gd,(freq-fc)/1e3,zeros(size(freq))); grid(ax,'on'); xlim(ax,[-1000 1000]); ylim(ax,[-1 23]); xlabel(ax,'Frequency relative to notch (kHz)'); ylabel(ax,'Residual group delay (samples)'); legend(ax,'IIR','FIR after D-sample compensation');
center=round(centers(min(3,numel(centers)))*fs); idx=max(1,center-1000):min(N,center+1400);
ax=nexttile(tl); plot(ax,(idx-center)/fs*1e6,double(mask(idx)),(idx-center)/fs*1e6,wNaive(idx),(idx-center)/fs*1e6,wFir(idx)); grid(ax,'on'); xlabel(ax,'Time relative to pulse (us)'); ylabel(ax,'Weight'); legend(ax,'Threshold mask','Unit-area triangle only','Guard + unit-area triangle');
ax=nexttile(tl); jf=tf_filter_aligned(jam,fir); yNaive=jam+wNaive.*(jf-jam); yGood=jam+wFir.*(jf-jam);
plot(ax,(idx-center)/fs*1e6,abs(jam(idx))/threshold,(idx-center)/fs*1e6,abs(yNaive(idx))/threshold,(idx-center)/fs*1e6,abs(yGood(idx))/threshold); grid(ax,'on'); xlabel(ax,'Time relative to pulse (us)'); ylabel(ax,'Interference magnitude / threshold'); legend(ax,'Input','FIR + naive triangle','FIR + guarded triangle');
title(tl,'Design comparison: FIR and IIR widths use different definitions'); exportgraphics(fig,fullfile(out,'filter_and_gating.png'),'Resolution',155); clear cl
clear jf yNaive yGood

% Conditional parameter grid; choose only among the tested points.
gridRows={};
for taps=[321 641 961]
    for width=[200 400 600 800]*1e3
        f=tf_notch_coefficients('fir',fs,fc,width,taps,150e3);
        [weight,wm]=tf_soft_weights(mask,fs,12,f.tail+round(2e-6*fs),'guarded');
        q=evaluate(sprintf('FIR %d %.0fk',taps,width/1e3),signal,noise,jam,c,f,weight,fs);
        H=reshape(freqz(f.b,f.a,2*pi*freq/fs),1,[]);
        stop=abs(freq-fc)<=width/2;
        q.stopbandWorstDb=20*log10(max(abs(H(stop))));
        q.taps=taps; q.stopWidthHz=width; q.transitionHz=150e3;
        q.delayUs=f.delay/fs*1e6; q.lookaheadUs=wm.lookaheadSamples/fs*1e6;
        gridRows{end+1}=q; %#ok<AGROW>
        fprintf('Grid %d %.0fk: IR %.2f, stop %.1f, CNI %.2f\n',taps,width/1e3,q.interferenceReductionDb,q.stopbandWorstDb,q.equivalentCniDbHz);
    end
end
results.parameterGrid=[gridRows{:}];
feasible=find([results.parameterGrid.stopbandWorstDb]<=-50 & [results.parameterGrid.interferenceReductionDb]>=30);
if ~isempty(feasible)
    [~,best]=max([results.parameterGrid(feasible).equivalentCniDbHz]); results.bestGridIndex=feasible(best);
else
    results.bestGridIndex=[];
end

% Sensitivity to peak amplitude, pulse density, and center mismatch.
sensitivity={};
for rate=[1350 2700]
    for ratio=[4 10 30]
        [j,~]=pulses(N,fs,rate,threshold*ratio,fc);
        m=abs(signal+noise+j).^2>=threshold^2;
        [weight,~]=tf_soft_weights(m,fs,12,fir.tail+round(2e-6*fs),'guarded');
        for err=[0 100 200]*1e3
            f=tf_notch_coefficients('fir',fs,fc+err,400e3,641,150e3);
            q=evaluate('FIR guarded sensitivity',signal,noise,j,c,f,weight,fs);
            q.pulseRate=rate; q.peakThresholdRatio=ratio; q.centerErrorHz=err;
            sensitivity{end+1}=q; %#ok<AGROW>
        end
    end
end
results.sensitivity=[sensitivity{:}];

% No-interference identity, including the realistic nonzero false-alarm case.
quiet=signal+noise; m=abs(quiet).^2>=threshold^2;
[weight,~]=tf_soft_weights(m,fs,12,fir.tail+50,'guarded');
qq=apply(quiet,fir,zeros(size(weight)));
results.quiet=struct('forcedZeroMaskExactIdentity',isequal(qq,quiet), ...
    'detectedSamples',nnz(m),'samples',N,'actualWeightSupport',mean(weight>0), ...
    'gaussianSingleSamplePfa',exp(-threshold^2/noiseRms^2));
assert(results.quiet.forcedZeroMaskExactIdentity);

% A 200-ms perfect-prompt intensity-CV test with known modulation. Not 60-s S4.
results.scintProxy=scintTest(cfg,fir,threshold,noiseRms);
results.adaptive=adaptiveTest(fs,fc,threshold,noiseRms,out);
results.notes={'No production receiver file or five-case config modified.', ...
    'FIR reference uses future samples; causal buffering and time mapping are design requirements.', ...
    'Equivalent C/(N+J) uses exact component separation and known PRN; not a receiver C/N0 estimator.', ...
    'Intensity CV test is 200 ms and does not implement the receiver 60-second detrending chain.', ...
    'Grid optimum is conditional on seed, pulse shape, power, carrier, and tested candidates.'};
save(fullfile(out,'design_simulation.mat'),'results','fir','iir','cfg','-v7.3');
fid=fopen(fullfile(out,'design_simulation.json'),'w','n','UTF-8'); fprintf(fid,'%s\n',jsonencode(results,'PrettyPrint',true)); fclose(fid);
fprintf('DESIGN SIMULATION FINISHED\n');
end

function y=apply(x,f,w)
if isempty(f), y=x.*(1-w); return; end
y=x; use=w>0;
if any(use), filtered=tf_filter_aligned(x,f); y(use)=x(use)+w(use).*(filtered(use)-x(use)); end
end

function q=evaluate(name,s,n,j,code,f,w,fs)
Ns=round(fs*.001); N=numel(s); interior=Ns+1:N-Ns;
ys=apply(s,f,w); yn=apply(n,f,w); yj=apply(j,f,w);
ps=mean(reshape(ys.*code,Ns,[]),1); pe=mean(reshape((yn+yj).*code,Ns,[]),1);
reference=mean(reshape(s.*code,Ns,[]),1); keep=2:numel(ps)-1;
intensity=abs(ps(keep)).^2; gain=ps(keep)./reference(keep);
q=struct('method',name,'interferenceReductionDb',10*log10(sum(abs(j(interior)).^2)/sum(abs(yj(interior)).^2)), ...
    'usefulPromptPowerRatioDb',10*log10(mean(abs(ps(keep)).^2)/mean(abs(reference(keep)).^2)), ...
    'equivalentCniDbHz',10*log10(mean(abs(ps(keep)).^2)/mean(abs(pe(keep)).^2)/.001), ...
    'usefulIntensityCV',std(intensity,1)/mean(intensity), ...
    'promptPhaseStdDeg',std(angle(gain),1)*180/pi,'meanWeight',mean(w(interior)));
end

function [j,centers]=pulses(N,fs,rate,peak,fc)
duration=N/fs; centers=cumsum(-log(max(rand(1,ceil(rate*duration*2+100)),eps))/rate);
centers=centers(centers>.0001 & centers<duration-.0001);
j=complex(zeros(1,N)); alpha=4.5e11; half=round(9e-6*fs);
for start=centers
    phase=2*pi*rand;
    for delta=[0 12e-6]
        middle=round((start+delta)*fs)+1; idx=max(1,middle-half):min(N,middle+half);
        t=(idx-1)/fs; local=t-start-delta;
        j(idx)=j(idx)+peak*exp(-alpha/2*local.^2).*exp(1i*(2*pi*fc*t+phase));
    end
end
end

function q=scintTest(cfg,fir,threshold,noiseRms)
fs=cfg.samplingFreq; N=round(.2*fs); n=0:N-1; code=generateB2aPilotCode(11,cfg);
c=double(code(mod(floor(n*cfg.codeFreqBasis/fs),cfg.codeLength)+1));
intensity=1+.6*sin(2*pi*5*n/fs); s=sqrt(intensity).*c;
[j,~]=pulses(N,fs,2700,20*threshold,fir.centerHz);
noise=noiseRms/sqrt(2)*(randn(1,N)+1i*randn(1,N));
m=abs(s+noise+j).^2>=threshold^2;
[w,~]=tf_soft_weights(m,fs,12,fir.tail+round(2e-6*fs),'guarded');
pb=apply(s,[],double(m)); tf=apply(s,fir,w); ns=round(.001*fs);
getI=@(x) abs(mean(reshape(x.*c,ns,[]),1)).^2;
original=getI(s); p=getI(pb); t=getI(tf); idx=2:numel(original)-1;
q=struct('durationSec',.2,'modulationDepth',.6,'nominalInfiniteRecordCV',.6/sqrt(2), ...
    'inputIntensityCV',std(original(idx),1)/mean(original(idx)), ...
    'pbIntensityCV',std(p(idx),1)/mean(p(idx)), ...
    'tfIntensityCV',std(t(idx),1)/mean(t(idx)), ...
    'scope','Noiseless useful-component prompt intensity after masks detected on noisy IF; 200-ms CV, not standard S4');
end

function q=adaptiveTest(fs,fc,threshold,noiseRms,out)
blocks=70; ns=round(.001*fs); truth=fc+100e3*sin(2*pi*(0:blocks-1)/50); truth(41:end)=truth(41:end)+180e3;
observed=nan(1,blocks); estimate=nan(1,blocks); accepted=false(1,blocks); initialized=false; current=fc;
for b=1:blocks
    hasPulse=~ismember(b,21:30);
    if hasPulse
        [j,~]=pulses(ns,fs,5000,20*threshold,truth(b));
    else
        j=zeros(1,ns);
    end
    x=j+noiseRms/sqrt(2)*(randn(1,ns)+1i*randn(1,ns)); m=abs(x).^2>=threshold^2;
    P=abs(fftshift(fft(x.*hann(ns).',32768))).^2; f=(-16384:16383)/32768*fs;
    [peak,ip]=max(P); floorPower=median(P);
    if nnz(m)>=round(.5e-6*fs) && peak/floorPower>100
        use=abs(f-f(ip))<500e3; excess=max(P(use)-floorPower,0); raw=sum(f(use).*excess)/sum(excess);
        observed(b)=raw; accepted(b)=true;
        if ~initialized, current=raw; initialized=true; else, current=current+max(-100e3,min(100e3,.5*(raw-current))); end
    end
    estimate(b)=current;
end
quiet=21:30;
q=struct('blockMs',1,'fftPoints',32768,'smoothingAlpha',.5,'maxStepHz',100e3, ...
    'acceptedBlocks',nnz(accepted),'totalBlocks',blocks, ...
    'measurementRmsErrorHz',sqrt(mean((observed(accepted)-truth(accepted)).^2)), ...
    'smoothedRmsErrorHz',sqrt(mean((estimate(accepted)-truth(accepted)).^2)), ...
    'quietUpdates',nnz(accepted(quiet)),'quietHoldExact',all(estimate(quiet)==estimate(quiet(1)-1)), ...
    'scope','Estimator-only stress test; fixed configured width; no end-to-end adaptive FIR coefficient-switching validation');
assert(q.quietUpdates==0 && q.quietHoldExact);
fig=figure('Visible','off','Color','w','Position',[100 100 1100 470]); cl=onCleanup(@() close(fig));
plot(1:blocks,truth/1e3,1:blocks,observed/1e3,'.',1:blocks,estimate/1e3,'LineWidth',1.2); grid on;
xlabel('Block index (1 ms each)'); ylabel('Center frequency (kHz)'); legend('Injected frequency','Accepted spectral centroid','Bounded EWMA');
title('V2 center-estimator stress test: blocks 21-30 contain no interference');
exportgraphics(fig,fullfile(out,'adaptive_center.png'),'Resolution',150);
end
