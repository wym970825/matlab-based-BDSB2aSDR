function outPath = exportUiDefaults(outPath)
%EXPORTUIDEFAULTS Write default initSettings as JSON for the web UI.
%
%   outPath = exportUiDefaults()
%   outPath = exportUiDefaults('config/ui_defaults.json')

    setupPaths();
    if nargin < 1 || isempty(outPath)
        root = fileparts(fileparts(mfilename('fullpath')));
        outPath = fullfile(root, 'config', 'ui_defaults.json');
    end
    outPath = char(outPath);

    % Avoid long file-cap side effects when dumping defaults
    settings = initSettings('msToProcess', 60000);

    % Flatten useful UI fields + keep nested structs
    d = struct();
    d.msToProcess = settings.msToProcess;
    d.numberOfChannels = settings.numberOfChannels;
    d.filePath = settings.filePath;
    d.fileName = settings.fileName;
    d.dataType = settings.dataType;
    d.fileType = settings.fileType;
    d.IF = settings.IF;
    d.samplingFreq = settings.samplingFreq;
    d.EnablePB = settings.EnablePB;
    d.skipAcquisition = settings.skipAcquisition;
    d.acqSatelliteList = settings.acqSatelliteList;
    d.acqSearchBand = settings.acqSearchBand;
    d.acqThreshold = settings.acqThreshold;
    d.acqStep = settings.acqStep;
    d.fineNoncoh = settings.fineNoncoh;
    d.dllNoiseBandwidth_pull = settings.dllNoiseBandwidth_pull;
    d.dllNoiseBandwidth_stab = settings.dllNoiseBandwidth_stab;
    d.pllNoiseBandwidth_pull = settings.pllNoiseBandwidth_pull;
    d.pllNoiseBandwidth_stab = settings.pllNoiseBandwidth_stab;
    d.filter_pullinMS = settings.filter_pullinMS;
    d.trackInit_MS = settings.trackInit_MS;
    d.carrierAidCode = settings.carrierAidCode;
    d.carrierAidCodeMaxHz = settings.carrierAidCodeMaxHz;
    d.TrkCN0Th = settings.TrkCN0Th;
    d.CNo_Th = settings.CNo_Th;
    d.FLL = settings.FLL;
    d.KF = settings.KF;
    d.REACQ_max = settings.REACQ_max;
    d.max_reacqT = settings.max_reacqT;
    d.navSolPeriod = settings.navSolPeriod;
    d.elevationMask = settings.elevationMask;
    d.useTropCorr = settings.useTropCorr;
    d.lsWeight = settings.lsWeight;
    d.raim = settings.raim;
    d.plotTracking = settings.plotTracking;
    d.plotNavPost = settings.plotNavPost;
    d.plotBaiduMap = settings.plotBaiduMap;
    d.navTrackMaxSpeedMps = settings.navTrackMaxSpeedMps;
    d.nmea = settings.nmea;
    d.useParfor = settings.useParfor;
    d.parMaxWorkers = settings.parMaxWorkers;
    d.doNavigation = true;
    d.doPlot = true;
    d.doNmea = true;
    d.doBaiduMap = true;

    dirn = fileparts(outPath);
    if ~isempty(dirn) && ~exist(dirn, 'dir'), mkdir(dirn); end
    fid = fopen(outPath, 'w', 'n', 'UTF-8');
    if fid < 0, error('exportUiDefaults:Write', 'Cannot write %s', outPath); end
    cleaner = onCleanup(@() fclose(fid));
    fwrite(fid, jsonencode(d), 'char');
    fprintf('UI defaults: %s\n', outPath);
end
