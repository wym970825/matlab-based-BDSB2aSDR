function r=verify_tf_design()
% Verify design invariants and bounded real-RF preprocessing, not tracking.
root=fileparts(fileparts(fileparts(mfilename('fullpath'))));
out=fullfile(root,'results','tf_blanker_design');
old=rng; restore=onCleanup(@() rng(old)); rng(923,'twister');
fs=25e6; fc=-450e3; f=tf_notch_coefficients('fir',fs,fc,400e3,641,150e3);
i=tf_notch_coefficients('iir',fs,fc,400e3); N=110000;
x=randn(1,N)+1i*randn(1,N); m=false(1,N);
m([200 201 900:970 25200:25300 78000:78200])=true;
[w,meta]=tf_soft_weights(m,fs,12,f.tail+50,'guarded');
y=x+w.*(tf_filter_aligned(x,f)-x); halo=meta.lookaheadSamples;
chunked=zeros(size(y)); sizes=[137 24799 621 18003 733]; p=1; b=1;
while p<=N
    last=min(N,p+sizes(mod(b-1,numel(sizes))+1)-1);
    lo=max(1,p-halo); hi=min(N,last+halo); local=x(lo:hi);
    ww=tf_soft_weights(m(lo:hi),fs,12,f.tail+50,'guarded');
    yy=local+ww.*(tf_filter_aligned(local,f)-local);
    chunked(p:last)=yy(p-lo+1:last-lo+1); p=last+1; b=b+1;
end
valid=halo+1:N-halo;
r=struct('blockHaloSamples',halo,'irregularBlockMaxError',max(abs(y(valid)-chunked(valid))), ...
    'weightWithinUnitInterval',all(w>=0 & w<=1),'detectorPlateauExact',all(w(m)==1), ...
    'zeroWeightIdentity',isequal(y(w==0),x(w==0)));
edges=fc+[-200e3 200e3]; H=reshape(freqz(i.b,i.a,2*pi*edges/fs),1,[]);
r.iirMinus3dBEdgeDb=20*log10(abs(H));
H=reshape(freqz(f.b,f.a,2*pi*[fc -fc]/fs),1,[]);
r.firSignedCenterMagnitudeDb=20*log10(max(abs(H),1e-15));
pass=linspace(1e6,5e6,31); H=reshape(freqz(f.b,f.a,2*pi*pass/fs),1,[]);
r.firAlignedPassbandMaxPhaseRad=max(abs(angle(H.*exp(1i*2*pi*pass*f.delay/fs))));
assert(r.irregularBlockMaxError<1e-10 && r.weightWithinUnitInterval && r.detectorPlateauExact && r.zeroWeightIdentity);
assert(max(abs(r.iirMinus3dBEdgeDb+10*log10(2)))<1e-9);
assert(r.firSignedCenterMagnitudeDb(1)<-50 && abs(r.firSignedCenterMagnitudeDb(2))<.05);
assert(r.firAlignedPassbandMaxPhaseRad<1e-10);

manifest=jsondecode(fileread(fullfile(root,'docs','semiphysical_recompute','five_cases.json')));
rows={}; count=round(.02*fs); example=[];
for k=1:5
    item=manifest.cases(k); cfg=jsondecode(fileread(fullfile(root,'docs','semiphysical_recompute',item.configFile)));
    for sec=[0 360 600]
        fid=fopen(item.inputFile,'rb'); assert(fid>=0);
        status=fseek(fid,round(sec*fs)*4,'bof'); assert(status==0);
        v=fread(fid,2*count,'int16=>double'); fclose(fid); assert(numel(v)==2*count);
        raw=complex(v(1:2:end),v(2:2:end)).'; mask=abs(raw).^2>=cfg.PB_settings.Th_static_tracking^2;
        [weight,wm]=tf_soft_weights(mask,fs,12,f.tail+50,'guarded');
        pb=raw.*(~mask); t400=raw+weight.*(tf_filter_aligned(raw,f)-raw);
        f600=tf_notch_coefficients('fir',fs,fc,600e3,641,150e3);
        t600=raw+weight.*(tf_filter_aligned(raw,f600)-raw);
        % Exclude 1 ms edges: no artificial zero padding in PSD metrics.
        idx=round(.001*fs)+1:count-round(.001*fs);
        [P,freq]=pwelch([raw(idx);pb(idx);t400(idx);t600(idx)].',hann(8192),4096,32768,fs,'centered');
        target=abs(freq-fc)<200e3; wide=abs(freq-fc)<600e3;
        outside=abs(freq-fc)>1e6 & abs(freq)<8e6;
        bp=sum(P(target,:),1); wp=sum(P(wide,:),1); op=sum(P(outside,:),1);
        q=struct('case',item.id,'startSec',sec,'durationSec',.02,'detectorDuty',mean(mask), ...
            'meanWeight',wm.meanWeight,'weightSupportFraction',wm.weightSupportFraction, ...
            'targetBandTotalPowerReductionDb',10*log10(bp(1)./bp(2:4)), ...
            'wideBandTotalPowerReductionDb',10*log10(wp(1)./wp(2:4)), ...
            'outsideBandTotalPowerChangeDb',10*log10(op(2:4)./op(1)), ...
            'quietExactIdentity',isequal(t400,raw),'methods',{{'PB','TF400k','TF600k'}});
        rows{end+1}=q; %#ok<AGROW>
        if k==4 && sec==360, example=P; exampleFreq=freq; end
    end
end
r.realRf=struct('scope','20-ms segments at 0, 360, 600 s; PSD includes receiver noise and GNSS, so reductions are NOT pure interference rejection or C/N0.', ...
    'centerHz',fc,'targetHalfWidthHz',200e3,'rows',[rows{:}]);
fig=figure('Visible','off','Color','w','Position',[80 80 1100 480]); cl=onCleanup(@() close(fig));
plot(exampleFreq/1e6,10*log10(example),'LineWidth',1); grid on; xlim([-2 1]);
xlabel('Complex baseband frequency (MHz)'); ylabel('IF PSD (dB sample-unit^2 / Hz)');
legend('Raw','PB','TF FIR 400 kHz','TF FIR 600 kHz');
title('Real RF: 2700 pairs/s, -50 dBm case, 20 ms at file time 360 s');
exportgraphics(fig,fullfile(out,'real_rf_psd.png'),'Resolution',150);
fid=fopen(fullfile(out,'design_verification.json'),'w','n','UTF-8'); fprintf(fid,'%s\n',jsonencode(r,'PrettyPrint',true)); fclose(fid);
fprintf('Design invariant checks passed; 15 real-RF snippets compared.\n');
end
