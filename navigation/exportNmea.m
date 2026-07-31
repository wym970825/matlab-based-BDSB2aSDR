function outPath = exportNmea(navSolutions, settings, varargin)
%EXPORTNMEA Write NMEA 0183 log (GGA + GSV at least) from PVT results.
%
%   outPath = exportNmea(navSolutions, settings)
%   outPath = exportNmea(..., 'trackResults', tr, 'outDir', dir, 'fileName', 'pvt.nmea')
%
% Per valid fix epoch:
%   $GBGGA,...   position / quality / HDOP / altitude
%   $GBGSV,...   satellites in view (az/el + optional C/N0 from track)
%
% Talker default GB (BeiDou, NMEA 4.10). Configurable via settings.nmea.
%
% settings.nmea fields:
%   .enable       (true)  master switch
%   .talkerId     ('GB')
%   .bdtMinusUtc  (4)     BDT − UTC [s] for time field
%   .quality      (1)     GGA quality when fix valid (0 if invalid)
%   .geoidSepM    (0)     geoid separation field (ellipsoidal h as alt)
%   .fileName     ('pvt.nmea')

    p = inputParser;
    addParameter(p, 'trackResults', [], @(x) true);
    addParameter(p, 'outDir', '', @(x) ischar(x) || isstring(x));
    addParameter(p, 'fileName', '', @(x) ischar(x) || isstring(x));
    addParameter(p, 'force', false, @islogical);
    parse(p, varargin{:});
    opt = p.Results;

    outPath = '';
    cfg = localNmeaCfg(settings);
    if ~cfg.enable && ~opt.force
        return;
    end

    if isempty(navSolutions) || ~isfield(navSolutions, 'latitude')
        warning('exportNmea:NoNav', 'No navSolutions — skip NMEA export.');
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
    if ~exist(outDir, 'dir')
        mkdir(outDir);
    end

    fileName = char(opt.fileName);
    if isempty(fileName)
        fileName = cfg.fileName;
    end
    outPath = fullfile(outDir, fileName);

    trackResults = opt.trackResults;
    if ~isempty(trackResults) && ~isstruct(trackResults)
        if exist('trackResultsToStruct', 'file')
            trackResults = trackResultsToStruct(trackResults);
        end
    end

    lat = navSolutions.latitude(:);
    lon = navSolutions.longitude(:);
    nEp = numel(lat);
    h = nan(nEp, 1);
    if isfield(navSolutions, 'height')
        hh = navSolutions.height(:);
        h(1:min(nEp, numel(hh))) = hh(1:min(nEp, numel(hh)));
    end

    % Time: prefer localTime (receiver time, BDT-scale SOW)
    tSow = nan(nEp, 1);
    if isfield(navSolutions, 'localTime') && ~isempty(navSolutions.localTime)
        lt = navSolutions.localTime(:);
        tSow(1:min(nEp, numel(lt))) = lt(1:min(nEp, numel(lt)));
    end
    % Fallback: epoch index * navSolPeriod
    periodS = 0.5;
    if isfield(settings, 'navSolPeriod') && isfinite(settings.navSolPeriod)
        periodS = settings.navSolPeriod / 1000;
    end
    for i = 1:nEp
        if ~isfinite(tSow(i))
            tSow(i) = (i-1) * periodS;
        end
    end

    hdop = nan(nEp, 1);
    if isfield(navSolutions, 'DOP') && ~isempty(navSolutions.DOP) ...
            && size(navSolutions.DOP, 1) >= 3
        d = navSolutions.DOP(3, :);
        hdop(1:min(nEp, numel(d))) = d(1:min(nEp, numel(d)));
    end

    hasAzEl = isfield(navSolutions, 'az') && isfield(navSolutions, 'el') ...
        && isfield(navSolutions, 'PRN');
    hasPRN = isfield(navSolutions, 'PRN');

    lines = {};
    nGga = 0;
    nGsv = 0;

    for i = 1:nEp
        fixOk = isfinite(lat(i)) && isfinite(lon(i));
        utc = nmeaFormatUtc(tSow(i), cfg.bdtMinusUtc);

        % Count SVs in view this epoch
        prnList = [];
        elList = [];
        azList = [];
        snrList = [];
        if hasAzEl
            prnCol = navSolutions.PRN(:, min(i, size(navSolutions.PRN, 2)));
            elCol  = navSolutions.el(:, min(i, size(navSolutions.el, 2)));
            azCol  = navSolutions.az(:, min(i, size(navSolutions.az, 2)));
            for ch = 1:numel(prnCol)
                prn = prnCol(ch);
                elv = elCol(ch);
                if isfinite(prn) && prn > 0 && isfinite(elv) && elv >= 0
                    prnList(end+1) = prn; %#ok<AGROW>
                    elList(end+1)  = elv;
                    azv = azCol(ch);
                    if isfinite(azv), azList(end+1) = azv; else, azList(end+1) = NaN; end
                    snrList(end+1) = localSnr(trackResults, prn, i, settings, periodS);
                end
            end
        elseif hasPRN
            prnCol = navSolutions.PRN(:, min(i, size(navSolutions.PRN, 2)));
            for ch = 1:numel(prnCol)
                prn = prnCol(ch);
                if isfinite(prn) && prn > 0
                    prnList(end+1) = prn; %#ok<AGROW>
                    elList(end+1) = NaN;
                    azList(end+1) = NaN;
                    snrList(end+1) = localSnr(trackResults, prn, i, settings, periodS);
                end
            end
        end
        nSat = numel(prnList);

        q = 0;
        if fixOk
            q = cfg.quality;
        end
        if nSat < 1 && fixOk
            nSat = 4; % unknown count — do not leave 00 if we have a 3D fix
        end

        gga = nmeaBuildGGA(cfg.talkerId, utc, lat(i), lon(i), q, nSat, ...
            hdop(i), h(i), cfg.geoidSepM);
        lines{end+1} = gga; %#ok<AGROW>
        nGga = nGga + 1;

        if ~isempty(prnList) && any(isfinite(elList))
            gsv = nmeaBuildGSV(cfg.talkerId, prnList, elList, azList, snrList);
            for k = 1:numel(gsv)
                lines{end+1} = gsv{k}; %#ok<AGROW>
                nGsv = nGsv + 1;
            end
        elseif ~isempty(prnList)
            % elev unknown — still emit GSV with empty elev via 0? skip empty elev
            % emit with elev=0 only if we want presence; NMEA allows empty elev.
            % Use elev=0 placeholder for tracked PRNs without az/el this epoch
            el0 = zeros(size(prnList));
            gsv = nmeaBuildGSV(cfg.talkerId, prnList, el0, azList, snrList);
            for k = 1:numel(gsv)
                lines{end+1} = gsv{k}; %#ok<AGROW>
                nGsv = nGsv + 1;
            end
        end
    end

    if isempty(lines)
        warning('exportNmea:Empty', 'No NMEA sentences generated.');
        outPath = '';
        return;
    end

    fid = fopen(outPath, 'w', 'n', 'UTF-8');
    if fid < 0
        error('exportNmea:Write', 'Cannot open %s', outPath);
    end
    cleaner = onCleanup(@() fclose(fid));
    for i = 1:numel(lines)
        fwrite(fid, lines{i}, 'char');
    end

    fprintf('NMEA export: %s\n', outPath);
    fprintf('  sentences: GGA=%d  GSV=%d  talker=%s  epochs=%d\n', ...
        nGga, nGsv, cfg.talkerId, nEp);
