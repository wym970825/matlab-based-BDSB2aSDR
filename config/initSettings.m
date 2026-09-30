function settings = initSettings(varargin)
%INITSETTINGS Receiver configuration for BDS-3 B2a SDR (refactored).
%
%   settings = initSettings()
%   settings = initSettings('Name', Value, ...)
%
% Name-Value overrides (optional):
%   'msToProcess'       - processing length [ms]
%   'acqSatelliteList'  - PRN list for acquisition
%   'filePath'          - IF data directory
%   'fileName'          - IF data file name
%   'EnablePB'          - pulse blanker enable
%   'skipAcquisition'   - 1 to skip acquisition
%   'plotTracking'      - 0/1
%   'numberOfChannels'  - channel count
%   'resultRoot'        - where to write results (default: <project>/results)
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
settings.startOffset   = 68.802;    % [ms]
settings.IFBandwidth   = 30e6;

%% Pulse blanker ===========================================================
settings.EnablePB = true;
settings.PB_settings.UseStatic   = true;
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
settings.PB_settings.falseAlert  = 5e-3;
settings.PB_settings.Th_TTL      = 5;
settings.PB_settings.debugplot   = true;  % quieter default in refactor

%% Acquisition =============================================================
settings.skipAcquisition  = 0;
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
settings.longCoh_ms      = 5;
settings.weilEstBuffLen  = 100;
settings.weilConfTh      = 1.5;
settings.TrkCN0Th        = 29;

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

settings.intTime      = 0.001;
settings.pilotTRKflag = 1;
settings.CNoInterval  = 200;
settings.CNo_Th       = 30;

% Carrier-aided code NCO (default ON): f_code = f0 - carrFreq*(f0/fL) - codeNco
% Instantaneous carrFreq; aid limited in *code-domain* Hz (50 ≈ 5.75 kHz carrier Doppler).
settings.carrierAidCode       = true;
settings.carrierAidCodeMaxHz  = 50;

%% FLL-aided PLL ===========================================================
settings.FLL = struct();
settings.FLL.enable          = true;
settings.FLL.aidingEnable    = true;
settings.FLL.useBpskFold     = true;
settings.FLL.smoothAlpha     = 0.5;
settings.FLL.maxCorrHz       = 100;
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
settings.FLLinitT            = 150;

%% Carrier KF (default OFF) ================================================
settings.KF = struct();
settings.KF.enable              = false;
settings.KF.enableFeedback      = false;
settings.KF.feedbackGain        = 1;
settings.KF.qJerk               = (0.3*pi*2)^2;
settings.KF.RphiFloor_deg       = 3;
settings.KF.RphiCeil            = 45;
settings.KF.RomegaFloor_Hz      = 1;
settings.KF.maxCorrHz           = 100;
settings.KF.scintAdaptiveEnable = true;
settings.KF.scintWarmup_ms      = 150e3;
settings.KF.rmsBeta             = 0.98;

%% Scintillation calculator =================================================
% Scintillation index batch interval (ms). push() still 1 ms; heavy
% filter/stats run only every scint_updateMs. 5000 = 5 s (mexBaseFast).
settings.scint_updateMs = 5000;
settings.scint_bufLen   = 60000;
settings.scint_fCutoff  = 0.1;

%% Re-acquisition ==========================================================
settings.REACQ_max          = 5;
settings.REACQ_eachTimeWaitMs = 100*(0:settings.REACQ_max-1);
settings.max_reacqT         = 10;
settings.reacqCnoConsecutive = 3;   % independent C/N0 updates below threshold
settings.reacqCnoRecoverDbHz = 32;  % hysteresis reset threshold

%% Navigation ==============================================================
settings.navSolPeriod   = 500;  % [ms]
settings.elevationMask  = 5;
settings.useTropCorr    = 1;
settings.truePosition.E = nan;
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

%% Apply optional overrides =================================================
if ~isempty(varargin)
    p = inputParser;
    p.KeepUnmatched = true;
    addParameter(p, 'msToProcess',      settings.msToProcess);
    addParameter(p, 'acqSatelliteList', settings.acqSatelliteList);
    addParameter(p, 'filePath',         settings.filePath);
    addParameter(p, 'fileName',         settings.fileName);
    addParameter(p, 'EnablePB',         settings.EnablePB);
    addParameter(p, 'skipAcquisition',  settings.skipAcquisition);
    addParameter(p, 'plotTracking',     settings.plotTracking);
    addParameter(p, 'numberOfChannels', settings.numberOfChannels);
    addParameter(p, 'acqSearchBand',   settings.acqSearchBand);
    addParameter(p, 'acqThreshold',    settings.acqThreshold);
    addParameter(p, 'acqStep',         settings.acqStep);
    addParameter(p, 'coarseNoncohMs',  settings.coarseNoncohMs);
    addParameter(p, 'acqFlipSegments', settings.acqFlipSegments);
    addParameter(p, 'fineNoncoh',      settings.fineNoncoh);
    addParameter(p, 'fineStepHz',      settings.fineStepHz);
    addParameter(p, 'fineSearchInitialHalfSpanHz', ...
        settings.fineSearchInitialHalfSpanHz);
    addParameter(p, 'fineSearchMaxHalfSpanHz', ...
        settings.fineSearchMaxHalfSpanHz);
    addParameter(p, 'resultRoot',       settings.resultRoot);
    addParameter(p, 'tempdataSvPth',    settings.tempdataSvPth);
    addParameter(p, 'useParfor',        settings.useParfor);
    addParameter(p, 'parMaxWorkers',    settings.parMaxWorkers);
    parse(p, varargin{:});
    fn = fieldnames(p.Results);
    for i = 1:numel(fn)
        settings.(fn{i}) = p.Results.(fn{i});
    end
end
% Enforce hard cap even if caller passes a larger value
if isfield(settings, 'parMaxWorkers')
    settings.parMaxWorkers = max(1, min(6, round(settings.parMaxWorkers)));
end

if ~exist(settings.tempdataSvPth, 'dir')
    mkdir(settings.tempdataSvPth);
end
if ~exist(settings.resultRoot, 'dir')
    mkdir(settings.resultRoot);
end

%% Cap msToProcess by file length ==========================================
fileInfo = dir(fullfile(settings.filePath, settings.fileName));
if isempty(fileInfo)
    warning('initSettings:FileMissing', ...
        'IF file not found: %s', fullfile(settings.filePath, settings.fileName));
else
    msToProcessMax = 1e3 * ((fileInfo.bytes) / settings.size_per_sample ...
        / settings.samplingFreq - skipNumberOfSeconds - 1);
    if msToProcessMax < settings.msToProcess
        settings.msToProcess = floor(msToProcessMax);
        warning('initSettings:CapMs', ...
            'msToProcess capped to file length: %d ms', settings.msToProcess);
    end
end
end
