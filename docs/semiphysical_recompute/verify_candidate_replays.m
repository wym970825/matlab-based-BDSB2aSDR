function evidence = verify_candidate_replays()
% Verify isolated fixes against completed RF tracking and PVT products.
root=fileparts(fileparts(fileparts(mfilename('fullpath'))));
base=fullfile(root,'results','semiphysical_recompute','20260929_debug_fixed_r2024b','dme_free');
out=fullfile(root,'results','semiphysical_recompute','20260930_restart_isolated');
candidate=fullfile(out,'candidate_code');
setupPaths; addpath(candidate,'-begin');
cleanup=onCleanup(@() rmpath(candidate));
data=load(fullfile(base,'ui_results.mat'),'settings','results','navSolutions');
s=data.settings;
channels=data.results.channel;
ch=find([channels.PRN]==11,1);
s.msToProcess=3000;
s.tempdataSvPth=fullfile(out,'candidate_tracking_3s');
if ~isfolder(s.tempdataSvPth), mkdir(s.tempdataSvPth); end
tr=trackOneChannel(channels(ch),s,ch,8);
original=load(fullfile(base,'temp','Trk_Prn_11_final.mat'),'finalTRes');
evidence.tracking=struct('samples',numel(tr.I_P), ...
    'maxPromptDifference',max(abs(tr.I_P-original.finalTRes.I_P(1:3000))), ...
    'maxSampleDifference',max(abs(tr.absoluteSample-original.finalTRes.absoluteSample(1:3000))));
assert(evidence.tracking.maxPromptDifference==0 && evidence.tracking.maxSampleDifference==0);
clear original tr
tracks=TrackResults2.createEmptyArray(data.settings.numberOfChannels);
for k=find([channels.PRN]>0)
    original=load(fullfile(base,'temp',sprintf('Trk_Prn_%02d_final.mat',channels(k).PRN)), 'finalTRes');
    tracks(k)=TrackResults2.fromStruct(original.finalTRes);
end
clear original
[nav,~]=runNavigation(tracks,data.settings);
valid=isfinite(data.navSolutions.latitude) & isfinite(nav.latitude);
evidence.navigation=struct('fixesBefore',nnz(isfinite(data.navSolutions.latitude)), ...
    'fixesAfter',nnz(isfinite(nav.latitude)), ...
    'maxLatitudeDifference',max(abs(nav.latitude(valid)-data.navSolutions.latitude(valid))), ...
    'maxLongitudeDifference',max(abs(nav.longitude(valid)-data.navSolutions.longitude(valid))), ...
    'maxHeightDifference',max(abs(nav.height(valid)-data.navSolutions.height(valid))), ...
    'medianDopBefore',median(data.navSolutions.DOP(:,valid),2).', ...
    'medianDopAfter',median(nav.DOP(:,valid),2).');
assert(evidence.navigation.fixesBefore==evidence.navigation.fixesAfter);
assert(evidence.navigation.maxLatitudeDifference<1e-9 && ...
    evidence.navigation.maxLongitudeDifference<1e-9 && ...
    evidence.navigation.maxHeightDifference<1e-4, 'Candidate changed the PVT solution.');
evidence.ok=true;
save(fullfile(out,'candidate_navigation.mat'),'nav','-v7.3');
fid=fopen(fullfile(out,'candidate_replay_evidence.json'),'w','n','UTF-8');
fprintf(fid,'%s\n',jsonencode(evidence,'PrettyPrint',true)); fclose(fid);
disp(evidence);
disp(evidence.navigation);
end
