function settings = initSettings(varargin)
%INITSETTINGS Build and normalize BDS-3 B2a receiver settings.
%
%   settings = initSettings()
%   settings = initSettings('Name', Value, ...)
%   settings = initSettings(overridesStruct)
%
% This is the shared constructor for JSON and MATLAB settings entry points.
% Every default field below accepts an override; nested scalar structures
% merge recursively (for example, struct('FLL',struct('enable',false))).
% Additional extension/pipeline fields are preserved instead of discarded.
% Use exact JSON field names; known name/value names are case-insensitive.
%
% Important input units and precedence:
%   msToProcess        : requested milliseconds, floored and capped to the
%                        available IF duration minus a one-second reserve.
%   samplingFreq / IF  : sample rate / digital IF in Hz; for IQ, one sample
%                        is one complex pair, not one stored scalar.
%   dataType/fileType  : fread precision; 1=real, 2=interleaved I,Q values.
%                        TF v1 specifically supports signed int8/int16 IQ.
%   skipNumberOfBytes  : absolute byte offset, not complex-sample count.
%                        If omitted, the legacy 3005 s skip is converted
%                        using FINAL rate/format; pass 0 to start at BOF.
%   acqSatelliteList   : numeric PRNs or text such as '11,19' / '1:2:63'.
%   PB_settings        : explicit ADC-amplitude thresholds override dBm
%                        conversion using FINAL usrp calibration and rate.
%   Frontend.mode      : off/pb/tf_v1; overrides legacy EnablePB when resolved.
%                        No Frontend field means retain EnablePB semantics.
% Canonical *_pull/*_stab bandwidths win over legacy aliases. Explicit fine
% code-search windows are preserved; omitted windows follow the final rate.
% Complete structs treat supplied derived values as explicit, including ADC
% thresholds: omit such fields to request recomputation after changing rate.
%
% Side effects: create result/temp directories; inspect IF metadata and warn
% if missing. Existing files with no usable interval throw. This function
% does not acquire/track, open a browser, or choose a new frontend default.
% Runners resolve Frontend and replace result paths with their outDir layout.
% Example: s=initSettings('samplingFreq',25e6,'skipNumberOfBytes',0,
%              'Frontend',struct('mode','tf_v1','TF', ...
%                  struct('stopbandWidthHz',800e3,'triangleSpanUs',3)));
%          report=runFromSettings(s,'doPlot',false);
%
% Relative documentation: ../docs/config_entrypoints/README.md
% TF parameters/units:    ../docs/upgrade_v020/USAGE.md
% See also runFromJsonConfig, runFromSettings, resolveFrontendSettings.
%
% Based on CU Multi-GNSS SDR B2a framework (Li / Shivaramaiah / Akos)
% and local FLL-aided / NH-state-machine extensions.

%% Defaults matching legacy init_B2a / initSettings smoke configuration
settings = struct();

%% Processing ==============================================================
settings.msToProcess      = 1452e3;  % [ms] acquisition/tracking tuning run
settings.numberOfChannels = 10;

%% IF file =================================================================
settings.filePath = 'D:\KLHP\IFData';
settings.fileName = '230919110036.B.gns';
settings.dataType = 'int8';
settings.fileType = 2;              % 1=real, 2=IQ interleaved
settings.IF       = 0e3;            % [Hz]
settings.samplingFreq = 30690000;       % [Hz]
settings.usrp.scaleK  = -94.72;
settings.usrp.gain    = 30;

%% B2a code / carrier ======================================================
settings.codeLength    = 10230;     % [chip]
settings.codeFreqBasis = 10.23e6;   % [Hz]
settings.carrFreqBasis = 1176.45e6; % [Hz]
settings.c             = 299792458;
settings.startOffset   = 68.802;    % [ms] initial receiver-time offset for pseudoranges
settings.IFBandwidth   = 30e6;    % [Hz] effective frontend bandwidth for monitoring

%% Pulse blanker ===========================================================
settings.EnablePB = true;
settings.PB_settings.UseStatic   = true; % false selects legacy adaptive PB threshold
settings.Th_static_dBm           = -110;
threshold_digdB = settings.Th_static_dBm - settings.usrp.scaleK - ...
    settings.usrp.gain + 10*log10(settings.samplingFreq);
settings.PB_settings.Th_static   = 10.^(threshold_digdB/20);
settings.Th_static_tracking_dBm  = -105;
trackingThreshold_digdB = settings.Th_static_tracking_dBm - ...
    settings.usrp.scaleK - settings.usrp.gain + ...
    10*log10(settings.samplingFreq);
settings.PB_settings.Th_static_tracking = ...
    10.^(trackingThreshold_digdB/20);
settings.PB_settings.falseAlert  = 5e-3; % target false alarm probability for adaptive PB
settings.PB_settings.Th_TTL      = 5;    % mitigate() calls per threshold refresh (1 call/ms in tracking)
settings.PB_settings.debugplot   = true; % legacy PB diagnostics; normally disable in batch
% Frontend is deliberately not defaulted to a resolved 'pb' structure here:
% callers may still edit EnablePB before running. Explicit Frontend.mode is
% authoritative; TF defaults (center, FIR, threshold, soft edge) are defined
% once in ../frontend/resolveFrontendSettings.m, not duplicated here.

%% Acquisition =============================================================
settings.skipAcquisition  = 0;     % current public runners require acquisition
% Smoke baseline from legacy initSettings (good satellites for this dataset)
settings.acqSatelliteList = [16,19,20,21,22,29,30,36,38,39,40,45,46];
% % settings.acqSatelliteList = [36];
settings.acqSearchBand    = 6000;   % [Hz] single-side; UAV Doppler + margin
settings.acqThreshold     = 1.4;
settings.acqStep          = 100;    % [Hz]
settings.coarseNoncohMs   = 5;      % independent 1-ms coarse power sums
settings.acqFlipSegments  = 8;      % single-boundary resolution per 1 ms
settings.fineNoncoh       = 5;      % [ms]
settings.fineStepHz       = 2;
settings.fineSearchInitialHalfSpanHz = 100;
settings.fineSearchMaxHalfSpanHz = 1000;
settings.fineCodeSearchHalfWinSamples = ceil(2*(settings.samplingFreq / ...
    settings.codeFreqBasis));
settings.resamplingThreshold = 50e6;
settings.resamplingflag      = 0;

%% Skip / duration vs file size ============================================
skipNumberOfSeconds = 3005;
if strcmpi(settings.dataType, 'int16')
    settings.size_per_sample = settings.fileType * 2;
elseif strcmpi(settings.dataType, 'int8')
    settings.size_per_sample = settings.fileType * 1;
else
    settings.size_per_sample = settings.fileType * 2;
end
settings.skipNumberOfBytes = skipNumberOfSeconds * settings.samplingFreq * ...
    settings.size_per_sample;

%% Tracking loops ==========================================================
% DLL: SoftGNSS 2nd-order. Pull-in is looser; switches with PLL at filter_pullinMS.
settings.dllDampingRatio         = 0.707;
settings.dllCorrelatorSpacing    = 0.5;
settings.dllNoiseBandwidth_pull  = 10;   % [Hz] INIT pull-in; 20 Hz diverged on UAV fade
settings.dllNoiseBandwidth_stab  = 2;    % [Hz] after pull-in / LONG
settings.dllNoiseBandwidth       = settings.dllNoiseBandwidth_stab; % legacy alias

settings.trackInit_MS    = 3000;   % INIT duration before ESTI/Weil
settings.filter_pullinMS = 2000;   % pull-in window: PLL+DLL use *_pull BW
settings.reEstimateMS    = 10e3;
settings.pllOrder        = 3;
settings.pllDampingRatio = 0.707;
settings.phaseDisType    = 2;
settings.longCoh_ms      = 5;      % [ms] coherent integration in LONG state
settings.weilEstBuffLen  = 100;    % native 1-ms pilot epochs used for NH estimation
settings.weilConfTh      = 1.5;    % best/second-best correlation-peak ratio (not probability)
settings.TrkCN0Th        = 29;     % [dB-Hz] low-C/N0 re-acquisition gate

% PLL noise bandwidths [Hz] — read by NH_stateMachine (not hard-coded there)
% pull: first filter_pullinMS of INIT; stab: rest of INIT + LONG
settings.pllNoiseBandwidth_pull = 50;
settings.pllNoiseBandwidth_stab = 30;
settings.pllNoiseBandwidth      = settings.pllNoiseBandwidth_stab; % legacy alias
settings.pllDampingRatio_init   = 0.707;
settings.pllNoiseBandwidth_init = settings.pllNoiseBandwidth_pull; % alias → pull
settings.pllDampingRatio_pull   = 0.707;
settings.pllDampingRatio_stab   = 0.707;
settings.phaseDisType_init      = 2;
settings.pllMaxNcoHz            = 1000; % residual about acquisition/FLL basis
settings.pllSaturationHoldMs    = 200;  % saturation occupancy window
settings.pllSaturationNcoRatio  = 0.95; % near-limit definition
settings.pllSaturationRatio     = 0.70; % near-limit occupancy for re-acquisition

settings.intTime      = 0.001;     % [s] native one-code-period integration
settings.pilotTRKflag = 1;         % use pilot branch for carrier tracking
settings.CNoInterval  = 200;       % native 1-ms epochs between C/N0 updates
settings.CNo_Th       = 30;        % [dB-Hz] legacy C/N0 quality threshold

% Carrier-aided code NCO (default ON): f_code = f0 - carrFreq*(f0/fL) - codeNco
% Instantaneous carrFreq; aid limited in *code-domain* Hz (50 ≈ 5.75 kHz carrier Doppler).
settings.carrierAidCode       = true;
settings.carrierAidCodeMaxHz  = 50;

%% FLL-aided PLL ===========================================================
% Frequency thresholds/limits and noise bandwidths are in Hz. N_on/N_off
% count consecutive state-machine decisions, not seconds. Separate INIT and
% LONG gains/bandwidths allow stronger pull-in without changing steady loops.
settings.FLL = struct();
settings.FLL.enable          = true;
settings.FLL.aidingEnable    = true;
settings.FLL.useBpskFold     = true;
settings.FLL.smoothAlpha     = 0.5; % legacy smoothing setting; unused by current tracker
settings.FLL.maxCorrHz       = 100; % per-update FLL correction bound [Hz]
settings.FLL.maxAccumHz      = 1000; % FLL-only offset around latest acquisition
settings.FLL.minCNoForAidDbHz = 29;  % stop integrating noise after C/N0 is known
settings.FLL.errThInitOn_Hz  = 15;
settings.FLL.errThInitOff_Hz = 10;
settings.FLL.errThLongOn_Hz  = 15;
settings.FLL.errThLongOff_Hz = 10;
settings.FLL.N_on            = 3;
settings.FLL.N_off           = 10;
settings.FLL.gainInit        = 0.003;
settings.FLL.gainLong        = 0.005;
settings.FLL.filtZeta        = 0.707;
settings.FLL.BW_Init_Hz      = 50;
settings.FLL.BW_Long_Hz      = 100;
settings.FLLinitT            = 150; % [ms] FLL-assisted initialization interval

%% Carrier KF (default OFF) ================================================
settings.KF = struct();
settings.KF.enable              = false;
settings.KF.enableFeedback      = false;
settings.KF.feedbackGain        = 1;
settings.KF.qJerk               = (0.3*pi*2)^2; % phase-jerk PSD [rad^2/s^5]
settings.KF.RphiFloor_deg       = 3;  % phase standard-deviation floor before squaring
settings.KF.RphiCeil            = 45; % legacy spelling; interpreted in degrees
settings.KF.RomegaFloor_Hz      = 1;  % frequency standard-deviation floor
settings.KF.maxCorrHz           = 100;
settings.KF.scintAdaptiveEnable = true;
settings.KF.scintWarmup_ms      = 150e3;
settings.KF.rmsBeta             = 0.98;

%% Scintillation calculator =================================================
% Scintillation index batch interval (ms). push() still 1 ms; heavy
% filter/stats run only every scint_updateMs. 5000 = 5 s (mexBaseFast).
settings.scint_updateMs = 5000;
settings.scint_bufLen   = 60000;    % native 1-ms samples: 60 s statistics window
settings.scint_fCutoff  = 0.1;      % [Hz] intensity/phase detrending cutoff

%% Re-acquisition ==========================================================
settings.REACQ_max          = 5;
settings.REACQ_eachTimeWaitMs = 100*(0:settings.REACQ_max-1); % legacy retry offsets [ms]; unused by current tracker
settings.max_reacqT         = 10;  % retained legacy limit; current tracker uses REACQ_max
settings.reacqCnoConsecutive = 3;   % independent C/N0 updates below threshold
settings.reacqCnoRecoverDbHz = 32;  % hysteresis reset threshold

%% Navigation ==============================================================
settings.navSolPeriod   = 500;  % [ms]
settings.elevationMask  = 5;    % [deg] navigation satellite-elevation mask
settings.useTropCorr    = 1;
settings.truePosition.E = nan;  % optional reference coordinates [m]; NaN=unknown
settings.truePosition.N = nan;
settings.truePosition.U = nan;

% Optional WLS observation weights (LS when nSat>=4; both off = equal weight)
% w = w_el * w_cno, clamped to [wMin, wMax], then scaled so max(w)=1
settings.lsWeight = struct();
settings.lsWeight.enableElev = false;  % sin(el)^elevExp (el floor applied)
settings.lsWeight.enableCno  = false;  % 10^((C/N0 - cnoRefDb)/10)
settings.lsWeight.elevExp    = 2;
settings.lsWeight.elFloorDeg = 5;      % min elev for sin() so weight not ~0
settings.lsWeight.cnoRefDb   = 40;     % unit C/N0 weight reference [dB-Hz]
settings.lsWeight.wMin       = 0.05;   % weight floor (limit weak SV influence)
settings.lsWeight.wMax       = 1.0;    % weight ceiling before re-normalise

% RAIM: solution-separation FDE (single- and dual-SV exclusion)
settings.raim = struct();
settings.raim.enable       = true;   % default ON
settings.raim.enableFde1   = true;   % single-SV fault
settings.raim.enableFde2   = true;   % dual-SV fault
settings.raim.alwaysSearch = false;  % FDE only if all-in-view fails gates
settings.raim.maxRmsM      = 80;     % residual RMS gate [m]
settings.raim.maxResM      = 200;    % max |residual| gate [m]

%% Plot / I/O ==============================================================
settings.plotTracking = true;
% Post-PVT display (default ON; set plotNavPost=false for silent / batch)
%   ENU displacement + velocity, GDOP/HDOP/VDOP, sky, geobasemap streets-light
settings.plotNavPost   = true;   % master switch for plotNavPost figures
settings.plotNavLegacy = false;  % SoftGNSS combined plotNavigation
% After time-order aggregate: drop points with |vE| or |vN| or |vU| > this (m/s)
settings.navTrackMaxSpeedMps = 500;  % position-jump filter for display track
% Baidu Map JSAPI 4.0 web UI (start/end + time-heat track; CustomOverlay labels)
settings.plotBaiduMap  = true;

% NMEA 0183 export. Constellation/time-system choices live in settings;
% navigation/nmeaBuild*.m remain constellation-neutral.
settings.nmea = struct();
settings.nmea.enable      = true;   % write pvt.nmea after navigation
settings.nmea.talkerId    = 'GB';   % GB (BDS); alternatives: BD, GN
settings.nmea.utcOffsetSeconds = 4; % receiver time = UTC + offset
settings.nmea.weekEpoch   = '2006-01-01'; % week-number epoch for ZDA date
settings.nmea.weekNumber  = [];     % optional override; eph.WN preferred
settings.nmea.systemId    = 4;      % optional NMEA 4.x GNSS system ID
settings.nmea.quality     = 1;      % GGA quality for valid fix (autonomous)
settings.nmea.geoidSepM   = 0;      % geoid separation (alt = ellipsoidal h)
settings.nmea.fileName    = 'pvt.nmea';
settings.nmea.emitGGA     = true;
settings.nmea.emitGSA     = true;
settings.nmea.emitGSV     = true;
settings.nmea.emitZDA     = true;
settings.nmea.localZoneHours = 0;
settings.nmea.localZoneMinutes = 0;

%% Multi-SV parallel tracking (par-fast-matlab) ============================
% Option A: each worker fopen()s the IF file privately. Hard cap 6 cores.
settings.useParfor     = true;   % parfor when >=2 active SVs
settings.parMaxWorkers = 8;      % max local workers (also hard-capped in code)

% Project-local result roots (override legacy absolute thesis paths)
projectRoot = fileparts(fileparts(mfilename('fullpath')));
settings.resultRoot     = fullfile(projectRoot, 'results');
settings.tempdataSvPth  = fullfile(settings.resultRoot, 'temp', ...
    string(datetime('now'), 'yyMMdd_HHmmss'));
settings.baiduMapKeyFile = fullfile(projectRoot, 'config', 'BaidumapKey.txt');

%% Apply all overrides before computing dependent settings =================
% raw records only caller-supplied values. This distinction is necessary:
% an explicit ADC threshold/window wins, whereas an omitted one is derived
% using the FINAL sample rate and calibration, not the legacy defaults above.
raw = localOverrides(settings, varargin{:});
settings = localMerge(settings, raw);

% Validate file geometry before multiplying offsets or dividing durations.
validateattributes(settings.samplingFreq, {'numeric'}, ...
    {'real','scalar','finite','positive'}, mfilename, 'samplingFreq');
validateattributes(settings.fileType, {'numeric'}, ...
    {'real','scalar','finite','integer'}, mfilename, 'fileType');
settings.fileType = double(settings.fileType);
settings.dataType = char(settings.dataType);
settings.size_per_sample = frontendSampleBytes(settings.dataType, settings.fileType);
if ~isfield(raw, 'skipNumberOfBytes')
    settings.skipNumberOfBytes = skipNumberOfSeconds * settings.samplingFreq * settings.size_per_sample;
end
validateattributes(settings.skipNumberOfBytes, {'numeric'}, ...
    {'real','scalar','finite','integer','nonnegative'}, mfilename, 'skipNumberOfBytes');
settings.skipNumberOfBytes = double(settings.skipNumberOfBytes);
settings.filePath = char(settings.filePath); settings.fileName = char(settings.fileName);
settings.acqSatelliteList = localParsePrnList(settings.acqSatelliteList);

% Canonical pull/stable bandwidths take precedence over legacy aliases.
% A caller supplying ONLY an alias still gets the intended loop bandwidth.
settings = localAlias(settings, raw, 'dllNoiseBandwidth_stab', 'dllNoiseBandwidth');
settings = localAlias(settings, raw, 'pllNoiseBandwidth_stab', 'pllNoiseBandwidth');
settings = localAlias(settings, raw, 'pllNoiseBandwidth_pull', 'pllNoiseBandwidth_init');
if ~isfield(raw, 'fineCodeSearchHalfWinSamples')
    settings.fineCodeSearchHalfWinSamples = ceil(2*settings.samplingFreq/settings.codeFreqBasis);
end
% Digital amplitudes are not dBm values: conversion includes ADC calibration
% and sample rate. Explicit digital thresholds remain unchanged on replay.
if ~localSupplied(raw, 'PB_settings', 'Th_static')
    settings.PB_settings.Th_static = localAmplitude(settings, settings.Th_static_dBm);
end
if ~localSupplied(raw, 'PB_settings', 'Th_static_tracking')
    settings.PB_settings.Th_static_tracking = localAmplitude(settings, settings.Th_static_tracking_dBm);
end
% JSON null becomes []; plotting expects scalar E/N/U values or scalar NaN.
for name = {'E','N','U'}
    key = name{1}; value = settings.truePosition.(key);
    if isempty(value) || ~isnumeric(value) || ~isscalar(value)
        settings.truePosition.(key) = NaN;
    else
        settings.truePosition.(key) = double(value);
    end
end
% Preserve the legacy BDT-UTC spelling only when the canonical name is absent.
if localSupplied(raw, 'nmea', 'bdtMinusUtc') && ~localSupplied(raw, 'nmea', 'utcOffsetSeconds')
    settings.nmea.utcOffsetSeconds = raw.nmea.bdtMinusUtc;
end
validateattributes(settings.REACQ_max, {'numeric'}, {'real','scalar','finite','nonnegative'});
nReacq = round(double(settings.REACQ_max));
if numel(settings.REACQ_eachTimeWaitMs) ~= nReacq
    settings.REACQ_eachTimeWaitMs = 100*(0:nReacq-1);
else
    settings.REACQ_eachTimeWaitMs = reshape(settings.REACQ_eachTimeWaitMs,1,[]);
end
validateattributes(settings.parMaxWorkers, {'numeric'}, {'real','scalar','finite'});
settings.parMaxWorkers = max(1,min(6,round(settings.parMaxWorkers)));

%% Cap the requested duration using the final IF geometry ===================
% Keep one second of real input after tracking, as required by the existing
% acquisition/reacquisition workflow. Missing files warn here and fail when
% a runner opens them; an existing file with no usable interval is an error.
validateattributes(settings.msToProcess, {'numeric'}, ...
    {'real','scalar','finite','positive'}, mfilename, 'msToProcess');
requestedMs = double(settings.msToProcess);
assert(requestedMs>=1,'initSettings:BadDuration','msToProcess must be at least 1 ms.');
settings.msToProcess = floor(requestedMs);
fileInfo = dir(fullfile(settings.filePath, settings.fileName));
if isempty(fileInfo)
    warning('initSettings:FileMissing', 'IF file not found: %s', fullfile(settings.filePath,settings.fileName));
else
    assert(isscalar(fileInfo) && ~fileInfo.isdir,'initSettings:BadFile','Expected one IF file.');
    maxMs = floor(1e3*(double(fileInfo.bytes)-settings.skipNumberOfBytes) / ...
        settings.size_per_sample/settings.samplingFreq-1e3);
    assert(maxMs>=1,'initSettings:FileTooShort','IF file is too short after skip/reserved tail.');
    settings.msToProcess = min(settings.msToProcess,maxMs);
    if settings.msToProcess < requestedMs
        warning('initSettings:CapMs','msToProcess capped to file length: %d ms',settings.msToProcess);
    end
end

% Only now create configured directories, after geometry/duration checks.
% Runners may replace these with their per-run outDir/temp layout.
if ~exist(settings.tempdataSvPth,'dir'), mkdir(settings.tempdataSvPth); end
if ~exist(settings.resultRoot,'dir'), mkdir(settings.resultRoot); end
end

function raw = localOverrides(defaults, varargin)
% Accept a partial/complete scalar struct or ordinary name/value overrides.
% Known names are matched case-insensitively (as before); partial matching is
% disabled to avoid ambiguous new fields. Extension fields are preserved,
% not silently discarded, so transport does not restrict receiver settings.
    if isscalar(varargin) && isstruct(varargin{1})
        assert(isscalar(varargin{1}),'initSettings:BadSettings','Settings must be a scalar struct.');
        raw = varargin{1}; return;
    end
    p = inputParser; p.KeepUnmatched = true; p.PartialMatching = false;
    names = fieldnames(defaults);
    for k=1:numel(names), addParameter(p,names{k},defaults.(names{k})); end
    parse(p,varargin{:}); raw = p.Unmatched;
    supplied = setdiff(names,p.UsingDefaults);
    for k=1:numel(supplied), raw.(supplied{k}) = p.Results.(supplied{k}); end
end

function target = localMerge(target, source)
% Recursively merge scalar substructures so partial FLL/KF/PB/NMEA options
% retain defaults. Unknown extension fields survive JSON and struct replay.
    names = fieldnames(source);
    for k=1:numel(names)
        name = names{k}; value = source.(name);
        if isfield(target,name) && isstruct(target.(name)) && isscalar(target.(name))
            assert(isstruct(value) && isscalar(value),'initSettings:BadNestedSetting', ...
                '%s must be a scalar structure.',name);
            target.(name) = localMerge(target.(name),value);
        else
            target.(name) = value;
        end
    end
end

function settings = localAlias(settings, raw, canonical, alias)
% Canonical wins when both are supplied; keep the consumer-facing alias equal.
    if isfield(raw,alias) && ~isfield(raw,canonical), settings.(canonical)=raw.(alias); end
    settings.(alias)=settings.(canonical);
end

function supplied = localSupplied(raw, parent, name)
    supplied = isfield(raw,parent) && isstruct(raw.(parent)) && isscalar(raw.(parent)) && isfield(raw.(parent),name);
end

function amplitude = localAmplitude(settings, thresholdDbm)
    digitalDb = thresholdDbm-settings.usrp.scaleK-settings.usrp.gain+10*log10(settings.samplingFreq);
    amplitude = 10.^(digitalDb/20);
end

function list = localParsePrnList(value)
% Canonical row vector for both MATLAB arrays and jsondecode column vectors.
% UI strings support "11,19", "11;19", "11 19", "1:63", and "1:2:63".
    if isnumeric(value)
        list=double(value(:).');
    elseif iscell(value)
        list=str2double(string(value(:).'));
    else
        value=strtrim(char(string(value)));
        if contains(value,':')
            numbers=str2double(split(value,':'));
            assert(all(isfinite(numbers)) && ismember(numel(numbers),[2 3]), ...
                'initSettings:BadPrnList','Invalid PRN range.');
            if numel(numbers)==2
                list=numbers(1):numbers(2);
            else
                assert(numbers(2)~=0,'initSettings:BadPrnList','PRN range step cannot be zero.');
                list=numbers(1):numbers(2):numbers(3);
            end
        else
            list=str2double(regexp(value,'[,;\s]+','split'));
        end
        assert(~isempty(list),'initSettings:BadPrnList','PRN text must contain a satellite number.');
    end
    assert(all(isfinite(list) & list>=1 & list==round(list)), ...
        'initSettings:BadPrnList','PRNs must be positive finite integers.');
    list=reshape(list,1,[]);
end
