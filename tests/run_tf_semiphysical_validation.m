function manifest=run_tf_semiphysical_validation(caseIndex,durationMs,modes,outputRoot)
%RUN_TF_SEMIPHYSICAL_VALIDATION Serial, reproducible single-PRN real-IF runs.
% Original five-case JSON files/RF are never edited. Existing outputs refused.
    root=setupPaths();
    if nargin<1 || isempty(caseIndex), caseIndex=4; end
    if nargin<2 || isempty(durationMs), durationMs=715000; end
    if nargin<3 || isempty(modes), modes={'pb','tf400','tf600'}; end
    if nargin<4 || isempty(outputRoot)
        outputRoot=fullfile(root,'results','upgrade_v020',char(datetime('now','Format','yyyyMMdd_HHmmss_SSS')));
    end
    assert(ismember(caseIndex,2:5),'TFValidation:Case','Select one of the four interfered cases (2:5).');
    assert(~isfolder(outputRoot),'TFValidation:OutputExists','Use a fresh output directory.');
    mkdir(outputRoot);
    names={'01_dme_free','02_1350_n50dBm','03_1350_n60dBm','04_2700_n50dBm','05_2700_n60dBm'};
    configPath=fullfile(root,'docs','semiphysical_recompute','configs',[names{caseIndex} '.json']);
    original=jsondecode(fileread(configPath));
    assert(durationMs>=1 && durationMs<=original.msToProcess,'TFValidation:Duration','Duration exceeds original experiment.');
    manifest=struct('softwareVersion',strtrim(fileread(fullfile(root,'VERSION'))), ...
        'startedAt',char(datetime('now')),'caseIndex',caseIndex,'configPath',configPath, ...
        'originalConfigHash',frontendHash(original),'prn',11,'durationMs',durationMs, ...
        'modes',{modes},'status','running','runs',[],'outputRoot',outputRoot);
    [~,head]=system('git rev-parse HEAD'); manifest.gitHead=strtrim(head);
    manifest.matlabVersion=version; manifest.computer=computer;
    fileInfo=dir(fullfile(original.filePath,original.fileName));
    manifest.inputFile=struct('path',fullfile(original.filePath,original.fileName), ...
        'bytes',fileInfo.bytes,'modified',fileInfo.date);
    saveSourceManifest(root,outputRoot);
    entries=cell(1,numel(modes));
    writeJson(fullfile(outputRoot,'validation_manifest.json'),manifest);
    for k=1:numel(modes)
        label=char(modes{k}); cfg=original;
        cfg.acqSatelliteList=11; cfg.numberOfChannels=1; cfg.useParfor=false;
        cfg.msToProcess=durationMs; cfg.doNavigation=false; cfg.doNmea=false;
        cfg.doBaiduMap=false; cfg.doPlot=false; cfg.plotTracking=false;
        cfg.tag=[names{caseIndex} '_' label];
        if strcmp(label,'pb') || strcmp(label,'off')
            cfg.Frontend=struct('mode',label);
        else
            assert(ismember(label,{'tf400','tf600','tf800'}),'TFValidation:Mode','Unknown mode.');
            width=str2double(label(3:end))*1000;
            cfg.Frontend=struct('mode','tf_v1','TF',struct('stopbandWidthHz',width));
        end
        runDir=fullfile(outputRoot,label); mkdir(runDir);
        replayPath=fullfile(runDir,'validation_config.json');
        writeJson(replayPath,cfg);
        start=tic;
        captured=evalc('report=runFromJsonConfig(replayPath,''outDir'',runDir,''openBaiduBrowser'',false,''closeFigures'',true);');
        elapsed=toc(start);
        logFile=fopen(fullfile(runDir,'matlab.log'),'w','n','UTF-8');
        fprintf(logFile,'%s',captured); fclose(logFile);
        entry=struct('mode',label,'outDir',runDir,'elapsedSec',elapsed,'pipelineOk',report.ok);
        if report.ok
            try
                entry=summarize_tf_validation(runDir,durationMs);
                entry.elapsedSec=elapsed;
                writeJson(fullfile(runDir,'validation_summary.json'),entry);
            catch ME
                entry.complete=false; entry.errorIdentifier=ME.identifier; entry.error=ME.message;
            end
        else
            entry.complete=false; entry.errorIdentifier=report.errorIdentifier; entry.error=report.error;
        end
        entries{k}=entry;
        if ~entry.complete, manifest.status='failed'; end
        manifest.runs=entries(1:k); writeJson(fullfile(outputRoot,'validation_manifest.json'),manifest);
        fprintf('Validation %s: complete=%d, elapsed=%.1f s, output=%s\n',label,entry.complete,elapsed,runDir);
        assert(entry.complete,'TFValidation:Incomplete','Run %s failed or incomplete; inspect %s.',label,runDir);
    end
    manifest.status='complete'; manifest.finishedAt=char(datetime('now'));
    writeJson(fullfile(outputRoot,'validation_manifest.json'),manifest);
end

function writeJson(file,value)
    fid=fopen(file,'w','n','UTF-8'); assert(fid>=0); cl=onCleanup(@() fclose(fid));
    fprintf(fid,'%s\n',jsonencode(value,'PrettyPrint',true));
end

function saveSourceManifest(root,out)
    folders={'frontend','acquisition','tracking','core','channelCtrl','config', ...
        'include','signal','cn0','common','navigation','mex','batch','tests'};
    rows={};
    for k=1:numel(folders)
        files=dir(fullfile(root,folders{k},'*.m'));
        for j=1:numel(files)
            path=fullfile(files(j).folder,files(j).name);
            rows{end+1}=struct('path',strrep(path,[root filesep],''), ...
                'textHash',frontendHash(fileread(path))); %#ok<AGROW>
        end
    end
    writeJson(fullfile(out,'source_manifest.json'),rows);
end
