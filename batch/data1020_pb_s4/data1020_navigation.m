function [links,nav] = data1020_navigation(c,t,d)
p=readtable(fullfile(c.cfg.resultDir,'figures','navResult','satellite_track_points.csv'));
[found,idx]=ismember(p.navigationEpochIndex,c.anchors.ggaOrdinal);
p=p(found,:);idx=idx(found);
nav=p;nav.utc=c.anchors.utc(idx);
lat=nav.latitudeDeg*pi/180;lon=nav.longitudeDeg*pi/180;
slat=c.entry.station.latitude*pi/180;slon=c.entry.station.longitude*pi/180;
h=sin((lat-slat)/2).^2+cos(lat).*cos(slat).*sin((lon-slon)/2).^2;
nav.dmeDistanceKm=6371.0088*2*atan2(sqrt(h),sqrt(1-h));
links=table();
intervals=readtable('F:/matlab-GNSSsdr/BDS/B2a/results/data1020/20261009_pb_tf_comparison/comparison/continuous_tracking_intervals.csv','TextType','string');
intervals=intervals(intervals.experimentNumber==c.entry.experimentNumber & intervals.mode=="PB" & ...
    intervals.PRN==t.PRN(1) & intervals.criterion=="no_reacq" & intervals.durationSeconds>=180,:);
for w=1:height(t)
    a=t.windowStartUtc(w);b=t.windowEndUtc(w);
    use=nav.utc>=a & nav.utc<b;
    firstSample=d.time.referenceSample+(seconds(a-d.time.referenceUtc)-d.time.offsetSec)*c.settings.samplingFreq;
    lastSample=d.time.referenceSample+(seconds(b-d.time.referenceUtc)-d.time.offsetSec)*c.settings.samplingFreq;
    qualifies=any(firstSample/c.settings.samplingFreq>=intervals.fileStartSeconds & ...
        lastSample/c.settings.samplingFreq<=intervals.fileEndSeconds);
    row=table(c.entry.experimentNumber,t.PRN(w),a,b,firstSample,lastSample,qualifies,nnz(use), ...
        mean(nav.latitudeDeg(use)),mean(nav.longitudeDeg(use)),mean(nav.dmeDistanceKm(use)), ...
        'VariableNames',{'Experiment','PRN','WindowStartUtc','WindowEndUtc','FirstSample','EndSampleExclusive', ...
        'Inside180SecondInterval','NavigationEpochs','MeanLatitude','MeanLongitude','MeanDmeDistanceKm'});
    links=[links;row]; %#ok<AGROW>
end
end
