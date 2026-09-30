function evidence=verify_candidate_tracking(durationMs)
% A real RF replay spanning the diagnostic warmup boundary with KF disabled.
root=fileparts(fileparts(fileparts(mfilename('fullpath'))));
out=fullfile(root,'results','semiphysical_recompute','20260930_restart_isolated');
base=fullfile(root,'results','semiphysical_recompute','20260929_debug_fixed_r2024b','dme_free');
candidate=fullfile(out,'candidate_code'); setupPaths; addpath(candidate,'-begin');
cleanup=onCleanup(@() rmpath(candidate));
d=load(fullfile(base,'ui_results.mat'),'settings','results');
s=d.settings; assert(~s.KF.enable); s.msToProcess=durationMs;
s.tempdataSvPth=fullfile(out,sprintf('candidate_tracking_%ds',round(durationMs/1000)));
if ~isfolder(s.tempdataSvPth), mkdir(s.tempdataSvPth); end
ch=d.results.channel; c=find([ch.PRN]==11,1);
log=evalc('tr=trackOneChannel(ch(c),s,c,8);');
fid=fopen(fullfile(s.tempdataSvPth,'tracking.log'),'w','n','UTF-8'); fprintf(fid,'%s',log); fclose(fid);
original=load(fullfile(base,'temp','Trk_Prn_11_final.mat'),'finalTRes');
evidence=struct('durationMs',durationMs,'maxPromptDifference', ...
    max(abs(tr.I_P-original.finalTRes.I_P(1:durationMs))), ...
    'maxSampleDifference',max(abs(tr.absoluteSample-original.finalTRes.absoluteSample(1:durationMs))), ...
    'maxCarrierDifference',max(abs(tr.carrFreq-original.finalTRes.carrFreq(1:durationMs))), ...
    'reacqMs',nnz(tr.trk_state==9),'firstFiniteS4Sec',find(isfinite(tr.S4),1)*s.CNoInterval/1000);
evidence.ok=evidence.maxPromptDifference==0 && evidence.maxSampleDifference==0 && evidence.maxCarrierDifference==0;
if durationMs<150000
    assert(all(~isfinite(tr.S4)), 'Unavailable S4 must stay NaN during warmup.');
end
fid=fopen(fullfile(out,sprintf('candidate_tracking_%ds.json',round(durationMs/1000))),'w','n','UTF-8');
fprintf(fid,'%s\n',jsonencode(evidence,'PrettyPrint',true)); fclose(fid);
assert(evidence.ok,'Candidate changed RF tracking with KF disabled.');
disp(evidence);
end
