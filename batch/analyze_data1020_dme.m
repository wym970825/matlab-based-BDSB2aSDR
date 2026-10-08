function summary = analyze_data1020_dme(manifestPath, windowCount, windowSeconds)
%ANALYZE_DATA1020_DME Raw-IQ, full-band Welch spectra for six DATA1020 cases.
%   analyze_data1020_dme(manifestPath) uses 61 uniformly spaced 50-ms windows
%   per file. No PB or TF filtering is applied. IQ is little-endian int16 I+jQ.
%   All results are written to manifest.analysisDir. JSON records frequency/space
%   evidence separately: station identity cannot be established from FFT alone.
%   analyze_data1020_dme(manifestPath,0) only redraws saved spectral_data.mat,
%   without reading source IQ or receiver results or changing spectral evidence.
%
%   Band contrast = mean PSD over station +/-400 kHz divided by mean PSD of
%   flanks 0.8--1.4 MHz from station. Peak is located within +/-400 kHz using
%   51-bin smoothing of the time-averaged PSD, suppressing narrow FFT spikes.
%   This local-background metric is descriptive, not a calibrated DME detector.

if nargin < 2, windowCount = 61; end
if nargin < 3, windowSeconds = 0.05; end
manifest = jsondecode(fileread(manifestPath));
outRoot = manifest.analysisDir;
if ~isfolder(outRoot), mkdir(outRoot); end
entries = manifest.entries;
nfft = 8192;
overlap = 0.5;
win = 0.5-0.5*cos(2*pi*(0:nfft-1)'/nfft); % periodic Hann, no toolbox
oldVisible = get(groot, 'defaultFigureVisible');
visibilityCleanup = onCleanup(@()set(groot,'defaultFigureVisible',oldVisible)); %#ok<NASGU>
set(groot, 'defaultFigureVisible', 'off');
summary = struct('method', struct('input', 'raw unblanked little-endian int16 I+jQ', ...
    'windowCount',windowCount,'windowSeconds',windowSeconds,'nfft',nfft, ...
    'windowFunction','periodic Hann','overlapFraction',overlap, ...
    'psdUnits','ADC squared per Hz, complex two-sided spectrum', ...
    'stationBandHalfWidthHz',400e3,'backgroundInnerHz',800e3,'backgroundOuterHz',1.4e6, ...
    'highEnergySpectrum','Average periodogram of highest-energy 10 percent of overlapping FFT frames in each window', ...
    'classification','candidate frequency/position match; not unique transmitter identification'), 'entries', []);
if windowCount==0
    summary=jsondecode(fileread(fullfile(outRoot,'fft_station_analysis.json')));
end
for k = 1:numel(entries)
    c = entries(k);
    c.id = c.sourceId;
    c.firstUtc = c.utcStart;
    c.samplingFrequencyHz = c.samplingFreq;
    dest = fullfile(outRoot,sprintf('%02d_%s',c.experimentNumber,c.id));
    if ~isfolder(dest), mkdir(dest); end
    if windowCount==0
        cached=load(fullfile(dest,'spectral_data.mat'));
        localFigures(c,cached.fHz,cached.psd,mean(cached.psd,2),max(cached.psd,[],2), ...
            mean(cached.highEnergyPsd,2),cached.actualStarts,cached.result.stationCandidates,dest);
        fprintf('[DME FFT plots %d/%d] %s, saved spectra only\n',k,numel(entries),c.id);
        continue
    end
    fileInfo = dir(c.sourceFile);
    c.durationSeconds = fileInfo.bytes/(4*c.samplingFrequencyHz);
    c.stationCandidates = localStationDistances(c.pbDir,manifest.stations);
    fs = c.samplingFrequencyHz;
    nSamples = floor(windowSeconds*fs);
    starts = linspace(0,c.durationSeconds-nSamples/fs,windowCount);
    actualStarts = floor(starts*fs)/fs;
    fHz = c.centerFrequencyHz+(-nfft/2:nfft/2-1)'*fs/nfft;
    psd = zeros(nfft,windowCount);
    highEnergyPsd = zeros(nfft,windowCount);
    peakAdc = zeros(windowCount,1);
    clipFraction = zeros(windowCount,1);
    fid = fopen(c.sourceFile,'rb','ieee-le');
    assert(fid>=0,'Cannot open IQ: %s',c.sourceFile);
    closer = onCleanup(@()fclose(fid));
    fprintf('[DME FFT %d/%d] %s, Fc %.3f MHz\n',k,numel(entries),c.id,c.centerFrequencyHz/1e6);
    for j = 1:windowCount
        status = fseek(fid,4*floor(starts(j)*fs),'bof');
        assert(status==0,'IQ seek failed');
        iq = fread(fid,[2,nSamples],'int16=>double');
        assert(size(iq,2)==nSamples,'Short IQ read');
        x = complex(iq(1,:),iq(2,:)).';
        peakAdc(j) = max(abs(x));
        clipFraction(j) = mean(any(iq<=-32768 | iq>=32767,1));
        x = x-mean(x); % DC removal only; all RF bands otherwise preserved
        [psd(:,j),highEnergyPsd(:,j)] = localWelch(x,win,nfft,fs);
    end
    clear closer
    meanPsd = mean(psd,2);
    medPsd = median(psd,2);
    maxPsd = max(psd,[],2);
    meanHighEnergyPsd = mean(highEnergyPsd,2);
    [~,top] = max(meanPsd);
    candidates = c.stationCandidates;
    for s = 1:numel(candidates)
        delta = abs(fHz-candidates(s).frequencyHz);
        band = delta<=400e3;
        side = delta>=800e3 & delta<=1.4e6;
        bandPower = mean(psd(band,:),1);
        sidePower = mean(psd(side,:),1);
        contrast = 10*log10(bandPower./sidePower);
        smoothed = movmean(meanPsd,51);
        bandIndices = find(band);
        [peakPower,ii] = max(smoothed(band));
        candidates(s).peakFrequencyHz = fHz(bandIndices(ii));
        candidates(s).peakOffsetFromReferenceHz = candidates(s).peakFrequencyHz-candidates(s).frequencyHz;
        candidates(s).meanBandContrastDb = 10*log10(mean(bandPower)/mean(sidePower));
        candidates(s).highEnergyBandContrastDb = 10*log10(mean(meanHighEnergyPsd(band))/mean(meanHighEnergyPsd(side)));
        candidates(s).highEnergyGainDb = 10*log10(mean(meanHighEnergyPsd(band))/mean(meanPsd(band)));
        candidates(s).medianWindowContrastDb = median(contrast);
        candidates(s).minimumWindowContrastDb = min(contrast);
        candidates(s).maximumWindowContrastDb = max(contrast);
        candidates(s).fractionWindowsAbove3dB = mean(contrast>3);
        candidates(s).bandPowerAdcSquared = mean(bandPower)*(sum(band)*fs/nfft);
        candidates(s).smoothedPeakAboveFlanksDb = 10*log10(peakPower/mean(sidePower));
        candidates(s).frequencyEvidenceStrong = candidates(s).meanBandContrastDb >= 3;
        candidates(s).frequencyEvidencePresent = candidates(s).meanBandContrastDb >= 1.5;
        candidates(s).windowContrastDb = contrast;
    end
    % The ranking is spectral only. Distance is supplied alongside it, avoiding
    % circularly forcing the nearest reference site to be the received source.
    [~,best] = max([candidates.meanBandContrastDb]);
    selected = candidates(best);
    confidence = 'weak / spectrum inconclusive';
    if selected.frequencyEvidenceStrong, confidence = 'spectrally supported candidate';
    elseif selected.frequencyEvidencePresent, confidence = 'tentative frequency candidate'; end
    result = struct('experimentNumber',c.experimentNumber,'sourceId',c.id, ...
        'sourceFile',c.sourceFile,'firstUtc',c.firstUtc,'centerFrequencyHz',c.centerFrequencyHz, ...
        'samplingFrequencyHz',fs,'resolutionHz',fs/nfft,'analyzedSeconds',nSamples/fs*windowCount, ...
        'windowStartSeconds',actualStarts,'windowSeconds',nSamples/fs, ...
        'globalMeanSpectrumPeakHz',fHz(top),'maxObservedClipFraction',max(clipFraction), ...
        'stationCandidates',candidates,'matchedStation',selected, ...
        'suggestedStationId',selected.id, ...
        'matchConfidence',confidence,'identityCaveat', ...
        'Frequency and route proximity support a candidate; other cochannel emitters are not excluded.');
    localWriteJson(fullfile(dest,'spectral_station_evidence.json'),result);
    stationId=string({candidates.id}).'; stationName=string({candidates.name}).';
    writetable(table(stationId,stationName,[candidates.frequencyHz].',[candidates.peakFrequencyHz].', ...
        [candidates.meanBandContrastDb].',[candidates.highEnergyBandContrastDb].', ...
        [candidates.highEnergyGainDb].',[candidates.minimumDistanceKm].', ...
        [candidates.medianDistanceKm].',[candidates.maximumDistanceKm].', ...
        'VariableNames',{'stationId','stationName','referenceFrequencyHz','smoothedPeakFrequencyHz', ...
        'meanBandContrastDb','highEnergyBandContrastDb','highEnergyGainDb', ...
        'minimumDistanceKm','medianDistanceKm','maximumDistanceKm'}),fullfile(dest,'station_candidates.csv'));
    writetable(table(fHz,10*log10(max(meanPsd,realmin)),10*log10(max(medPsd,realmin)), ...
        10*log10(max(maxPsd,realmin)),10*log10(max(meanHighEnergyPsd,realmin)), 'VariableNames', ...
        {'frequencyHz','meanPsdDbAdcSquaredPerHz','medianPsdDbAdcSquaredPerHz','maxWindowPsdDbAdcSquaredPerHz','highEnergyPsdDbAdcSquaredPerHz'}), ...
        fullfile(dest,'welch_spectrum.csv'));
    wt = table(actualStarts(:),peakAdc,clipFraction,'VariableNames', ...
        {'windowStartSeconds','peakAmplitudeAdc','clipFraction'});
    for s=1:numel(candidates), wt.([candidates(s).id '_contrastDb'])=candidates(s).windowContrastDb(:); end
    writetable(wt,fullfile(dest,'window_diagnostics.csv'));
    save(fullfile(dest,'spectral_data.mat'),'fHz','psd','highEnergyPsd','actualStarts','result','-v7.3');
    localFigures(c,fHz,psd,meanPsd,maxPsd,meanHighEnergyPsd,actualStarts,candidates,dest);
    result = rmfield(result,'windowStartSeconds');
    for s=1:numel(result.stationCandidates), result.stationCandidates(s).windowContrastDb=[]; end
    result.matchedStation.windowContrastDb=[];
    if isempty(summary.entries), summary.entries=result; else, summary.entries(end+1)=result; end %#ok<AGROW>
    localWriteJson(fullfile(outRoot,'fft_station_analysis.json'),summary);
    fprintf('  Candidate %s %.0f MHz: contrast %.2f dB, closest distance %.3f km, %s\n', ...
        selected.id,selected.frequencyHz/1e6,selected.meanBandContrastDb,selected.minimumDistanceKm,confidence);
end
end

function [psd,highPsd] = localWelch(x,win,nfft,fs)
step = nfft/2;
starts = 1:step:(numel(x)-nfft+1);
accum = zeros(nfft,1);
keepCount = max(1,ceil(0.1*numel(starts)));
topSpectra = zeros(nfft,0);
topEnergy = zeros(1,0);
for first = 1:32:numel(starts)
    ss = starts(first:min(first+31,numel(starts)));
    block = x((0:nfft-1)'+ss).*win;
    z = fft(block,nfft,1);
    power = abs(z).^2;
    accum = accum+sum(power,2);
    pool = [topSpectra power]; %#ok<AGROW>
    [energy,order] = sort([topEnergy sum(power,1)],'descend');
    order=order(1:min(keepCount,numel(order)));
    topSpectra=pool(:,order);
    topEnergy=energy(1:numel(order));
end
psd = fftshift(accum/(numel(starts)*fs*sum(win.^2)));
highPsd = fftshift(mean(topSpectra,2)/(fs*sum(win.^2)));
end

function localFigures(c,fHz,psd,meanPsd,maxPsd,highPsd,starts,candidates,dest)
colors = lines(numel(candidates));
f = figure('Color','w','Position',[100 100 1600 1050]);
layout = tiledlayout(f,3,1,'Padding','compact','TileSpacing','compact');
ax = nexttile(layout);
plot(ax,fHz/1e6,10*log10(max(meanPsd,realmin)),'k','LineWidth',1.3); hold(ax,'on');
plot(ax,fHz/1e6,10*log10(max(maxPsd,realmin)),'Color',[0.7 0.7 0.7]);
plot(ax,fHz/1e6,10*log10(max(highPsd,realmin)),'Color',[0.85 0.35 0.05]);
grid(ax,'on'); ylabel(ax,'PSD (dB ADC^2/Hz)');
lg=legend(ax,{'Mean of windows','Maximum window','Highest-energy 10% frames'},'Location','eastoutside');
lg.AutoUpdate='off';
title(ax,sprintf('Experiment %02d | %s | %s | RAW IQ, no blanking',c.experimentNumber,c.id,c.firstUtc),'Interpreter','none');
for s=1:numel(candidates), xline(ax,candidates(s).frequencyHz/1e6,'--', ...
    sprintf('%s %.0f MHz',candidates(s).id,candidates(s).frequencyHz/1e6),'Color',colors(s,:),'LabelOrientation','horizontal'); end
xlim(ax,[min(fHz) max(fHz)]/1e6);
ax = nexttile(layout);
imagesc(ax,fHz/1e6,starts,10*log10(max(psd.',realmin))); axis(ax,'xy');
colormap(ax,turbo(256)); cb=colorbar(ax); cb.Label.String='PSD (dB ADC^2/Hz)';
ylabel(ax,'Offset in raw file (s)'); hold(ax,'on');
for s=1:numel(candidates), xline(ax,candidates(s).frequencyHz/1e6,'w--','LineWidth',1); end
ax = nexttile(layout); hold(ax,'on');
for s=1:numel(candidates), plot(ax,starts,candidates(s).windowContrastDb,'LineWidth',1.3,'Color',colors(s,:)); end
yline(ax,3,'k:','3 dB descriptive threshold'); grid(ax,'on'); ylabel(ax,'Band / local background (dB)');
xlabel(ax,'Offset in raw file (s)'); legend(ax,{candidates.id},'Location','eastoutside');
xlabel(layout,'RF frequency (MHz), top two panels');
exportgraphics(f,fullfile(dest,'raw_fft_fullband.png'),'Resolution',160); close(f);
f = figure('Color','w','Position',[100 100 1650 520]);
layout = tiledlayout(f,1,numel(candidates),'Padding','compact','TileSpacing','compact');
for s=1:numel(candidates)
    ax=nexttile(layout); pick=abs(fHz-candidates(s).frequencyHz)<=1.5e6;
    plot(ax,fHz(pick)/1e6,10*log10(max(meanPsd(pick),realmin)),'Color',colors(s,:),'LineWidth',1.5); hold(ax,'on');
    xline(ax,candidates(s).frequencyHz/1e6,'k--');
    xline(ax,(candidates(s).frequencyHz-400e3)/1e6,':'); xline(ax,(candidates(s).frequencyHz+400e3)/1e6,':');
    grid(ax,'on'); xlabel(ax,'RF frequency (MHz)'); ylabel(ax,'PSD (dB ADC^2/Hz)');
    title(ax,sprintf('%s: %.2f dB; route %.2f--%.2f km',candidates(s).id,candidates(s).meanBandContrastDb, ...
        candidates(s).minimumDistanceKm,candidates(s).maximumDistanceKm));
end
title(layout,sprintf('Experiment %02d | %s | reference-frequency evidence',c.experimentNumber,c.id),'Interpreter','none');
exportgraphics(f,fullfile(dest,'station_band_zoom.png'),'Resolution',160); close(f);
end

function candidates = localStationDistances(pbDir,stations)
lines = readlines(fullfile(pbDir,'pvt.nmea'));
lat = []; lon = []; height = [];
for i=1:numel(lines)
    if ~startsWith(lines(i),'$GBGGA,'), continue; end
    parts=split(lines(i),',');
    if numel(parts)<10 || parts(7)=="0" || strlength(parts(3))==0 || strlength(parts(5))==0, continue; end
    la=str2double(parts(3)); lo=str2double(parts(5));
    la=floor(la/100)+mod(la,100)/60; lo=floor(lo/100)+mod(lo,100)/60;
    if parts(4)=="S", la=-la; end
    if parts(6)=="W", lo=-lo; end
    lat(end+1,1)=la; lon(end+1,1)=lo; height(end+1,1)=str2double(parts(10)); %#ok<AGROW>
end
assert(~isempty(lat),'No NMEA position for station distances');
ok=isfinite(lat)&isfinite(lon)&isfinite(height)&abs(height)<=1000& ...
    localDistance(lat,lon,median(lat),median(lon))<=20;
assert(any(ok),'No plausible NMEA position for station distances');
candidates=stations;
for s=1:numel(stations)
    d=localDistance(lat(ok),lon(ok),stations(s).latitude,stations(s).longitude);
    candidates(s).minimumDistanceKm=min(d);
    candidates(s).medianDistanceKm=median(d);
    candidates(s).maximumDistanceKm=max(d);
    candidates(s).positionCount=sum(ok);
    candidates(s).rejectedPositionCount=sum(~ok);
    candidates(s).distanceMethod='Great-circle Earth radius 6371.0088km; abs(height)<=1000m and within 20km of coordinate median; diagnostic only';
end
end

function d=localDistance(lat,lon,stationLat,stationLon)
a=deg2rad(lat); b=deg2rad(stationLat);
h=sin((a-b)/2).^2+cos(a).*cos(b).*sin(deg2rad(lon-stationLon)/2).^2;
d=6371.0088*2*asin(sqrt(min(1,max(0,h))));
end

function localWriteJson(path,data)
fid=fopen(path,'w','n','UTF-8'); assert(fid>=0,'Cannot write JSON');
closer=onCleanup(@()fclose(fid)); %#ok<NASGU>
fprintf(fid,'%s',jsonencode(data,PrettyPrint=true));
end
