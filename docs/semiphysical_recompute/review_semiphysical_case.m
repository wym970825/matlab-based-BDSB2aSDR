function review = review_semiphysical_case(outputDir, reviewDir)
%REVIEW_SEMIPHYSICAL_CASE Data audit without changing receiver products.
% Position scatter is relative to this run's median, not truth accuracy.
% Raw 1-ms intensity CV includes thermal noise and interference.
arguments
    outputDir (1,1) string
    reviewDir (1,1) string
end
if ~isfolder(reviewDir), mkdir(reviewDir); end
saved = load(fullfile(outputDir, 'ui_results.mat'), 'settings', 'navSolutions', 'results');
s = saved.settings; n = saved.navSolutions;
review = struct('outputDir', outputDir, 'reviewedAt', string(datetime('now')), ...
    'steadyStartSec', 150, 'positionReference', 'within-run median; NOT simulator truth');
review.validation = jsondecode(fileread(fullfile(outputDir, 'validation.json')));
review.parameters = struct('samplingFreq', s.samplingFreq, 'intTime', s.intTime, ...
    'msToProcess', s.msToProcess, 'bandwidthMHz', s.IFBandwidth/1e6, ...
    'thresholdAmplitude', s.PB_settings.Th_static_tracking, ...
    'thresholdDbm', s.Th_static_dBm, 'startOffsetMs', s.startOffset, ...
    'pllPullHz', s.pllNoiseBandwidth_pull, 'pllStableHz', s.pllNoiseBandwidth_stab, ...
    'dllPullHz', s.dllNoiseBandwidth_pull, 'dllStableHz', s.dllNoiseBandwidth_stab, ...
    'FLL', s.FLL.enable, 'KF', s.KF.enable, ...
    'scintCutoffHz', s.scint_fCutoff, 'scintWindowMs', s.scint_bufLen);
review.navigation = struct('epochs', numel(n.latitude), ...
    'validFixes', nnz(isfinite(n.latitude) & isfinite(n.longitude)));
valid = isfinite(n.latitude) & isfinite(n.longitude) & isfinite(n.height);
review.navigation.validFixes = nnz(valid);
review.navigation.invalidEpochs = find(~valid);
review.navigation.invalidEpochSample = n.currMeasSample(~valid);
steadyNav = valid & n.currMeasSample/s.samplingFreq >= review.steadyStartSec;
if ~any(steadyNav), steadyNav = valid; end
review.navigation.raimPassCount = nnz(n.raim.passed);
review.navigation.exclusionEpochs = nnz(n.raim.nExcluded);
review.navigation.raimResidualRmsM = stats(n.raim.residualRms(steadyNav));
review.navigation.raimMaxResidualM = stats(n.raim.maxResidual(steadyNav));
review.navigation.usedSatellites = stats(cellfun(@numel, n.raim.usedPRN(steadyNav)));
review.navigation.medianLatLonHeight = [median(n.latitude(steadyNav)), ...
    median(n.longitude(steadyNav)), median(n.height(steadyNav))];
xyz = [n.X(steadyNav); n.Y(steadyNav); n.Z(steadyNav)];
center = median(xyz, 2);
lat = deg2rad(median(n.latitude(steadyNav))); lon = deg2rad(median(n.longitude(steadyNav)));
R = [-sin(lon), cos(lon), 0; -sin(lat)*cos(lon), -sin(lat)*sin(lon), cos(lat); ...
     cos(lat)*cos(lon), cos(lat)*sin(lon), sin(lat)];
