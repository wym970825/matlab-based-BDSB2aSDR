function completion = run_exp00_case(caseIndex, phase)
%RUN_EXP00_CASE Replay one accepted full PB configuration through TF v1.
% Called in an isolated R2024b process by supervise_exp00.py. Receiver
% algorithms are not modified. Preflight checks every old effective field;
% only frontend selection and output/execution metadata may differ.
    root=setupPaths();
    addpath(fullfile(root,'docs','semiphysical_recompute'));
    base=fullfile(root,'results','Exp00-newTFPB');
    plan=jsondecode(fileread(fullfile(base,'experiment_plan.json')));
    item=plan.cases(caseIndex); rd=item.outputDir;
    completion=struct('ok',false,'caseIndex',caseIndex,'phase',phase,'matlabVersion',version);
    try
        cfg=jsondecode(fileread(item.configPath));
        old=jsondecode(fileread(fullfile(item.oldResultDir,'effective_settings.json')));
        s=resolveFrontendSettings(initSettings(cfg));
        differences=compareOld(old,s,'');
        assert(isempty(differences),'Exp00:ConfigDrift','PB settings differ: %s',strjoin(differences,', '));
        assert(s.msToProcess==715000 && s.numberOfChannels==12 && s.useParfor && s.parMaxWorkers==4);
        assert(isequal(s.acqSatelliteList,1:20) && s.Frontend.TF.stopbandWidthHz==800e3);
        assert(s.Frontend.TF.triangleSpanUs==3 && s.Frontend.TF.effectiveTaps==641);
        preflight=struct('ok',true,'oldSettingsDifferences',{differences}, ...
            'allowedChanges',{{'Frontend','EnablePB','resultRoot','tempdataSvPth','tag','outDir','do* execution controls'}}, ...
            'matlabVersion',version,'resolvedFrontend',s.Frontend,'effectiveSettings',s);
        writeJson(fullfile(rd,'preflight.json'),preflight);
        if strcmp(phase,'preflight')
            completion.ok=true;
        else
            assert(ismember(phase,{'smoke','full'}));
            jobDir=getenv('B2A_JOB_DIR'); assert(~isempty(jobDir));
            if ~isfolder(jobDir), mkdir(jobDir); end
            cluster=parcluster('local'); cluster.JobStorageLocation=jobDir;
            pool=parpool(cluster,4); assert(pool.NumWorkers==4);
            poolCleanup=onCleanup(@() delete(pool));
            if strcmp(phase,'smoke')
                rd=fullfile(base,'_runtime','smoke',item.id);
                assert(~isfolder(rd),'Exp00:ExistingSmoke','Smoke already exists.'); mkdir(rd);
                cfg.msToProcess=5000; cfg.tag=[cfg.tag '_smoke'];
                cfg.doNavigation=false; cfg.doNmea=false; cfg.doPlot=false;
                cfg.outDir=rd; cfg.resultRoot=rd; cfg.tempdataSvPth=fullfile(rd,'temp');
            end
            assert(~isfile(fullfile(rd,'report.json')),'Exp00:ExistingRun','Refusing to overwrite a previous run.');
            configPath=fullfile(rd,'run_config.json'); writeJson(configPath,cfg);
            diary(fullfile(rd,'matlab.log')); diaryCleanup=onCleanup(@() diary('off'));
            started=tic;
            report=runFromJsonConfig(configPath,'outDir',rd,'openBaiduBrowser',false,'closeFigures',true);
            completion.elapsedSec=toc(started); completion.outputDir=rd;
            assert(report.ok,'Exp00:Pipeline','%s: %s',report.stage,report.error);
            actual=load(fullfile(rd,'ui_results.mat'),'settings');
            if strcmp(phase,'full')
                differences=compareOld(old,actual.settings,'');
                assert(isempty(differences),'Exp00:ActualConfigDrift','Actual settings differ: %s',strjoin(differences,', '));
                audit=audit_semiphysical_run(rd); completion.audit=audit;
                assert(audit.ok,'Exp00:Audit','%s',strjoin(audit.issues,'; '));
            end
            finals=dir(fullfile(rd,'temp','Trk_Prn_*_final.mat')); entries=cell(1,numel(finals));
            assert(~isempty(finals),'Exp00:NoTracks','No final tracks.');
            for k=1:numel(finals)
                saved=load(fullfile(finals(k).folder,finals(k).name),'finalTRes'); tr=saved.finalTRes;
                normal=tr.trk_state(1:end-1)~=9 & tr.trk_state(2:end)~=9;
                delta=diff(tr.absoluteSample)-tr.frontendSampleCount(1:end-1);
                boundary=nnz(tr.frontendBoundaryFlag);
                valid=all(tr.frontendValidCount==tr.frontendSampleCount) && all(tr.frontendSampleCount>0);
                complete=numel(tr.I_P)==cfg.msToProcess && all(isfinite(tr.I_P)) && all(isfinite(tr.absoluteSample));
                v=tr.B2a_CNo(isfinite(tr.B2a_CNo)&tr.B2a_CNo>0);
                entries{k}=struct('prn',tr.PRN,'recordedMs',numel(tr.I_P),'complete',complete, ...
                    'frontendMode',tr.frontendInfo.mode,'frontendConfigHash',tr.frontendInfo.configHash, ...
                    'frontendAllSamplesValid',valid,'boundaryEpochs',boundary, ...
                    'normalTimelineContinuous',all(delta(normal)==0),'reacqMs',nnz(tr.trk_state==9), ...
                    'finiteS4',nnz(isfinite(tr.S4)),'medianCNo',median(v), ...
                    'meanWeight',mean(tr.frontendMeanWeight),'timestampMs',nnz(isfinite(tr.Timestamp)));
                assert(complete && valid && boundary==0 && all(delta(normal)==0), ...
                    'Exp00:TrackIntegrity','Track integrity failed for PRN %d.',tr.PRN);
                assert(strcmp(tr.frontendInfo.mode,'tf_v1') && ...
                    strcmp(tr.frontendInfo.configHash,actual.settings.Frontend.configHash));
                clear saved tr
            end
            completion.tracks=entries; completion.ok=true;
            writeJson(fullfile(rd,'all_tracks_validation.json'),completion);
        end
    catch ME
        completion.errorIdentifier=ME.identifier;
        completion.error=getReport(ME,'extended','hyperlinks','off');
        fprintf(2,'%s\n',completion.error);
    end
    completion.finishedAt=char(datetime('now'));
    path=getenv('B2A_COMPLETION_PATH'); assert(~isempty(path)); writeJson(path,completion);
