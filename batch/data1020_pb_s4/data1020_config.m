function [cases,out,root] = data1020_config()
root="F:/matlab-GNSSsdr/BDS/S4repair_basedOnSDR-v2";
addpath(root); addpath('F:/matlab-GNSSsdr/BDS/B2a/channelCtrl');
out=fullfile(root,'results','data1020_pb_02_04_05_s4');
source="F:/matlab-GNSSsdr/BDS/B2a/results/data1020/20261009_pb_tf_comparison";
m=jsondecode(fileread(fullfile(source,'manifest.json')));
ids=[2 4 5]; prns={[24 27 28 32 33 38 39 41],[25 27 28 30 32 33 38 39 41],[24 27 28 30 32 33 38 39 41]};
cases=cell(3,1);
for k=1:3
    e=m.entries(ids(k));
    cfg=s4repair.config.defaultConfig('real',root);
    settings=s4repair.io.loadSettings(string(e.pbDir));
    cfg.coherentIntegrationSec=settings.intTime;
    cfg.bdtMinusUtc=settings.nmea.utcOffsetSeconds;
    [cfg,metadata]=s4repair.config.configureFromResultDir(cfg,string(e.pbDir));
    cfg.prns=prns{k}; cfg.name=sprintf('%02d-%s-PB',ids(k),e.sourceId);
    cfg.outputDir=fullfile(out,'experiments',cfg.name);
    cfg.deltaFrequencyHz=e.station.frequencyHz-e.centerFrequencyHz;
    cfg.allowUnverifiedFrontendModel=true;
    cfg.forceHardwareValid=true;
    cfg.conventionalNoiseSource="logged_pilot";
    cfg.truthResultsCsv="";
    anchors=s4repair.io.loadPositionAnchors(cfg.resultDir,settings,cfg);
    cases{k}=struct('cfg',cfg,'settings',settings,'anchors',anchors,'entry',e,'metadata',metadata);
end
end
