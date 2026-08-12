function outPath = exportNmea(navSolutions, settings, varargin)
%EXPORTNMEA Write NMEA 0183 GGA/GSA/GSV/ZDA sentences from PVT results.
%
%   outPath = exportNmea(navSolutions, settings)
%   outPath = exportNmea(..., 'trackResults', tr, 'eph', eph, ...
%       'outDir', dir, 'fileName', 'pvt.nmea')
%
% Sentence builders and formatters are constellation-neutral. The caller
% selects the talker, system ID, receiver-to-UTC offset, and week epoch in
% settings.nmea. The legacy bdtMinusUtc field remains a compatibility alias
% for utcOffsetSeconds.

    p = inputParser;
    addParameter(p, 'trackResults', [], @(x) true);
    addParameter(p, 'eph', [], @(x) true);
    addParameter(p, 'outDir', '', @(x) ischar(x) || isstring(x));
    addParameter(p, 'fileName', '', @(x) ischar(x) || isstring(x));
    addParameter(p, 'force', false, @(x) islogical(x) && isscalar(x));
    parse(p, varargin{:});
    opt = p.Results;

    outPath = '';
    cfg = localNmeaCfg(settings);
    if ~cfg.enable && ~opt.force
        return;
    end
    if isempty(navSolutions) || ~isfield(navSolutions, 'latitude')
        warning('exportNmea:NoNav', 'No navigation solutions; NMEA export skipped.');
        return;
    end

    outDir = char(opt.outDir);
    if isempty(outDir)
        if isfield(settings, 'resultRoot') && ~isempty(settings.resultRoot)
            outDir = fullfile(settings.resultRoot, 'nmea');
        else
            outDir = fullfile(pwd, 'nmea');
        end
    end
    if ~exist(outDir, 'dir'), mkdir(outDir); end
    fileName = char(opt.fileName);
    if isempty(fileName), fileName = cfg.fileName; end
    outPath = fullfile(outDir, fileName);

    trackResults = opt.trackResults;
    if ~isempty(trackResults) && ~isstruct(trackResults) && ...
            exist('trackResultsToStruct', 'file')
        trackResults = trackResultsToStruct(trackResults);
    end

    lat = navSolutions.latitude(:);
    lon = navSolutions.longitude(:);
    nEp = numel(lat);
    height = localEpochVector(navSolutions, 'height', nEp);
    tSow = localEpochVector(navSolutions, 'localTime', nEp);
    hasReceiverTime = isfinite(tSow);
    periodS = localNavPeriod(settings);
    missingTime = ~isfinite(tSow);
    tSow(missingTime) = (find(missingTime) - 1) * periodS;

    pdop = localDop(navSolutions, 2, nEp);
    hdop = localDop(navSolutions, 3, nEp);
    vdop = localDop(navSolutions, 4, nEp);
    weekNumber = localWeekNumber(opt.eph, cfg.weekNumber);
    weekEpoch = localWeekEpoch(cfg.weekEpoch);
    canBuildDate = ~isempty(weekEpoch) && isfinite(weekNumber);
    if cfg.emitZDA && ~canBuildDate
        warning('exportNmea:NoAbsoluteDate', ...
            ['ZDA skipped: supply settings.nmea.weekEpoch and either ' ...
             'decoded eph.WN or settings.nmea.weekNumber.']);
    end

    lines = cell(0, 1);
    counts = struct('GGA', 0, 'GSA', 0, 'GSV', 0, 'ZDA', 0);
    hasAzEl = isfield(navSolutions, 'az') && isfield(navSolutions, 'el') ...
        && isfield(navSolutions, 'PRN');
    hasPRN = isfield(navSolutions, 'PRN');

    for epochIdx = 1:nEp
        fixOk = isfinite(lat(epochIdx)) && isfinite(lon(epochIdx));
        utc = nmeaFormatUtc(tSow(epochIdx), cfg.utcOffsetSeconds);
        [visiblePrn, elev, azim, snr] = localSatellitesInView( ...
            navSolutions, trackResults, epochIdx, settings, periodS, ...
            hasAzEl, hasPRN);
        [usedPrn, integrityOk] = localUsedSatellites( ...
            navSolutions, epochIdx, visiblePrn, fixOk);

        if cfg.emitGGA
            quality = 0;
            if fixOk && integrityOk, quality = cfg.quality; end
            gga = nmeaBuildGGA(cfg.talkerId, utc, lat(epochIdx), ...
                lon(epochIdx), quality, numel(usedPrn), hdop(epochIdx), ...
                height(epochIdx), cfg.geoidSepM);
            lines{end + 1, 1} = gga; %#ok<AGROW>
            counts.GGA = counts.GGA + 1;
        end

        if cfg.emitGSA
            fixType = localFixType(fixOk, integrityOk, numel(usedPrn));
            gsa = nmeaBuildGSA(cfg.talkerId, 'A', fixType, usedPrn, ...
                pdop(epochIdx), hdop(epochIdx), vdop(epochIdx), cfg.systemId);
            lines{end + 1, 1} = gsa; %#ok<AGROW>
            counts.GSA = counts.GSA + 1;
        end

        if cfg.emitGSV && ~isempty(visiblePrn)
            if ~any(isfinite(elev)), elev = zeros(size(visiblePrn)); end
            gsv = nmeaBuildGSV(cfg.talkerId, visiblePrn, elev, azim, snr);
            for messageIdx = 1:numel(gsv)
                lines{end + 1, 1} = gsv{messageIdx}; %#ok<AGROW>
                counts.GSV = counts.GSV + 1;
            end
        end

        if cfg.emitZDA && canBuildDate && fixOk && ...
                hasReceiverTime(epochIdx) && ~isempty(utc)
            utcDate = localUtcDate(weekEpoch, weekNumber, ...
                tSow(epochIdx), cfg.utcOffsetSeconds);
            zda = nmeaBuildZDA(cfg.talkerId, utc, day(utcDate), ...
                month(utcDate), year(utcDate), cfg.localZoneHours, ...
                cfg.localZoneMinutes);
            lines{end + 1, 1} = zda; %#ok<AGROW>
            counts.ZDA = counts.ZDA + 1;
        end
    end

    if isempty(lines)
        warning('exportNmea:Empty', 'No NMEA sentences generated.');
        outPath = '';
        return;
    end

    fid = fopen(outPath, 'w', 'n', 'UTF-8');
    if fid < 0, error('exportNmea:Write', 'Cannot open %s', outPath); end
    cleaner = onCleanup(@() fclose(fid));
    for lineIdx = 1:numel(lines)
        fwrite(fid, lines{lineIdx}, 'char');
    end

    fprintf('NMEA export: %s\n', outPath);
    fprintf(['  sentences: GGA=%d GSA=%d GSV=%d ZDA=%d ' ...
        'talker=%s epochs=%d\n'], counts.GGA, counts.GSA, counts.GSV, ...
        counts.ZDA, cfg.talkerId, nEp);
