function run_data1020_recovery_stage(manifestPath, index, action, prn)
%RUN_DATA1020_RECOVERY_STAGE One bounded, serial, restartable batch stage.
% A saved tracking chunk is not a loop-state checkpoint. Incomplete channels
% restart at acquisition; complete final files are preserved byte-for-byte.
    setupPaths; set(groot,'defaultFigureVisible','off'); maxNumCompThreads(1);
    assert(isempty(gcp('nocreate')),'Recovery must not use a parallel pool.');
    m=jsondecode(fileread(manifestPath)); e=m.entries(index); dst=char(e.tfDir);
    assert(ismember(index,[5 6]),'Recovery is scoped to experiments 5 and 6.');
    started=tic; statePath=fullfile(dst,'recovery_state.mat');
    if ~isfolder(dst), mkdir(dst); end
    if strcmp(action,'prepare')
        old=load(fullfile(e.pbDir,'ui_results.mat'),'settings'); baseline=old.settings;
        settings=baseline;
        settings.Frontend=struct('mode','tf_v1','TF',struct( ...
            'centerHz',e.station.frequencyHz-e.centerFrequencyHz, ...
            'stopbandWidthHz',800e3,'triangleSpanUs',3));
        settings.EnablePB=false; settings.parMaxWorkers=1;
        settings.useParfor=false; settings.useParallelAcquisition=false;
        [~,settings.tag]=fileparts(dst); settings.outDir=dst; settings.resultRoot=dst;
        settings.tempdataSvPth=fullfile(dst,'temp');
        settings=resolveFrontendSettings(initSettings(settings));
        dirs={settings.tempdataSvPth,fullfile(dst,'figures','AcqResult'), ...
            fullfile(dst,'figures','trkResult'),fullfile(dst,'figures','navResult')};
        for j=1:numel(dirs), if ~isfolder(dirs{j}), mkdir(dirs{j}); end, end
        audit_data1020_tf_run('conditions',baseline,settings,fullfile(dst,'recovery_condition_check.json'));
        audit_data1020_tf_run('filter',settings,dst);
        if isfile(statePath)
            saved=load(statePath); assert(isequaln(saved.settings,settings),'Recovery settings changed.');
            acqResults=saved.acqResults; channel=saved.channel;
        else
            [fid,k]=openIfFile(settings); cleaner=onCleanup(@() fclose(fid));
            acqResults=runAcquisition(fid,settings,k); clear cleaner;
            channel=preRun2(acqResults,settings);
            assert(isequal(settings.acqSatelliteList(:).',1:63));
            assert(numel(channel)==63);
            if index==5
                expected=[41 33 39 38 27 32 24 25 28 30];
                phase=[17311 8767 5037 18522 19519 2959 15231 3554 1843 12698];
                assert(isequal([channel([channel.PRN]>0).PRN],expected));
                assert(isequal([channel(1:10).codePhase],phase),'Acquisition differs from original logged handoff.');
            end
            saveState(statePath,settings,acqResults,channel);
        end
        initialChannel=preRun2(acqResults,settings); active=find([channel.PRN]>0);
        finalFiles=dir(fullfile(settings.tempdataSvPth,'Trk_Prn_*_final.mat'));
        found=[]; reused=struct([]);
        for j=1:numel(finalFiles)
            path=fullfile(finalFiles(j).folder,finalFiles(j).name);
            S=load(path,'finalTRes'); t=S.finalTRes;
            c=find([initialChannel.PRN]==double(t.PRN));
            assert(isscalar(c),'Final PRN absent/duplicated in captured channels.');
            assert(double(t.absoluteSample(1))==initialChannel(c).trackStartAbs, ...
                'Saved PRN %d has a different acquisition sample origin.',t.PRN);
            assert(strcmp(t.frontendInfo.configHash,acqResults.frontendInfo.configHash), ...
                'Saved PRN %d frontend hash differs.',t.PRN);
            assert(numel(t.I_P)>0 && numel(t.I_P)<=settings.msToProcess);
            found(end+1)=double(t.PRN); %#ok<AGROW>
            row=struct('PRN',double(t.PRN),'recordedEpochs',numel(t.I_P), ...
                'firstAbsoluteSample',double(t.absoluteSample(1)), ...
                'newAcquisitionOriginMatches',true,'frontendHashMatches',true,'sourceMat',path);
            if isempty(reused), reused=row; else, reused(end+1)=row; end %#ok<AGROW>
            clear S t;
        end
        assert(numel(unique(found))==numel(found));
        if index==5, assert(all(ismember([24 27 28 32 33 38 39 41],found))); end
        missing=[channel(active).PRN]; missing=missing(~ismember(missing,found));
        archive=fullfile(m.outputRoot,'recovery_archive',sprintf('exp%02d',index));
        if ~isfolder(archive), mkdir(archive); end
        for name={'ui_config.json','report.json'}
            source=fullfile(dst,name{1}); backup=fullfile(archive,['before_recovery_' name{1}]);
            if isfile(source)&&~isfile(backup), copyfile(source,backup); end
        end
        writeJson(fullfile(dst,'ui_config.json'),settings);
        writeJson(fullfile(dst,'comparison_origin.json'),struct('pbDir',e.pbDir,'station',e.station, ...
            'rfCenterHz',e.centerFrequencyHz,'tfDigitalCenterHz',settings.Frontend.TF.centerHz, ...
            'resourceOnlyChange','Crash recovery: serial acquisition and tracking, one process, one computational thread, no pool.'));
        writeJson(fullfile(dst,'recovery_plan.json'),struct('experimentNumber',index, ...
            'sourceId',e.sourceId,'acquiredPrns',[channel(active).PRN], ...
            'reusedFinals',reused,'missingPrns',missing,'loopStateCheckpointAvailable',false, ...
            'incompleteChannelsRestartFromAcquisition',true,'parallelPoolUsed',false));
        fprintf('RECOVERY PREPARED %02d: reuse=%s missing=%s\n',index,mat2str(found),mat2str(missing));
    elseif strcmp(action,'track')
        saved=load(statePath); settings=saved.settings; channel=saved.channel; acqResults=saved.acqResults;
        assert(~settings.useParfor && ~settings.useParallelAcquisition && settings.parMaxWorkers==1);
        c=find([channel.PRN]==prn); assert(isscalar(c));
        finalPath=fullfile(settings.tempdataSvPth,sprintf('Trk_Prn_%02d_final.mat',prn));
        if isfile(finalPath)
            S=load(finalPath,'finalTRes');
            assert(S.finalTRes.PRN==prn && numel(S.finalTRes.I_P)>0);
            fprintf('RECOVERY SKIP existing final PRN %02d\n',prn); return
        end
        archive=fullfile(m.outputRoot,'recovery_archive',sprintf('exp%02d',index), ...
            sprintf('prn%02d_%s',prn,char(datetime('now','Format','yyyyMMdd_HHmmss'))));
        partial=dir(fullfile(settings.tempdataSvPth,sprintf('Trk_Prn_%02d_*.mat',prn)));
        if ~isempty(partial), mkdir(archive); end
        for j=1:numel(partial)
            source=fullfile(partial(j).folder,partial(j).name);
            assert(containsProjectPath(source,m.outputRoot)&&containsProjectPath(archive,m.outputRoot));
            movefile(source,fullfile(archive,partial(j).name));
        end
        progress=fullfile(dst,sprintf('tracking_progress_prn%02d.json',prn));
        if isfile(progress)
            if ~isfolder(archive), mkdir(archive); end
            copyfile(progress,fullfile(archive,'before_recovery_progress.json'));
        end
        initial=preRun2(acqResults,settings);
        [path,chOut]=trackOneChannel(initial(c),settings,c,nnz([initial.PRN]>0),true);
        assert(isfile(path));
        names=fieldnames(channel(c));
        for j=1:numel(names), if isfield(chOut,names{j}), channel(c).(names{j})=chOut.(names{j}); end, end
        saveState(statePath,settings,acqResults,channel);
        writeJson(fullfile(dst,sprintf('recovery_prn%02d_complete.json',prn)), ...
            struct('PRN',prn,'finalPath',char(path),'fromAcquisitionStart',true, ...
            'splicedWithOldChunks',false,'elapsedSeconds',toc(started)));
    elseif strcmp(action,'finish')
        finalize_data1020_saved_run(manifestPath,index);
        old=load(fullfile(e.pbDir,'ui_results.mat'),'settings');
        elapsed=stageElapsed(dst)+toc(started);
        audit_data1020_tf_run('completed',dst,old.settings,elapsed);
    else
        error('Unknown recovery action: %s',action);
    end
    timing=struct('experimentNumber',index,'action',action,'elapsedSeconds',toc(started), ...
        'completedAtUtc',char(datetime('now','TimeZone','UTC')),'parallelPoolUsed',false);
    name=['recovery_timing_' action]; if nargin>=4, name=sprintf('%s_%02d',name,prn); end
    writeJson(fullfile(dst,[name '.json']),timing);
    close all force;
end

function saveState(path,settings,acqResults,channel)
    temporary=[path '.tmp.mat'];
    save(temporary,'settings','acqResults','channel','-v7.3'); movefile(temporary,path,'f');
end
function writeJson(path,value)
    fid=fopen(path,'w','n','UTF-8'); assert(fid>0); c=onCleanup(@() fclose(fid)); %#ok<NASGU>
    fprintf(fid,'%s\n',jsonencode(value,'PrettyPrint',true));
end
function yes=containsProjectPath(path,root)
    absolute=char(java.io.File(path).getCanonicalPath()); base=char(java.io.File(root).getCanonicalPath());
    yes=startsWith(lower(absolute),[lower(base) filesep]);
end
function seconds=stageElapsed(dst)
    files=dir(fullfile(dst,'recovery_timing_*.json')); seconds=0;
    for k=1:numel(files)
        if contains(files(k).name,'finish'), continue; end
        value=jsondecode(fileread(fullfile(files(k).folder,files(k).name)));
        seconds=seconds+value.elapsedSeconds;
    end
end
