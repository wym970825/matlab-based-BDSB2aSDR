function result=probe_rf_centers()
% Read-only, short RF checks. These are frequency estimates, not RF truth.
root=fileparts(fileparts(fileparts(mfilename('fullpath'))));
out=fullfile(root,'results','tf_blanker_design');
manifest=jsondecode(fileread(fullfile(root,'docs','semiphysical_recompute','five_cases.json')));
rows=cell(1,5);
for k=1:5
    c=manifest.cases(k); cfg=jsondecode(fileread(fullfile(root,'docs','semiphysical_recompute',c.configFile)));
    fs=cfg.samplingFreq; n=round(.02*fs); estimates=[]; fractions=[];
    for sec=[0 360 600]
        fid=fopen(c.inputFile,'rb'); assert(fid>=0); fseek(fid,round(sec*fs)*4,'bof');
        v=fread(fid,2*n,'int16=>double'); fclose(fid);
        x=complex(v(1:2:end),v(2:2:end));
        [p,f]=pwelch(x,hann(8192),4096,32768,fs,'centered');
        background=median(p); [~,ip]=max(p); fc=f(ip);
        use=abs(f-fc)<400e3; excess=max(p(use)-background,0);
        estimates(end+1)=sum(f(use).*excess)/sum(excess); %#ok<AGROW>
        fractions(end+1)=mean(abs(x).^2>=cfg.PB_settings.Th_static_tracking^2); %#ok<AGROW>
    end
    rows{k}=struct('case',c.id,'seconds',[0 360 600],'estimatedCenterHz',estimates, ...
        'detectorDuty',fractions,'thresholdAmplitude',cfg.PB_settings.Th_static_tracking, ...
        'thresholdPower',cfg.PB_settings.Th_static_tracking^2);
    fprintf('%s: centers kHz = %s\n',c.id,mat2str(estimates/1e3,6));
end
result=struct('method','Welch PSD; excess-power centroid within +/-400 kHz of the peak; no-interference estimate is not a carrier identification', ...
    'cases',[rows{:}]);
fid=fopen(fullfile(out,'rf_center_probes.json'),'w','n','UTF-8');
fprintf(fid,'%s\n',jsonencode(result,'PrettyPrint',true)); fclose(fid);
end