end

function cfg = localNmeaCfg(settings)
    cfg = struct('enable', true, 'talkerId', 'GN', ...
        'utcOffsetSeconds', 0, 'quality', 1, 'geoidSepM', 0, ...
        'fileName', 'pvt.nmea', 'systemId', [], 'weekNumber', nan, ...
        'weekEpoch', '', 'localZoneHours', 0, 'localZoneMinutes', 0, ...
        'emitGGA', true, 'emitGSA', true, 'emitGSV', true, 'emitZDA', true);
    if ~isstruct(settings) || ~isfield(settings, 'nmea') || ...
            ~isstruct(settings.nmea)
        return;
    end
    raw = settings.nmea;
    cfg = localCopyLogical(raw, cfg, {'enable','emitGGA','emitGSA','emitGSV','emitZDA'});
    cfg = localCopyFinite(raw, cfg, {'quality','geoidSepM','systemId', ...
        'weekNumber','localZoneHours','localZoneMinutes'});
    if isfield(raw, 'talkerId') && ~isempty(raw.talkerId)
        talker = upper(char(raw.talkerId));
        if numel(talker) == 2, cfg.talkerId = talker; end
    end
    if isfield(raw, 'utcOffsetSeconds') && isfinite(raw.utcOffsetSeconds)
        cfg.utcOffsetSeconds = raw.utcOffsetSeconds;
    elseif isfield(raw, 'bdtMinusUtc') && isfinite(raw.bdtMinusUtc)
        cfg.utcOffsetSeconds = raw.bdtMinusUtc;
    end
    if isfield(raw, 'fileName') && ~isempty(raw.fileName)
        cfg.fileName = char(raw.fileName);
    end
    if isfield(raw, 'weekEpoch') && ~isempty(raw.weekEpoch)
        cfg.weekEpoch = char(raw.weekEpoch);
    end
    cfg.quality = max(0, min(8, round(cfg.quality)));
end

function cfg = localCopyLogical(raw, cfg, names)
    for idx = 1:numel(names)
        name = names{idx};
        if isfield(raw, name) && isscalar(raw.(name))
            cfg.(name) = logical(raw.(name));
        end
    end
end

function cfg = localCopyFinite(raw, cfg, names)
    for idx = 1:numel(names)
        name = names{idx};
        if isfield(raw, name) && isnumeric(raw.(name)) && ...
                isscalar(raw.(name)) && isfinite(raw.(name))
            cfg.(name) = double(raw.(name));
        end
    end
end

function values = localEpochVector(source, fieldName, nEpochs)
    values = nan(nEpochs, 1);
    if isfield(source, fieldName) && ~isempty(source.(fieldName))
        raw = source.(fieldName)(:);
        nCopy = min(nEpochs, numel(raw));
        values(1:nCopy) = raw(1:nCopy);
    end
end

function values = localDop(navSolutions, row, nEpochs)
    values = nan(nEpochs, 1);
    if isfield(navSolutions, 'DOP') && size(navSolutions.DOP, 1) >= row
        raw = navSolutions.DOP(row, :);
        nCopy = min(nEpochs, numel(raw));
        values(1:nCopy) = raw(1:nCopy);
    end
end

