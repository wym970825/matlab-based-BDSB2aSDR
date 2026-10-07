cd('F:/matlab-GNSSsdr/BDS/B2a'); setupPaths;
root='F:/matlab-GNSSsdr/BDS/B2a/results/data1020/20261008_static_pb_run02';
cfg=jsondecode(fileread(fullfile(root,'configs','02_beiqijiatai.json')));
cfg.acqSatelliteList=25; cfg.numberOfChannels=1; cfg.msToProcess=30000;
cfg.longCoh_ms=1; cfg.useParfor=false; cfg.useParallelAcquisition=false;
cfg.doNavigation=false; cfg.doNmea=false; cfg.doPlot=false;
cfg.tag='weak25_coh1'; dst=fullfile(root,cfg.tag);
assert(~isfolder(dst),'Output exists.'); mkdir(dst); diary(fullfile(dst,'matlab.log'));
report=runFromJsonConfig(cfg,'outDir',dst,'closeFigures',true);
if report.ok
    T=load(fullfile(dst,'temp','Trk_Prn_25_final.mat'),'finalTRes'); t=T.finalTRes;
    result=struct('PRN',25,'coherentMs',1,'recordedMs',numel(t.I_P), ...
        'longStateMs',nnz(ismember(t.trk_state,[3 4])), ...
        'reacqMs',nnz(t.trk_state==9), ...
        'medianCno',median(t.B2a_CNo(isfinite(t.B2a_CNo)&t.B2a_CNo>0)));
    fid=fopen(fullfile(dst,'diagnostic.json'),'w'); fprintf(fid,'%s',jsonencode(result)); fclose(fid);
end
diary off; exit
