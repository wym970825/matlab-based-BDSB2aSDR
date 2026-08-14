function w = lsObservationWeights(elDeg, cnoDb, settings)
%LSOBSERVATIONWEIGHTS Optional elevation / C/N0 weights for WLS PVT.
%
%   w = lsObservationWeights(elDeg, cnoDb, settings)
%
%   elDeg  - 1xN elevation angles [deg] (NaN → elev weight 1 if enabled)
%   cnoDb  - 1xN C/N0 [dB-Hz]           (NaN → cno weight 1 if enabled)
%   settings.lsWeight fields (all optional; defaults = unweighted):
%     .enableElev  (false)  w_el = max(sin(el), sin(elFloorDeg))^elevExp
%     .enableCno   (false)  w_cno = 10.^((cno - cnoRefDb)/10)
%     .elevExp     (2)
%     .elFloorDeg  (5)      sin floor so low-elev SVs are not ~0 weight
%     .cnoRefDb    (40)     reference C/N0 for unit weight
%     .wMin        (0.05)   clamp floor (always applied when any weight on)
%     .wMax        (1.0)    clamp ceiling; then re-normalised so max(w)=1
%
% When both elev and C/N0 are off, returns ones(1,N).

    n = max(numel(elDeg), numel(cnoDb));
    if n < 1
        w = [];
        return;
    end
    elDeg = elDeg(:).';
    cnoDb = cnoDb(:).';
    if numel(elDeg) < n, elDeg(end+1:n) = NaN; end
    if numel(cnoDb) < n, cnoDb(end+1:n) = NaN; end

    cfg = localCfg(settings);
    if ~cfg.enableElev && ~cfg.enableCno
        w = ones(1, n);
        return;
    end

    wEl = ones(1, n);
    if cfg.enableElev
        el = elDeg;
        el(~isfinite(el)) = 90; % unknown → full elev weight until first fix
        el = max(min(el, 90), 0);
        s = sind(el);
        sFloor = sind(cfg.elFloorDeg);
        s = max(s, sFloor);
        wEl = s .^ cfg.elevExp;
    end

    wCn = ones(1, n);
    if cfg.enableCno
        cn = cnoDb;
        % Missing / invalid C/N0 → neutral (1), not zero
        bad = ~isfinite(cn) | cn <= 0;
        cn(bad) = cfg.cnoRefDb;
        wCn = 10 .^ ((cn - cfg.cnoRefDb) / 10);
    end

    w = wEl .* wCn;
    w = max(w, cfg.wMin);
    w = min(w, cfg.wMax);
    % Normalise so strongest SV has weight 1 (scale-invariant WLS)
    wMaxObs = max(w);
    if isfinite(wMaxObs) && wMaxObs > 0
        w = w / wMaxObs;
        w = max(w, cfg.wMin); % re-apply floor after scale
    else
        w = ones(1, n);
    end
end

function cfg = localCfg(settings)
    cfg = struct();
    cfg.enableElev = false;
    cfg.enableCno  = false;
    cfg.elevExp    = 2;
    cfg.elFloorDeg = 5;
    cfg.cnoRefDb   = 40;
    cfg.wMin       = 0.05;
    cfg.wMax       = 1.0;

    if ~isstruct(settings) || ~isfield(settings, 'lsWeight') ...
            || isempty(settings.lsWeight)
        return;
    end
    r = settings.lsWeight;
    if isfield(r, 'enableElev'), cfg.enableElev = logical(r.enableElev); end
    if isfield(r, 'enableCno'),  cfg.enableCno  = logical(r.enableCno);  end
    if isfield(r, 'elevExp') && isfinite(r.elevExp)
        cfg.elevExp = max(0, r.elevExp);
    end
    if isfield(r, 'elFloorDeg') && isfinite(r.elFloorDeg)
        cfg.elFloorDeg = max(0, min(90, r.elFloorDeg));
    end
    if isfield(r, 'cnoRefDb') && isfinite(r.cnoRefDb)
        cfg.cnoRefDb = r.cnoRefDb;
    end
    if isfield(r, 'wMin') && isfinite(r.wMin)
        cfg.wMin = max(1e-6, min(1, r.wMin));
    end
    if isfield(r, 'wMax') && isfinite(r.wMax)
        cfg.wMax = max(cfg.wMin, r.wMax);
    end
end
