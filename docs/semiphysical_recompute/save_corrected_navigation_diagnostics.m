function info=save_corrected_navigation_diagnostics(outputDir,reviewDir)
% Recompute only DOP diagnostics from the recorded final azimuth/elevation.
% Position/time/ephemeris observations are not re-estimated or overwritten.
data=load(fullfile(outputDir,'ui_results.mat'),'settings','navSolutions','eph');
navSolutions=data.navSolutions; settings=data.settings; eph=data.eph;
available=false(size(navSolutions.latitude));
for k=1:numel(available)
    if ~isfinite(navSolutions.latitude(k)), continue; end
    used=navSolutions.raim.usedPRN{k};
    prns=zeros(size(navSolutions.el,1),1); prns(1:size(navSolutions.PRN,1))=navSolutions.PRN(:,k);
    mask=ismember(prns,used) & isfinite(navSolutions.el(:,k)) & isfinite(navSolutions.az(:,k));
    el=deg2rad(navSolutions.el(mask,k)); az=deg2rad(navSolutions.az(mask,k));
    G=[-cos(el).*sin(az),-cos(el).*cos(az),-sin(el),ones(numel(el),1)];
    if size(G,1)<4 || rank(G)<4, continue; end
    Q=(G.'*G)\eye(4);
    navSolutions.DOP(:,k)=[sqrt(trace(Q));sqrt(trace(Q(1:3,1:3))); ...
        sqrt(Q(1,1)+Q(2,2));sqrt(Q(3,3));sqrt(Q(4,4))];
    available(k)=true;
end
if ~isfolder(reviewDir), mkdir(reviewDir); end
diagnosticSource=struct('originalRun',string(outputDir),'correction','ECEF HDOP/VDOP -> local ENU', ...
    'positionAndTimeUnchanged',true,'correctedEpochs',nnz(available));
save(fullfile(reviewDir,'navigation_corrected.mat'),'navSolutions','settings','eph','diagnosticSource','-v7.3');
exportSettings=settings; exportSettings.nmea.fileName='pvt_corrected.nmea';
nmeaPath=exportNmea(navSolutions,exportSettings,'eph',eph,'outDir',reviewDir);
info=struct('correctedEpochs',nnz(available),'nmeaPath',nmeaPath, ...
    'maxLatitudeChange',max(abs(navSolutions.latitude-data.navSolutions.latitude),[],'omitnan'), ...
    'maxLongitudeChange',max(abs(navSolutions.longitude-data.navSolutions.longitude),[],'omitnan'));
fid=fopen(fullfile(reviewDir,'navigation_correction.json'),'w','n','UTF-8');
fprintf(fid,'%s\n',jsonencode(info,'PrettyPrint',true)); fclose(fid);
end