end

function cfg = localNmeaCfg(settings)
    cfg = struct();
    cfg.enable = true;
    cfg.talkerId = 'GB';
    cfg.bdtMinusUtc = 4;
    cfg.quality = 1;
    cfg.geoidSepM = 0;
    cfg.fileName = 'pvt.nmea';
    if ~isstruct(settings) || ~isfield(settings, 'nmea') || isempty(settings.nmea)
        return;
    end
    r = settings.nmea;
    if isfield(r, 'enable'),      cfg.enable = logical(r.enable); end
    if isfield(r, 'talkerId') && ~isempty(r.talkerId)
        cfg.talkerId = upper(char(r.talkerId));
    end
    if isfield(r, 'bdtMinusUtc') && isfinite(r.bdtMinusUtc)
        cfg.bdtMinusUtc = r.bdtMinusUtc;
    end
    if isfield(r, 'quality') && isfinite(r.quality)
        cfg.quality = max(0, min(8, round(r.quality)));
    end
    if isfield(r, 'geoidSepM') && isfinite(r.geoidSepM)
        cfg.geoidSepM = r.geoidSepM;
    end
    if isfield(r, 'fileName') && ~isempty(r.fileName)
        cfg.fileName = char(r.fileName);
    end
end

function snr = localSnr(trackResults, prn, epIdx, settings, periodS)
    snr = NaN;
    if isempty(trackResults)
        return;
    end
    cnoInt = 200;
    if isfield(settings, 'CNoInterval') && ~isempty(settings.CNoInterval)
        cnoInt = settings.CNoInterval;
    end
    % Approximate ms index of this nav epoch
    msIdx = max(1, round((epIdx-1) * periodS * 1000) + 1);
    for ch = 1:numel(trackResults)
        if ~isfield(trackResults, 'PRN')
            continue;
        end
        if trackResults(ch).PRN ~= prn
            continue;
        end
        if ~isfield(trackResults, 'B2a_CNo') || isempty(trackResults(ch).B2a_CNo)
            return;
        end
        k = max(1, min(numel(trackResults(ch).B2a_CNo), ceil(msIdx / cnoInt)));
        v = trackResults(ch).B2a_CNo(k);
        if isfinite(v) && v > 0
            snr = v;
        end
        return;
    end
end
