function state=run_tf800_comparison(outputRoot,baselineDir)
%RUN_TF800_COMPARISON Validate 800 kHz and compare to archived 600 kHz.
% Only test orchestration changes; receiver source/config defaults stay fixed.
    root=setupPaths(); addpath(fullfile(root,'tests'));
    if nargin<1, outputRoot=fullfile(root,'results','tf600_vs_tf800','run_01'); end
    if nargin<2, baselineDir=fullfile(root,'results','upgrade_v020','full_01','tf600'); end
    assert(~isfolder(outputRoot),'TF800:OutputExists','Use a fresh output root.');
    mkdir(outputRoot);
    state=struct('status','running','phase','preflight','startedAt',char(datetime('now')), ...
        'outputRoot',outputRoot,'baselineDir',baselineDir,'matlabVersion',version);
    [~,head]=system('git rev-parse HEAD'); state.gitHead=strtrim(head);
    state.scriptHash=frontendHash(fileread([mfilename('fullpath') '.m']));
    checkpoint();
    try
        baseline=jsondecode(fileread(fullfile(baselineDir,'validation_summary.json')));
        assert(baseline.complete && baseline.recordedMs==715000,'TF800:Baseline','Incomplete 600-kHz baseline.');
        config600=jsondecode(fileread(fullfile(baselineDir,'validation_config.json')));
        assert(config600.Frontend.TF.stopbandWidthHz==600000);
        prior=jsondecode(fileread(fullfile(fileparts(baselineDir),'source_manifest.json')));
        changed={};
        for k=1:numel(prior)
            path=prior(k).path;
            if startsWith(path,['tests' filesep]) || strcmp(path,fullfile('core','runProbeIf.m')), continue; end
            if ~strcmp(frontendHash(fileread(fullfile(root,path))),prior(k).textHash)
                changed{end+1}=path; %#ok<AGROW>
            end
        end
        assert(isempty(changed),'TF800:ReceiverChanged','Tracking/frontend differs from 600-kHz baseline.');
        state.receiverMatchesBaseline=true;
        state.phase='frontend_tests'; checkpoint();
        captured=evalc("testResults=runtests(fullfile(root,'tests','test_tf_frontend.m'));");
        writeText(fullfile(outputRoot,'frontend_tests.log'),captured);
        rows=arrayfun(@(x) struct('name',x.Name,'passed',x.Passed, ...
            'failed',x.Failed,'incomplete',x.Incomplete,'duration',x.Duration),testResults);
        writeJson(fullfile(outputRoot,'frontend_tests.json'),rows);
        assert(all([testResults.Passed]),'TF800:UnitTests','Frontend tests failed.');
        state.phase='correlation_diagnostics'; checkpoint();
        verify_tf_correlation_fidelity(fullfile(outputRoot,'correlation'),[600e3 800e3]);
        filterRows={};
        for fs=[25e6 30.69e6]
            for bw=[600e3 800e3]
                cfg=config600; cfg.samplingFreq=fs; cfg.Frontend.TF.stopbandWidthHz=bw;
                filter=TFBlankerV1(cfg);
                filterRows{end+1}=struct('samplingFreq',fs,'bandwidthHz',bw, ...
                    'taps',filter.Config.effectiveTaps,'D',filter.Config.D, ...
                    'H',filter.Config.H,'worstStopbandDbOnGrid',filter.Info.worstStopbandDbOnGrid, ...
                    'zeroFrequencyResponseDb',20*log10(abs(sum(filter.Notch))), ...
                    'coefficientHash',filter.Info.coefficientHash); %#ok<AGROW>
            end
        end
        writeJson(fullfile(outputRoot,'filter_response.json'),filterRows);
        state.phase='short_tf800'; checkpoint();
        run_tf_semiphysical_validation(4,30000,{'tf800'},fullfile(outputRoot,'short'));
        state.phase='full_tf800'; checkpoint();
        run_tf_semiphysical_validation(4,715000,{'tf800'},fullfile(outputRoot,'full'));
        run800=fullfile(outputRoot,'full','tf800');
        config800=jsondecode(fileread(fullfile(run800,'validation_config.json')));
        config800.Frontend.TF.stopbandWidthHz=600000; config800.tag=config600.tag;
        assert(isequaln(config600,config800),'TF800:ConfigMismatch','Comparison changes more than bandwidth/tag.');
        state.phase='comparison'; checkpoint();
        compare_tf_validation({baselineDir,run800},fullfile(outputRoot,'comparison'));
        state.status='complete'; state.phase='done'; state.finishedAt=char(datetime('now')); checkpoint();
    catch ME
        state.status='failed'; state.errorIdentifier=ME.identifier;
        state.error=ME.message; state.finishedAt=char(datetime('now')); checkpoint();
        rethrow(ME);
    end

    function checkpoint()
        state.updatedAt=char(datetime('now'));
        writeJson(fullfile(outputRoot,'experiment_status.json'),state);
        fprintf('TF600/800: %s %s (%s)\n',state.status,state.phase,state.updatedAt);
    end
end

function writeJson(path,value)
    writeText(path,jsonencode(value,'PrettyPrint',true));
end

function writeText(path,value)
    fid=fopen(path,'w','n','UTF-8'); assert(fid>=0);
    cleanup=onCleanup(@() fclose(fid)); fprintf(fid,'%s\n',value);
end
