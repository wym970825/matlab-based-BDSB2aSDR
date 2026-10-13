function tf_h0_prepare()
cd('F:/matlab-GNSSsdr/BDS/B2a');setupPaths;
addpath('batch/data1020_pb_s4');set(groot,'defaultFigureVisible','off');
out="F:/matlab-GNSSsdr/BDS/B2a/results/data1020/20261010_tf_h0_20s";mkdir(out);
m=jsondecode(fileread('results/data1020/20261009_pb_tf_comparison/manifest.json'));
cases=cell(3,1);summary=table();rng(20261010);
for k=1:3
    ids=[2 4 5];e=m.entries(ids(k));s=load(fullfile(e.pbDir,'ui_results.mat'),'settings','results');
    fs=s.settings.samplingFreq;fc=e.centerFrequencyHz;pfa=1e-3;
    offsets=(0:.5:19.5)'; n=round(.005*fs);x=zeros(n,numel(offsets)); psd=[];
    fid=fopen(e.sourceFile,'rb','ieee-le');
    for j=1:numel(offsets)
        fseek(fid,round(offsets(j)*fs)*4,'bof');a=fread(fid,[2 n],'int16=>double');z=complex(a(1,:),a(2,:)).';
        x(:,j)=z;
        [p,f]=pwelch(z,hann(8192,'periodic'),4096,16384,fs,'centered','psd');
        psd(:,j)=p; %#ok<AGROW>
    end
    fclose(fid);fRF=fc+f;meanP=mean(psd,2);
    noiseMask=abs(fRF-1176.45e6)<=5e6 & abs(f)>25e3;
    for rf=[1170 1173 1181]*1e6,noiseMask=noiseMask & abs(fRF-rf)>1e6;end
    n0=mean(meanP(noiseMask));welchVariance=n0*fs;
    power=abs(x(:)).^2;v=welchVariance;history=zeros(30,1);q=-log(pfa);
    truncatedMeanFactor=1-q/expm1(q);
    for j=1:30
        v=mean(power(power<q*v))/truncatedMeanFactor;history(j)=v;
    end
    threshold=sqrt(q*v);rawDuty=mean(power>=threshold^2);
    spectrum=movmean(meanP,21);center=e.station.frequencyHz;
    flank=abs(fRF-center)>1.2e6 & abs(fRF-center)<1.8e6;
    floorPSD=median(spectrum(flank));search=find(abs(fRF-center)<1e6);
    [~,pk]=max(spectrum(search));pk=search(pk);
    left=pk;right=pk;
    while left>search(1) && spectrum(left-1)>2*floorPSD,left=left-1;end
    while right<search(end) && spectrum(right+1)>2*floorPSD,right=right+1;end
    band=left:right;excess=max(spectrum(band)-floorPSD,0);cum=cumsum(excess)/sum(excess);
    lo=fRF(band(find(cum>=.005,1)));hi=fRF(band(find(cum>=.995,1)));
    estimatedCenter=(lo+hi)/2;
    width=max(200e3,ceil((hi-lo+100e3)/50e3)*50e3);
    cfg=s.settings;cfg.msToProcess=20000;cfg.doNavigation=false;cfg.doNmea=false;cfg.doPlot=false;
    cfg.plotTracking=false;cfg.useParfor=false;cfg.useParallelAcquisition=false;cfg.parMaxWorkers=1;
    channel=preRun2(s.results.acqResults,cfg);
    ps=[27 38 41];assert(all(ismember(ps,[channel.PRN])));
    tfcfg=cfg;tfcfg.Frontend=struct('mode','tf_v1','TF',struct('centerHz',estimatedCenter-fc, ...
        'stopbandWidthHz',width,'thresholdAmplitude',threshold,'triangleSpanUs',3));
    filter=TFBlankerV1(tfcfg);
    mirrorResponse=freqz(filter.Notch,1,repmat(-2*pi*(estimatedCenter-fc)/fs,1,2));
    mirror=20*log10(abs(mirrorResponse(1)));
    noise=sqrt(v/2)*(randn(1,2e6)+1i*randn(1,2e6));empiricalPfa=mean(abs(noise)>=threshold);
    assert(abs(empiricalPfa-pfa)<1e-4 && mirror>-.1 && filter.Info.worstStopbandDbOnGrid<-40);
    [~,weight]=filter.applyRange(x(:,1),0,filter.Config.H,n-2*filter.Config.H);
    c=struct('entry',e,'settings',cfg,'channel',channel,'prns',ps,'threshold',threshold, ...
        'noiseVariance',v,'welchVariance',welchVariance,'noisePsd',n0,'centerHz',estimatedCenter-fc, ...
        'bandwidthHz',width,'rawDetectorDuty',rawDuty,'powerHistory',history);
    cases{k}=c;
    row=table(e.experimentNumber,fc,estimatedCenter,width,lo,hi,n0,welchVariance,v,threshold, ...
        rawDuty,weight.meanWeight,empiricalPfa,filter.Info.worstStopbandDbOnGrid,mirror, ...
        'VariableNames',{'Experiment','SamplingCenterHz','EstimatedDmeCenterHz','NotchFullWidthHz', ...
        'Excess99LowHz','Excess99HighHz','WelchNoisePsdAdc2PerHz','WelchFlatFullBandVariance', ...
        'IterativeH0Variance','DetectorAmplitude','RawDetectorDuty','ProbeMeanWeight', ...
        'GaussianH0MeasuredPfa','StopbandDb','MirrorResponseDb'});
    summary=[summary;row]; %#ok<AGROW>
    save(fullfile(out,sprintf('spectrum_%02d.mat',e.experimentNumber)),'fRF','meanP','psd','noiseMask','offsets','c','-v7.3');
    fig=figure('Visible','off','Color','w');plot(fRF/1e6,10*log10(meanP));hold on;
    plot(fRF(noiseMask)/1e6,10*log10(meanP(noiseMask)),'.');yline(10*log10(n0),'--');
    xline((estimatedCenter-width/2)/1e6,'r--');xline((estimatedCenter+width/2)/1e6,'r--');
    xlabel('RF frequency (MHz)');ylabel('PSD (ADC^2/Hz, dB)');grid on;title(sprintf('PB source %02d / raw IF Welch',e.experimentNumber));
    exportgraphics(fig,fullfile(out,sprintf('spectrum_%02d.png',e.experimentNumber)),'Resolution',180);close(fig);
    fprintf('Experiment %02d: threshold=%.6f ADC, center=%.6f MHz, full BW=%.0f kHz, detector duty=%.4f\n', ...
        e.experimentNumber,threshold,estimatedCenter/1e6,width/1e3,rawDuty);
end
data1020_write_md(fullfile(out,'spectral_estimates.md'),summary,'H0门限与干扰频谱估计');
save(fullfile(out,'prepared.mat'),'cases','summary','-v7.3');
fprintf('Main driver parsed: nargin=%d\n',nargin('tf_h0_run'));
end
