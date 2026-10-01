function state=run_tf_parameter_grid(outputRoot)
%RUN_TF_PARAMETER_GRID Complete six missing bandwidth/edge combinations.
% Fresh case-4/PRN-11 runs; receiver sources and all other settings frozen.
    root=setupPaths(); addpath(fullfile(root,'tests'));
    baselineDir=fullfile(root,'results','upgrade_v020','full_01','tf600');
    assert(~isfolder(outputRoot),'Grid:OutputExists','Use a fresh output root.'); mkdir(outputRoot);
    state=struct('status','running','phase','preflight','startedAt',char(datetime('now')), ...
        'outputRoot',outputRoot,'baselineDir',baselineDir,'matlabVersion',version, ...
        'bandwidthsHz',[400e3 800e3],'outerSpansUs',[3 6 9],'runs',{{}});
    [~,head]=system('git rev-parse HEAD'); state.gitHead=strtrim(head);
    state.scriptHash=frontendHash(fileread([mfilename('fullpath') '.m'])); checkpoint();
    try
        base=jsondecode(fileread(fullfile(baselineDir,'validation_config.json')));
        baseline=jsondecode(fileread(fullfile(baselineDir,'validation_summary.json')));
        assert(baseline.complete && base.msToProcess==715000 && baseline.recordedMs==715000);
        prior=jsondecode(fileread(fullfile(fileparts(baselineDir),'source_manifest.json')));
        current=prior;
        for k=1:numel(prior)
            path=prior(k).path; current(k).textHash=frontendHash(fileread(fullfile(root,path)));
            if startsWith(path,['tests' filesep]) || strcmp(path,fullfile('core','runProbeIf.m')), continue; end
            assert(strcmp(current(k).textHash,prior(k).textHash), ...
                'Grid:ReceiverChanged','Runtime differs from reference: %s',path);
        end
        writeJson(fullfile(outputRoot,'source_manifest.json'),current);
        info=dir(fullfile(base.filePath,base.fileName)); assert(isscalar(info));
        state.inputFile=struct('path',fullfile(base.filePath,base.fileName),'bytes',info.bytes,'modified',info.date);
        state.receiverMatchesBaseline=true; checkpoint();
        configs={}; runDirs={}; labels={}; plans={};
        for bw=state.bandwidthsHz
            state.phase=sprintf('verification_%gk',bw/1e3); checkpoint();
            verify_tf_soft_edges(fullfile(outputRoot,sprintf('verification_%gk',bw/1e3)),bw);
            verify_tf_soft_edge_fidelity(fullfile(outputRoot,sprintf('fidelity_%gk',bw/1e3)),bw);
            coefficientHash='';
            for span=state.outerSpansUs
                cfg=base; cfg.Frontend.TF.stopbandWidthHz=bw; cfg.Frontend.TF.triangleSpanUs=span;
                label=sprintf('tf%g_edge%gus',bw/1e3,span); cfg.tag=['04_2700_n50dBm_' label];
                normalized=cfg; normalized.tag=base.tag;
                normalized.Frontend.TF=base.Frontend.TF;
                assert(isequaln(normalized,base),'Only bandwidth, edge span and tag may change.');
                tf=TFBlankerV1(cfg);
                if isempty(coefficientHash), coefficientHash=tf.Info.coefficientHash; end
                assert(strcmp(coefficientHash,tf.Info.coefficientHash));
                rd=fullfile(outputRoot,'full',label);
                configs{end+1}=cfg; runDirs{end+1}=rd; labels{end+1}=label; %#ok<AGROW>
                plans{end+1}=struct('label',label,'bandwidthHz',bw,'requestedOuterSpanUs',span, ...
                    'resolvedTF',tf.Config,'coefficientHash',tf.Info.coefficientHash,'runDir',rd); %#ok<AGROW>
            end
        end
        writeJson(fullfile(outputRoot,'experiment_plan.json'),plans);
        for k=1:numel(configs)
            state.phase=['short_' labels{k}]; checkpoint();
            cfg=configs{k}; cfg.msToProcess=30000; runOne(cfg,fullfile(outputRoot,'short',labels{k}));
        end
        for k=1:numel(configs)
            state.phase=['full_' labels{k}]; checkpoint();
            entry=runOne(configs{k},runDirs{k}); state.runs{end+1}=entry; checkpoint();
        end
        state.status='complete'; state.phase='done'; state.finishedAt=char(datetime('now')); checkpoint();
    catch ME
        state.status='failed'; state.errorIdentifier=ME.identifier; state.error=ME.message;
        state.finishedAt=char(datetime('now')); checkpoint(); rethrow(ME);
    end
    function checkpoint()
        state.updatedAt=char(datetime('now')); writeJson(fullfile(outputRoot,'experiment_status.json'),state);
        fprintf('TF parameter grid: %s %s (%s)\n',state.status,state.phase,state.updatedAt);
    end
end

function entry=runOne(cfg,rd)
    assert(~isfolder(rd)); mkdir(rd); path=fullfile(rd,'validation_config.json'); writeJson(path,cfg);
    start=tic; report=[];
    captured=evalc('report=runFromJsonConfig(path,''outDir'',rd,''openBaiduBrowser'',false,''closeFigures'',true);');
    elapsed=toc(start); writeText(fullfile(rd,'matlab.log'),captured);
    assert(report.ok,'Grid:Pipeline','Inspect failed run in %s',rd);
    entry=summarize_tf_validation(rd,cfg.msToProcess); entry.elapsedSec=elapsed;
    writeJson(fullfile(rd,'validation_summary.json'),entry);
    assert(entry.complete,'Grid:Incomplete','Incomplete run in %s',rd);
    fprintf('%s: %d ms complete in %.1f s\n',cfg.tag,cfg.msToProcess,elapsed);
end

function writeJson(path,value), writeText(path,jsonencode(value,'PrettyPrint',true)); end
function writeText(path,value)
    fid=fopen(path,'w','n','UTF-8'); assert(fid>=0); cleanup=onCleanup(@() fclose(fid));
    fprintf(fid,'%s\n',value);
end
