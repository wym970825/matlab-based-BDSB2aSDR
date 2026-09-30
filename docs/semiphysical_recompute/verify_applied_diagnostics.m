function checks = verify_applied_diagnostics(runRoot)
% Verify final source files, never a candidate directory on the MATLAB path.
arguments
    runRoot (1,1) string
end
projectRoot = fileparts(fileparts(fileparts(mfilename('fullpath'))));
assert(isfile(fullfile(runRoot,'fixes_applied.json')), ...
    'Apply the verified candidates only after the frozen experiments finish.');
setupPaths();
clear Calc_CNo_PLD leastSquarePos trackOneChannel NH_stateMachine scint_calculator TrackResults2
sources = {'include/Calc_CNo_PLD.m','common/leastSquarePos.m', ...
    'tracking/trackOneChannel.m','channelCtrl/NH_stateMachine.m', ...
    'channelCtrl/scint_calculator.m','channelCtrl/TrackResults2.m'};
resolved = struct();
for k=1:numel(sources)
    [~,name]=fileparts(sources{k});
    actual=which(name);
    expected=fullfile(projectRoot,sources{k});
    assert(strcmpi(strrep(actual,'\','/'),strrep(expected,'\','/')), ...
        'Unexpected active source for %s: %s',name,actual);
    resolved.(name)=actual;
end
files=dir(fullfile(projectRoot,'tests','test_*.m'));
names={files.name};
names=names(~strcmp(names,'test_batch_dir_for_one_settings.m'));
paths=cellfun(@(x) fullfile(projectRoot,'tests',x),names,'UniformOutput',false);
testLog=evalc('results=runtests(paths);');
batchLog=evalc('batchResult=test_batch_dir_for_one_settings();');
checks=struct('ok',all([results.Passed]) && batchResult.ok, ...
    'passed',nnz([results.Passed]),'failed',nnz([results.Failed]), ...
    'incomplete',nnz([results.Incomplete]),'batchOrchestration',batchResult, ...
    'matlabVersion',version,'release',version('-release'), ...
    'checkedAt',string(datetime('now')),'activeSources',resolved);
stem=fullfile(runRoot,"post_apply_"+version('-release'));
save(stem+".mat",'results','checks');
writeText(stem+".log",testLog+string(newline)+batchLog);
writeText(stem+".json",jsonencode(checks,'PrettyPrint',true));
if strcmp(version('-release'),'2026a')
    writeText(fullfile(runRoot,'post_apply_checks.json'), ...
        jsonencode(checks,'PrettyPrint',true));
end
disp(checks);
assert(checks.ok,'Post-application regression failed. See the saved log.');
end

function writeText(file,text)
fid=fopen(file,'w','n','UTF-8'); assert(fid>=0);
cleanup=onCleanup(@() fclose(fid));
fprintf(fid,'%s\n',text);
end