function periodS = localNavPeriod(settings)
    periodS = 0.5;
    if isstruct(settings) && isfield(settings, 'navSolPeriod') && ...
            isnumeric(settings.navSolPeriod) && isscalar(settings.navSolPeriod) ...
            && isfinite(settings.navSolPeriod)
        periodS = settings.navSolPeriod / 1000;
    end
end

function weekNumber = localWeekNumber(eph, override)
    weekNumber = override;
    if isfinite(weekNumber), return; end
    values = [];
    if isstruct(eph)
        for idx = 1:numel(eph)
            if isfield(eph(idx), 'WN') && isnumeric(eph(idx).WN) && ...
                    isscalar(eph(idx).WN) && isfinite(eph(idx).WN)
                values(end + 1) = double(eph(idx).WN); %#ok<AGROW>
            end
        end
    end
    if ~isempty(values), weekNumber = mode(values); end
end

function epoch = localWeekEpoch(value)
    epoch = [];
    if isempty(value), return; end
    try
        epoch = datetime(value, 'InputFormat', 'yyyy-MM-dd', 'TimeZone', 'UTC');
        if ~isscalar(epoch) || isnat(epoch), epoch = []; end
    catch
        epoch = [];
    end
end

function utcDate = localUtcDate(epoch, weekNumber, sow, offset)
    utcDate = epoch + seconds(weekNumber * 604800 + sow - offset);
end

function [prn, elev, azim, snr] = localSatellitesInView(navSolutions, ...
        trackResults, epochIdx, settings, periodS, hasAzEl, hasPRN)
    prn = [];
    elev = [];
    azim = [];
    snr = [];
    if ~hasPRN, return; end

    prnCol = navSolutions.PRN(:, min(epochIdx, size(navSolutions.PRN, 2)));
    if hasAzEl
        elevCol = navSolutions.el(:, min(epochIdx, size(navSolutions.el, 2)));
        azimCol = navSolutions.az(:, min(epochIdx, size(navSolutions.az, 2)));
    else
        elevCol = nan(size(prnCol));
        azimCol = nan(size(prnCol));
    end
    for channelIdx = 1:numel(prnCol)
        satelliteId = prnCol(channelIdx);
        if ~isfinite(satelliteId) || satelliteId <= 0, continue; end
        elevation = elevCol(channelIdx);
        if hasAzEl && (~isfinite(elevation) || elevation < 0), continue; end
        prn(end + 1) = satelliteId; %#ok<AGROW>
        elev(end + 1) = elevation; %#ok<AGROW>
        azim(end + 1) = azimCol(channelIdx); %#ok<AGROW>
        snr(end + 1) = localSnr(trackResults, satelliteId, epochIdx, ...
            settings, periodS); %#ok<AGROW>
    end
end

function [usedPrn, integrityOk] = localUsedSatellites(navSolutions, ...
        epochIdx, visiblePrn, fixOk)
    usedPrn = visiblePrn;
    integrityOk = fixOk;
    if ~isfield(navSolutions, 'raim') || ~isstruct(navSolutions.raim)
        return;
    end
    raim = navSolutions.raim;
    if isfield(raim, 'usedPRN') && epochIdx <= numel(raim.usedPRN) && ...
            ~isempty(raim.usedPRN{epochIdx})
        usedPrn = double(raim.usedPRN{epochIdx}(:).');
    elseif isfield(raim, 'excludedPRN') && ...
            epochIdx <= numel(raim.excludedPRN) && ...
            ~isempty(raim.excludedPRN{epochIdx})
        usedPrn = setdiff(visiblePrn, raim.excludedPRN{epochIdx}, 'stable');
    end
    if isfield(raim, 'passed') && epochIdx <= numel(raim.passed)
        integrityOk = fixOk && logical(raim.passed(epochIdx));
    end
    if ~integrityOk
        usedPrn = [];
    end
end

function fixType = localFixType(fixOk, integrityOk, nUsed)
    if ~fixOk || ~integrityOk
        fixType = 1;
    elseif nUsed >= 4
        fixType = 3;
    elseif nUsed >= 3
        fixType = 2;
    else
        fixType = 1;
    end
end

function snr = localSnr(trackResults, prn, epochIdx, settings, periodS)
    snr = nan;
    if isempty(trackResults), return; end
    cnoInterval = 200;
    if isfield(settings, 'CNoInterval') && ~isempty(settings.CNoInterval)
        cnoInterval = settings.CNoInterval;
    end
    msIdx = max(1, round((epochIdx - 1) * periodS * 1000) + 1);
    for channelIdx = 1:numel(trackResults)
        if ~isfield(trackResults, 'PRN') || trackResults(channelIdx).PRN ~= prn
            continue;
        end
        if ~isfield(trackResults, 'B2a_CNo') || ...
                isempty(trackResults(channelIdx).B2a_CNo)
            return;
        end
        cno = trackResults(channelIdx).B2a_CNo;
        sampleIdx = max(1, min(numel(cno), ceil(msIdx / cnoInterval)));
        value = cno(sampleIdx);
        if isfinite(value) && value > 0, snr = value; end
        return;
    end
end
