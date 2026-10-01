function summary=verify_config_entrypoint_if(outputRoot)
%VERIFY_CONFIG_ENTRYPOINT_IF Compare both real-IF entry paths and an archive.
% Five seconds include acquisition, INIT and the transition to LONG. This
% checks routing/configuration, not long-duration S4 accuracy or availability.
    root=setupPaths(); assert(~isfolder(outputRoot)); mkdir(outputRoot);
    baselineDir=fullfile(root,'results','tf_parameter_grid','run_01','full','tf800_edge3us');
    cfg=jsondecode(fileread(fullfile(baselineDir,'validation_config.json')));
    cfg.msToProcess=5000; cfg.tag='entry_parity_tf800_3us';
    path=fullfile(outputRoot,'input.json'); writeJson(path,cfg);
    jsonDir=fullfile(outputRoot,'json'); structDir=fullfile(outputRoot,'settings');
    jsonReport=[]; settingsReport=[];
    log=evalc('jsonReport=runFromJsonConfig(path,''outDir'',jsonDir,''openBaiduBrowser'',false,''closeFigures'',true);');
    writeText(fullfile(outputRoot,'json.log'),log); assert(jsonReport.ok);
    args=namedargs2cell(cfg); settings=initSettings(args{:}); %#ok<NASGU> Used by evalc below.
    log=evalc('settingsReport=runFromSettings(settings,''outDir'',structDir,''openBaiduBrowser'',false,''closeFigures'',true);');
    writeText(fullfile(outputRoot,'settings.log'),log); assert(settingsReport.ok);
    a=load(fullfile(jsonDir,['run_B2a_' cfg.tag '.mat']),'results');
    b=load(fullfile(structDir,['run_B2a_' cfg.tag '.mat']),'results');
    verifySettingsA=rmfield(a.results.settings,{'resultRoot','tempdataSvPth','outDir'});
    verifySettingsB=rmfield(b.results.settings,{'resultRoot','tempdataSvPth','outDir'});
    assert(isequaln(verifySettingsA,verifySettingsB),'Effective settings differ.');
    trA=trackResultsToStruct(a.results.trackResults); trA=trA([trA.PRN]==11);
    trB=trackResultsToStruct(b.results.trackResults); trB=trB([trB.PRN]==11);
    assert(isscalar(trA) && isscalar(trB) && numel(trA.I_P)==5000 && numel(trB.I_P)==5000);
    assert(isequaln(a.results.acqResults,b.results.acqResults),'Acquisition outputs differ.');
    assert(isequaln(trA,trB),'Tracking outputs differ between entry points.');
    assert(strcmp(trA.frontendInfo.configHash,trB.frontendInfo.configHash));
    oldReport=jsondecode(fileread(fullfile(baselineDir,'report.json')));
    old=load(fullfile(baselineDir,['run_B2a_' oldReport.tag '.mat']),'results');
    oldTrack=trackResultsToStruct(old.results.trackResults); oldTrack=oldTrack([oldTrack.PRN]==11);
    fields={'I_P','Q_P','Pilot_I_P','Pilot_Q_P','codeFreq','carrFreq','absoluteSample', ...
        'trk_state','cur_state','dllDiscr','pllDiscr','frontendMeanWeight', ...
        'frontendSampleCount','frontendValidCount','PilotCNo','B2a_CNo','S4','S4_ori'};
    comparisons=cell(size(fields));
    for k=1:numel(fields)
        name=fields{k}; actual=trA.(name); expected=oldTrack.(name); expected=expected(1:numel(actual));
        assert(isequal(isnan(actual),isnan(expected)) && isequal(isinf(actual),isinf(expected)));
        finite=isfinite(actual)&isfinite(expected); maxError=0; relativeError=0;
        if any(finite)
            maxError=max(abs(actual(finite)-expected(finite)));
            relativeError=maxError/max(1,max(abs(expected(finite))));
        end
        exact=isequaln(actual,expected);
        if ismember(name,{'absoluteSample','trk_state','cur_state','frontendSampleCount','frontendValidCount'})
            assert(exact,'Discrete archive prefix differs: %s',name);
        else
            assert(relativeError<1e-12,'Numerical archive prefix differs: %s',name);
        end
        comparisons{k}=struct('field',name,'elements',numel(actual),'finiteElements',nnz(finite), ...
            'exact',exact,'maxAbsoluteError',maxError,'relativeError',relativeError);
    end
    summary=struct('passed',true,'prn',11,'recordedMs',numel(trA.I_P), ...
        'effectiveSettingsEqual',true,'acquisitionExactlyEqual',true,'trackingExactlyEqual',true, ...
        'frontendHash',trA.frontendInfo.configHash,'archivePrefixComparisons',{comparisons}, ...
        'baselineDir',baselineDir,'scope','Five seconds; no finite S4 expected before 150-second warmup.', ...
        'scriptHash',frontendHash(fileread([mfilename('fullpath') '.m'])));
    writeJson(fullfile(outputRoot,'entrypoint_if_summary.json'),summary);
end

function writeJson(path,value), writeText(path,jsonencode(value,'PrettyPrint',true)); end
function writeText(path,value)
    fid=fopen(path,'w','n','UTF-8'); assert(fid>=0); cleaner=onCleanup(@() fclose(fid));
    fprintf(fid,'%s\n',value);
end
