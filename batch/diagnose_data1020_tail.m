cd('F:/matlab-GNSSsdr/BDS/B2a'); setupPaths;
base='F:/matlab-GNSSsdr/BDS/B2a/results/data1020/20261008_static_pb_run02';
cfg=jsondecode(fileread(fullfile(base,'configs','01_HUR.json')));
cfg.acqSatelliteList=38; cfg.numberOfChannels=1;
cfg.skipNumberOfBytes=125*20e6*4; cfg.msToProcess=30000;
cfg.useParfor=false; cfg.useParallelAcquisition=false;
cfg.doNavigation=false; cfg.doPlot=false; cfg.doNmea=false;
for coherentMs=[1 5]
    cfg.longCoh_ms=coherentMs;
    cfg.tag=sprintf('tail125_prn38_coh%d',coherentMs);
    dst=fullfile(base,cfg.tag); assert(~isfolder(dst),'Output exists.');
    mkdir(dst); diary(fullfile(dst,'matlab.log'));
    report=runFromJsonConfig(cfg,'outDir',dst,'closeFigures',true);
    if report.ok
        t=load(fullfile(dst,'temp','Trk_Prn_38_final.mat'),'finalTRes');
        tr=t.finalTRes;
        s=struct('coherentMs',coherentMs,'recordedMs',numel(tr.I_P), ...
            'medianCno',median(tr.B2a_CNo(isfinite(tr.B2a_CNo)&tr.B2a_CNo>0)), ...
            'lowCnoCount',nnz(tr.B2a_CNo<35),'reacqMs',nnz(tr.trk_state==9));
        fid=fopen(fullfile(dst,'diagnostic.json'),'w'); fprintf(fid,'%s',jsonencode(s)); fclose(fid);
    end
    diary off
end
exit