enu = R*(xyz-center);
review.navigation.enuStdM = std(enu, 0, 2).';
review.navigation.horizontalScatterM = stats(hypot(enu(1,:), enu(2,:)));
review.navigation.heightM = stats(n.height(steadyNav));
review.navigation.DOP = median(n.DOP(:,steadyNav), 2).';
review.navigation.dopAudit = dopAudit(n, steadyNav);
files = dir(fullfile(outputDir, 'temp', 'Trk_Prn_*_final.mat'));
tracks = cell(1, numel(files));
for k = 1:numel(files)
    loaded = load(fullfile(files(k).folder, files(k).name), 'finalTRes');
    tr = loaded.finalTRes;
    N = numel(tr.I_P); time = (1:N)*s.intTime;
    idx = time >= review.steadyStartSec & tr.trk_state ~= 9 & tr.trk_state ~= 0;
    cidx = (1:numel(tr.B2a_CNo))*s.CNoInterval*s.intTime >= review.steadyStartSec;
    a = struct('PRN', tr.PRN, 'samples', N, ...
        'finiteSamples', nnz(isfinite(tr.I_P) & isfinite(tr.absoluteSample)), ...
        'reacqMs', nnz(tr.trk_state == 9), ...
        'reacqEvents', nnz(diff([false tr.trk_state == 9]) == 1), ...
        'timestampSamples', nnz(isfinite(tr.Timestamp)), ...
        'nonIncreasingAbsoluteSamples', nnz(diff(tr.absoluteSample) <= 0));
    a.states = unique(double(tr.trk_state));
    a.stateCounts = arrayfun(@(st) nnz(tr.trk_state == st), a.states);
    a.cnoTotalDbHz = stats(tr.B2a_CNo(cidx));
    a.cnoPilotDbHz = stats(tr.PilotCNo(cidx));
    a.cnoDataDbHz = stats(tr.DataCNo(cidx));
    a.cnoMomentAudit = struct('data', momentAudit(tr.I_P, tr.Q_P, s.CNoInterval), ...
        'pilot', momentAudit(tr.Pilot_I_P, tr.Pilot_Q_P, s.CNoInterval));
    a.cnoPatchAudit = cnoPatchAudit(tr,s);
    a.pbDuty = stats(tr.eta(idx));
    a.pbPowerReductionDb = stats(tr.Ppre(idx)-tr.Ppost(idx));
    a.dllErrorChips = stats(tr.dllDiscr(idx));
    a.pllErrorDegrees = stats(360*tr.pllDiscr(idx));
    a.fllErrorHz = stats(tr.fllDiscrFiltHz(idx));
    a.fllAidingFraction = mean(tr.fllAided(idx));
    a.codeFreqOffsetHz = stats(tr.codeFreq(idx)-s.codeFreqBasis);
    a.carrierFreqHz = stats(tr.carrFreq(idx));
    a.onlineS4 = stats(tr.S4(cidx));
    a.onlineS4Raw = stats(tr.S4_ori(cidx));
    a.onlineS4NoiseTerm = stats(tr.S4_corr(cidx));
    a.onlineS4StartupMax = max(tr.S4_ori, [], 'omitnan');
    a.loggedPllThermalDeg = stats(tr.sigma_PLL(cidx));
    % Carrier loop uses pilot correlator: audit the consequence of using
    % summed data+pilot C/N0 in the existing thermal-jitter diagnostic.
    pilotCN0 = 10.^(tr.PilotCNo(cidx)/10);
    a.pilotBasedPllThermalDeg = stats(180/pi * sqrt(s.pllNoiseBandwidth_stab ./ ...
        pilotCN0 .* (1+1./(2*s.intTime*pilotCN0))));
    a.scintDefinitionAudit = struct();
    a.windows = struct([]);
    a.navFrameAudit = struct();
    if tr.PRN == 11
        a.scintDefinitionAudit = intensityAudit(tr, s);
        a.windows = windowAudit(tr, s);
        channelIndex=find([saved.results.channel.PRN]==tr.PRN,1);
        a.navFrameAudit=navFrameAudit(tr,n.towSeg{channelIndex});
        review.prn11 = a;
    end
    tracks{k} = a;
    fprintf('Reviewed PRN %02d: samples=%d REACQ=%d medianCNo=%.2f\n', ...
        tr.PRN, N, a.reacqMs, a.cnoTotalDbHz.median);
    clear loaded tr
end
review.tracks = [tracks{:}];
review.notes = [ ...
    "Steady statistics use t>=150 s; initial pull-in excluded.", ...
    "S4 is sparse (5-second updates); NaNs between updates are expected.", ...
    "No inter-case truth alignment or absolute positioning accuracy is inferred.", ...
    "Raw intensity CV includes 1-ms thermal noise and DME residuals."];
writeJson(fullfile(reviewDir, 'data_review.json'), review);
end

function a = momentAudit(I, Q, interval)
n = floor(numel(I)/interval)*interval;
power = reshape(I(1:n).^2+Q(1:n).^2, interval, []);
m = mean(power,1); v = var(power,0,1);
a = struct('windows',numel(m),'negativeRadicand',nnz(m.^2-v<0), ...
    'zeroPower',nnz(m==0),'nonfinitePower',nnz(~isfinite(m)));
end

