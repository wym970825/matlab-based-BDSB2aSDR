function probe = probe_rf_parameter_windows(outputPath)
% Sparse RF diagnostics across the whole recording; never edits inputs.
pkg=fileparts(mfilename('fullpath'));
manifest=jsondecode(fileread(fullfile(pkg,'five_cases.json')));
offsets=[0 120 240 360 480 600 714];
duration=0.02;
probe=struct('probeDurationSec',duration,'offsetsSec',offsets, ...
    'note','Sparse 20-ms probes; not a full-record saturation guarantee.');
allCases=cell(1,5);
for k=1:5
    item=manifest.cases(k); s=jsondecode(fileread(fullfile(pkg,item.configFile)));
    fid=fopen(fullfile(s.filePath,s.fileName),'rb'); assert(fid>=0);
    cleanup=onCleanup(@() fclose(fid));
    amplitude=s.PB_settings.Th_static_tracking;
    scale=s.usrp.scaleK+s.usrp.gain-10*log10(s.samplingFreq);
    a=struct('case',item.id,'configuredThresholdDbm',s.Th_static_dBm, ...
        'reconstructedThresholdDbm',20*log10(amplitude)+scale, ...
        'fileBytes',dir(fullfile(s.filePath,s.fileName)).bytes);
    windows=cell(size(offsets));
    for j=1:numel(offsets)
        assert(fseek(fid,round(offsets(j)*s.samplingFreq)*4,'bof')==0);
        iq=fread(fid,2*round(duration*s.samplingFreq),'int16=>double');
        assert(numel(iq)==2*round(duration*s.samplingFreq));
        I=iq(1:2:end); Q=iq(2:2:end); power=I.^2+Q.^2;
        thresholds=amplitude*10.^([-3 0 3]/20);
        duty=arrayfun(@(th) mean(power>th^2),thresholds);
        postPower=arrayfun(@(th) mean(power.*(power<=th^2)),thresholds);
        windows{j}=struct('offsetSec',offsets(j), ...
            'adcRailFraction',mean(iq==-32768 | iq==32767), ...
            'inputRms',sqrt(mean(power)), 'dutyAtThresholdMinus3NominalPlus3Db',duty, ...
            'postRmsAtThresholdMinus3NominalPlus3Db',sqrt(postPower));
    end
    a.windows=[windows{:}]; allCases{k}=a; clear cleanup
end
probe.cases=[allCases{:}];
fid=fopen(outputPath,'w','n','UTF-8'); assert(fid>=0);
cleanup=onCleanup(@() fclose(fid));
fprintf(fid,'%s\n',jsonencode(probe,'PrettyPrint',true));
end
