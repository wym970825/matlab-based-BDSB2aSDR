function evidence=audit_start_offset_sensitivity(outputDir,reviewDir,newOffsetMs)
% Change only the local-clock initializer in an isolated navigation replay.
arguments
    outputDir (1,1) string
    reviewDir (1,1) string
    newOffsetMs (1,1) double
end
setupPaths();
data=load(fullfile(outputDir,'ui_results.mat'),'settings','results','navSolutions');
s=data.settings; channels=data.results.channel;
tracks=TrackResults2.createEmptyArray(s.numberOfChannels);
for k=find([channels.PRN]>0)
    d=load(fullfile(outputDir,'temp',sprintf('Trk_Prn_%02d_final.mat',channels(k).PRN)),'finalTRes');
    tracks(k)=TrackResults2.fromStruct(d.finalTRes);
end
clear d calculatePseudoranges
s.startOffset=newOffsetMs;
replayLog=evalc('[nav,~]=runNavigation(tracks,s);');
reference=data.navSolutions;
valid=isfinite(nav.latitude)&isfinite(reference.latitude);
delta=[nav.X(valid)-reference.X(valid);nav.Y(valid)-reference.Y(valid);nav.Z(valid)-reference.Z(valid)];
evidence=struct('originalOffsetMs',data.settings.startOffset,'replayOffsetMs',newOffsetMs, ...
    'referenceValidFixes',nnz(isfinite(reference.latitude)), ...
    'replayValidFixes',nnz(isfinite(nav.latitude)), ...
    'sameEpochSamples',isequal(nav.currMeasSample,reference.currMeasSample), ...
    'maxPositionDifferenceM',max(sqrt(sum(delta.^2,1))), ...
    'maxReceiverTimeDifferenceSec',max(abs(nav.localTime(valid)-reference.localTime(valid))), ...
    'matlabVersion',version, ...
    'note','Same saved correlators; only startOffset changed. Comparison includes R2024b/R2026a numerical differences.');
if ~isfolder(reviewDir), mkdir(reviewDir); end
save(fullfile(reviewDir,'start_offset_sensitivity.mat'),'evidence','nav','s','-v7.3');
writeText(fullfile(reviewDir,'start_offset_sensitivity.json'),jsonencode(evidence,'PrettyPrint',true));
writeText(fullfile(reviewDir,'start_offset_sensitivity.log'),replayLog);
disp(evidence);
end

function writeText(file,value)
fid=fopen(file,'w','n','UTF-8'); assert(fid>=0);
cleanup=onCleanup(@() fclose(fid));
fprintf(fid,'%s\n',value);
end