function a=navFrameAudit(tr,segments)
% Audit scheduled frames against the same hard decisions/CRC as the receiver.
secondary=[1 1 1 -1 1];
preamble=[-1 -1 -1 1 1 1 -1 1 1 -1 1 1 -1 -1 1 -1 -1 -1 -1 1 -1 1 1 1];
pattern=kron(preamble,secondary);
crc=comm.CRCDetector([24 23 18 17 14 11 10 7 6 5 4 3 1 0]);
frames=0; preamblePass=0; crcPass=0; usable=0; towMismatch=0;
for si=1:numel(segments)
    sg=segments(si);
    for start=sg.subFrameStart:3000:(sg.indexEnd-2999)
        frames=frames+1; raw=tr.I_P(start:start+2999);
        if any(~isfinite(raw)), continue; end
        bits=2*(raw>0)-1;
        preOK=abs(sum(bits(1:120).*pattern))>115;
        preamblePass=preamblePass+preOK;
        symbols=sum(reshape(bits,5,[]).'.*secondary,2).';
        symbols=2*(symbols>0)-1;
        if ~isequal(symbols(1:24),preamble), symbols=-symbols; end
        payload=symbols(25:312)<0.5;
        [~,bad]=step(crc,payload.');
        if bad, continue; end
        crcPass=crcPass+1; usable=usable+preOK;
        eph=ephemeris(dec2bin(payload).',eph_structure_init());
        expected=mod(sg.TOW+(start-sg.subFrameStart)/1000,604800);
        towMismatch=towMismatch+(abs(eph.SOW-expected)>1e-6);
    end
end
a=struct('scheduledCompleteFrames',frames,'preamblePassingFrames',preamblePass, ...
    'crcPassingFrames',crcPass,'receiverUsableFrames',usable, ...
    'towMismatchesAmongCrcPass',towMismatch, ...
    'method','hard decisions + CRC-24Q; receiver currently does not implement LDPC decoding');
end

function a = cnoPatchAudit(tr,s)
N=floor(numel(tr.I_P)/s.CNoInterval)*s.CNoInterval;
rawData=reshape(tr.I_P(1:N).^2+tr.Q_P(1:N).^2,s.CNoInterval,[]);
rawPilot=reshape(tr.Pilot_I_P(1:N).^2+tr.Pilot_Q_P(1:N).^2,s.CNoInterval,[]);
md=mean(rawData); mp=mean(rawPilot); dd=md.^2-var(rawData); dp=mp.^2-var(rawPilot);
ad=sqrt(dd); ap=sqrt(dp);
old=10*log10((abs(ad./(md-ad))+abs(ap./(mp-ap)))/s.intTime);
ad=sqrt(max(0,dd)); ap=sqrt(max(0,dp));
fixed=10*log10((ad./max(md-ad,2*eps(md))+ap./max(mp-ap,2*eps(mp)))/s.intTime);
changed=find(abs(old-fixed)>1e-8 | xor(isfinite(old),isfinite(fixed)));
low=~isfinite(fixed) | fixed<s.TrkCN0Th;
edges=diff([false low false]); starts=find(edges==1); ends=find(edges==-1);
longest=0; if ~isempty(starts), longest=max(ends-starts); end
recover=s.TrkCN0Th+3; needed=3;
if isfield(s,'reacqCnoRecoverDbHz'), recover=s.reacqCnoRecoverDbHz; end
if isfield(s,'reacqCnoConsecutive'), needed=s.reacqCnoConsecutive; end
counter=0; triggers=[];
for k=1:numel(fixed)
    if ~isfinite(fixed(k)) || fixed(k)<s.TrkCN0Th
        counter=counter+1;
    elseif fixed(k)>=recover
        counter=0;
    end
    if counter>=needed, triggers(end+1)=k; counter=0; end %#ok<AGROW>
end
a=struct('changedWindows',numel(changed), ...
    'windowEndSec',changed*s.CNoInterval*s.intTime, ...
    'oldTotalCNo',old(changed),'fixedTotalCNo',fixed(changed), ...
    'minimumFixedTotalCNo',min(fixed),'belowThresholdWindows',nnz(low), ...
    'longestConsecutiveLowWindows',longest,'thresholdDbHz',s.TrkCN0Th, ...
    'potentialReacqWindowEndsSec',triggers*s.CNoInterval*s.intTime);
end

function a = windowAudit(tr, s)
ends = 60:60:floor(numel(tr.I_P)*s.intTime);
cells = cell(size(ends));
for j=1:numel(ends)
    ii=round((ends(j)-60)/s.intTime)+1:round(ends(j)/s.intTime);
    kk=ceil(ii(1)/s.CNoInterval):floor(ii(end)/s.CNoInterval);
    cells{j} = struct('startSec',ends(j)-60,'endSec',ends(j), ...
        'pllStdDegrees',std(360*tr.pllDiscr(ii),'omitnan'), ...
        'dllStdChips',std(tr.dllDiscr(ii),'omitnan'), ...
        'medianCNo',median(tr.B2a_CNo(kk),'omitnan'), ...
        'pilotCNo',median(tr.PilotCNo(kk),'omitnan'), ...
        'fllAidingFraction',mean(tr.fllAided(ii)), ...
        'pbDutyMean',mean(tr.eta(ii),'omitnan'), ...
        'nearCostasBoundaryFraction',mean(abs(tr.pllDiscr(ii))>.24));
end
a=[cells{:}];
end

function a = dopAudit(n, use)
indices=find(use); corrected=nan(5,numel(indices));
for j=1:numel(indices)
    k=indices(j); used=n.raim.usedPRN{k};
    prns=zeros(size(n.el,1),1); prns(1:size(n.PRN,1))=n.PRN(:,k);
    mask=ismember(prns,used) & isfinite(n.el(:,k)) & isfinite(n.az(:,k));
    el=deg2rad(n.el(mask,k)); az=deg2rad(n.az(mask,k));
    G=[-cos(el).*sin(az),-cos(el).*cos(az),-sin(el),ones(numel(el),1)];
    if size(G,1)<4 || rank(G)<4, continue; end
    Q=(G.'*G)\eye(4);
    corrected(:,j)=[sqrt(trace(Q));sqrt(trace(Q(1:3,1:3))); ...
        sqrt(Q(1,1)+Q(2,2));sqrt(Q(3,3));sqrt(Q(4,4))];
end
a=struct('order','GDOP PDOP HDOP VDOP TDOP', ...
    'loggedMedian',median(n.DOP(:,indices),2,'omitnan').', ...
    'enuCorrectedMedian',median(corrected,2,'omitnan').', ...
    'maxPdopDifference',max(abs(corrected(2,:)-n.DOP(2,indices)),[],'omitnan'));
end

function a = intensityAudit(tr, s)
% Same causal filter, two input definitions; no tuning or noise subtraction.
power = tr.Pilot_I_P.^2 + tr.Pilot_Q_P.^2;
amp = sqrt(power);
[z,p,g] = butter(6, s.scint_fCutoff/(0.5/s.intTime), 'low');
[sos, gain] = zp2sos(z,p,g);
ampTrend = amp*gain; powerTrend = power*gain;
for section=1:size(sos,1)
    ampTrend = filter(sos(section,1:3),sos(section,4:6),ampTrend);
    powerTrend = filter(sos(section,1:3),sos(section,4:6),powerTrend);
end
ampNorm = amp./max(abs(ampTrend),eps);
powerNorm = power./max(abs(powerTrend),eps);
window = round(60/s.intTime);
ends = round((180:60:floor(numel(power)*s.intTime))/s.intTime);
a = struct('windowEndSec', ends*s.intTime, 'amplitudeCV', nan(size(ends)), ...
    'intensityCV', nan(size(ends)), 'definition', ...
    'std normalized intensity / mean normalized intensity; population moments; no thermal correction');
for j=1:numel(ends)
    ii = ends(j)-window+1:ends(j);
    if any(tr.trk_state(ii)==9 | ~isfinite(power(ii))), continue; end
    a.amplitudeCV(j) = std(ampNorm(ii),1)/mean(ampNorm(ii));
    a.intensityCV(j) = std(powerNorm(ii),1)/mean(powerNorm(ii));
end
a.medianIntensityToAmplitudeRatio = median(a.intensityCV./a.amplitudeCV,'omitnan');
end

function a = stats(x)
x = double(x(isfinite(x))); x = x(:);
if isempty(x)
    q=nan(1,5); av=NaN; sd=NaN; rmsv=NaN;
else
    q=prctile(x,[0 5 50 95 100]); av=mean(x); sd=std(x); rmsv=sqrt(mean(x.^2));
end
a=struct('count',numel(x),'min',q(1),'p05',q(2),'median',q(3),'p95',q(4), ...
    'max',q(5),'mean',av,'std',sd,'rms',rmsv);
end

function writeJson(path,value)
fid=fopen(path,'w','n','UTF-8'); assert(fid>=0);
cleaner=onCleanup(@() fclose(fid));
fprintf(fid,'%s\n',jsonencode(value,'PrettyPrint',true));
end