end

function differences=compareOld(old,current,prefix)
% Compare all recorded old fields, not only the original partial JSON.
    differences={}; names=fieldnames(old);
    for k=1:numel(names)
        name=names{k}; path=[prefix name];
        if isempty(prefix) && ismember(name,{'Frontend','EnablePB','resultRoot','tempdataSvPth','outDir','tag'}), continue; end
        if ~isfield(current,name), differences{end+1}=path; continue; end %#ok<AGROW>
        a=old.(name); b=current.(name);
        if isstruct(a) && isstruct(b)
            differences=[differences compareOld(a,b,[path '.'])]; %#ok<AGROW>
        elseif isempty(a) && isnumeric(b) && isscalar(b) && isnan(b)
            % JSON null round-trips reference-coordinate NaNs.
        elseif (isnumeric(a)||islogical(a)) && (isnumeric(b)||islogical(b))
            if ~isequaln(double(a(:)),double(b(:))), differences{end+1}=path; end %#ok<AGROW>
        elseif ~isequaln(a,b)
            differences{end+1}=path; %#ok<AGROW>
        end
    end
end

function writeJson(path,value)
    fid=fopen(path,'w','n','UTF-8'); assert(fid>=0); cleanup=onCleanup(@() fclose(fid));
    fprintf(fid,'%s\n',jsonencode(value,'PrettyPrint',true));
end
