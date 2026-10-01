function state=run_tf600_edge_comparison(outputRoot,baselineDir)
%RUN_TF600_EDGE_COMPARISON Fixed 600-kHz FIR, outer soft transitions 3/6/9 us.
% Each fresh run uses all 715 seconds of case 4, PRN 11. Runtime unchanged.
    root=setupPaths(); addpath(fullfile(root,'tests'));
    if nargin<2, baselineDir=fullfile(root,'results','upgrade_v020','full_01','tf600'); end
    assert(~isfolder(outputRoot),'EdgeSweep:OutputExists','Use a fresh output root.'); mkdir(outputRoot);
    state=struct('status','running','phase','preflight','startedAt',char(datetime('now')), ...
        'outputRoot',outputRoot,'baselineDir',baselineDir,'matlabVersion',version, ...
        'bandwidthHz',600e3,'outerSpansUs',[3 6 9],'referenceOuterSpanUs',12,'runs',{{}});
    [~,head]=system('git rev-parse HEAD'); state.gitHead=strtrim(head);
    state.scriptHash=frontendHash(fileread([mfilename('fullpath') '.m'])); checkpoint();
    try
        base=jsondecode(fileread(fullfile(baselineDir,'validation_config.json')));
        baseline=jsondecode(fileread(fullfile(baselineDir,'validation_summary.json')));
        assert(baseline.complete && base.msToProcess==715000 && baseline.recordedMs==715000);
        baseTf=TFBlankerV1(base);
        assert(baseTf.Config.stopbandWidthHz==600e3 && baseTf.Config.triangleSpanUs==12);
        prior=jsondecode(fileread(fullfile(fileparts(baselineDir),'source_manifest.json')));
        current=prior;
        for k=1:numel(prior)
            path=prior(k).path; current(k).textHash=frontendHash(fileread(fullfile(root,path)));
            if startsWith(path,['tests' filesep]) || strcmp(path,fullfile('core','runProbeIf.m')), continue; end
            assert(strcmp(current(k).textHash,prior(k).textHash), ...
                'EdgeSweep:ReceiverChanged','Runtime differs from reference: %s',path);
        end
        writeJson(fullfile(outputRoot,'source_manifest.json'),current);
        info=dir(fullfile(base.filePath,base.fileName));
        state.inputFile=struct('path',fullfile(base.filePath,base.fileName),'bytes',info.bytes,'modified',info.date);
        state.receiverMatchesBaseline=true; state.phase='edge_verification'; checkpoint();
        verify_tf_soft_edges(fullfile(outputRoot,'verification'));
        spans=[3 6 9]; configs=cell(1,3); runDirs=cell(1,3); plans=cell(1,3);
        for k=1:3
            cfg=base; cfg.Frontend.TF.triangleSpanUs=spans(k);
            cfg.tag=sprintf('04_2700_n50dBm_tf600_edge%gus',spans(k));
            normalized=cfg; normalized.tag=base.tag;
            normalized.Frontend.TF=rmfield(normalized.Frontend.TF,'triangleSpanUs');
            assert(isequaln(normalized,base),'Only edge span and tag may change.');
            tf=TFBlankerV1(cfg);
            assert(strcmp(tf.Info.coefficientHash,baseTf.Info.coefficientHash));
            configs{k}=cfg; runDirs{k}=fullfile(outputRoot,'full',sprintf('edge%gus',spans(k)));
            plans{k}=struct('requestedOuterSpanUs',spans(k),'resolvedTF',tf.Config, ...
                'coefficientHash',tf.Info.coefficientHash,'runDir',runDirs{k});
        end
        writeJson(fullfile(outputRoot,'experiment_plan.json'),plans);
        for k=1:3
            state.phase=sprintf('short_edge%gus',spans(k)); checkpoint();
            cfg=configs{k}; cfg.msToProcess=30000;
            rd=fullfile(outputRoot,'short',sprintf('edge%gus',spans(k)));
            runOne(cfg,rd);
        end
        for k=1:3
            state.phase=sprintf('full_edge%gus',spans(k)); checkpoint();
            entry=runOne(configs{k},runDirs{k}); state.runs{end+1}=entry; checkpoint();
        end
        state.phase='comparison'; checkpoint();
        compare_tf_validation([runDirs {baselineDir}],fullfile(outputRoot,'comparison'));
        state.status='complete'; state.phase='done'; state.finishedAt=char(datetime('now')); checkpoint();
    catch ME
        state.status='failed'; state.errorIdentifier=ME.identifier; state.error=ME.message;
        state.finishedAt=char(datetime('now')); checkpoint(); rethrow(ME);
    end
    function checkpoint()
        state.updatedAt=char(datetime('now')); writeJson(fullfile(outputRoot,'experiment_status.json'),state);
        fprintf('TF600 edge sweep: %s %s (%s)\n',state.status,state.phase,state.updatedAt);
    end
end

function entry=runOne(cfg,rd)
    assert(~isfolder(rd)); mkdir(rd); path=fullfile(rd,'validation_config.json'); writeJson(path,cfg);
    start=tic; report=[];
    captured=evalc('report=runFromJsonConfig(path,''outDir'',rd,''openBaiduBrowser'',false,''closeFigures'',true);');
    elapsed=toc(start); writeText(fullfile(rd,'matlab.log'),captured);
    assert(report.ok,'EdgeSweep:Pipeline','Inspect failed run in %s',rd);
    entry=summarize_tf_validation(rd,cfg.msToProcess); entry.elapsedSec=elapsed;
    writeJson(fullfile(rd,'validation_summary.json'),entry);
    assert(entry.complete,'EdgeSweep:Incomplete','Incomplete run in %s',rd);
    fprintf('TF600 edge %g us: %d ms complete in %.1f s\n',cfg.Frontend.TF.triangleSpanUs,cfg.msToProcess,elapsed);
end

function writeJson(path,value), writeText(path,jsonencode(value,'PrettyPrint',true)); end
function writeText(path,value)
    fid=fopen(path,'w','n','UTF-8'); assert(fid>=0); cleanup=onCleanup(@() fclose(fid));
    fprintf(fid,'%s\n',value);
end
