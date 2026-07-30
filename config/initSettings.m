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
settings.msToProcess      = 300e3;   % [ms] full-length default
settings.numberOfChannels = 12;

%% IF file =================================================================
settings.filePath = 'F:\Data\DME_BDSB2a\Experiment\2022BJ\DATA1020';
settings.fileName = '300sData_@111407_221020@_1176450000_20000000_0_20000000_ZeroIF.bin';
settings.dataType = 'int16';
settings.fileType = 2;              % 1=real, 2=IQ interleaved
settings.IF       = 0e3;            % [Hz]
settings.samplingFreq = 20e6;       % [Hz]
settings.usrp.scaleK  = -94.72;
settings.usrp.gain    = 60;

%% B2a code / carrier ======================================================
settings.codeLength    = 10230;     % [chip]
settings.codeFreqBasis = 10.23e6;   % [Hz]
settings.carrFreqBasis = 1176.45e6; % [Hz]
settings.c             = 299792458;
settings.startOffset   = 68.802;    % [ms]
settings.IFBandwidth   = 18e6;

%% Pulse blanker ===========================================================
settings.EnablePB = true;
settings.PB_settings.UseStatic   = true;
settings.Th_static_dBm           = -76.5;
threshold_digdB = settings.Th_static_dBm - settings.usrp.scaleK - ...
    settings.usrp.gain + 10*log10(settings.samplingFreq);
settings.PB_settings.Th_static   = 10.^(threshold_digdB/20);
settings.PB_settings.falseAlert  = 1e-4;
settings.PB_settings.Th_TTL      = 5;
settings.PB_settings.debugplot   = false;  % quieter default in refactor

%% Acquisition =============================================================
settings.skipAcquisition  = 0;
% Smoke baseline from legacy initSettings (good satellites for this dataset)
settings.acqSatelliteList = [24, 38, 39, 41];
settings.acqSearchBand    = 5000;   % [Hz] single-side
settings.acqThreshold     = 2;
settings.acqStep          = 125;    % [Hz]
settings.fineNoncoh       = 5;      % [ms]
settings.fineCodeSearchHalfWinSamples = ceil(2*(settings.samplingFreq / ...
    settings.codeFreqBasis));
settings.resamplingThreshold = 50e6;
settings.resamplingflag      = 0;

%% Skip / duration vs file size ============================================
skipNumberOfSeconds = 0;
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
settings.dllNoiseBandwidth_pull  = 10;   % [Hz] INIT pull-in (was fixed 2 Hz)
settings.dllNoiseBandwidth_stab  = 2;    % [Hz] after pull-in / LONG
settings.dllNoiseBandwidth       = settings.dllNoiseBandwidth_stab; % legacy alias

settings.trackInit_MS    = 3000;   % INIT duration before ESTI/Weil
settings.filter_pullinMS = 2000;   % pull-in window: PLL+DLL use *_pull BW
settings.reEstimateMS    = 10e3;
settings.pllOrder        = 3;
settings.pllDampingRatio = 0.707;
settings.phaseDisType    = 2;
settings.longCoh_ms      = 1;
settings.weilEstBuffLen  = 100;
settings.weilConfTh      = 1.5;
settings.TrkCN0Th        = 25;

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

settings.intTime      = 0.001;
settings.pilotTRKflag = 1;
settings.CNoInterval  = 200;
settings.CNo_Th       = 30;

% Carrier-aided code NCO: f_code = f0 + carrFreq*(f0/fL) - codeNco
% Aid is limited in *code-domain* Hz (50 Hz ≈ 5.75 kHz carrier Doppler).
settings.carrierAidCode       = true;
settings.carrierAidCodeMaxHz  = 50;

%% FLL-aided PLL ===========================================================
settings.FLL = struct();
settings.FLL.enable          = true;
settings.FLL.aidingEnable    = true;
settings.FLL.useBpskFold     = true;
settings.FLL.smoothAlpha     = 0.5;
settings.FLL.maxCorrHz       = 100;
settings.FLL.errThInitOn_Hz  = 15;
settings.FLL.errThInitOff_Hz = 10;
settings.FLL.errThLongOn_Hz  = 15;
settings.FLL.errThLongOff_Hz = 10;
settings.FLL.N_on            = 5;
settings.FLL.N_off           = 10;
settings.FLL.gainInit        = 0.02;
settings.FLL.gainLong        = 0.01;
settings.FLL.filtZeta        = 0.707;
settings.FLL.BW_Init_Hz      = 100;
settings.FLL.BW_Long_Hz      = 100;
settings.FLLinitT            = 100;

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

%% Navigation ==============================================================
settings.navSolPeriod   = 500;  % [ms]
settings.elevationMask  = 5;
settings.useTropCorr    = 1;
settings.truePosition.E = nan;
settings.truePosition.N = nan;
settings.truePosition.U = nan;

%% Plot / I/O ==============================================================
settings.plotTracking = 1;

%% Multi-SV parallel tracking (par-fast-matlab) ============================
% Option A: each worker fopen()s the IF file privately. Hard cap 6 cores.
settings.useParfor     = true;   % parfor when >=2 active SVs
settings.parMaxWorkers = 6;      % max local workers (also hard-capped in code)

% Project-local result roots (override legacy absolute thesis paths)
projectRoot = fileparts(fileparts(mfilename('fullpath')));
settings.resultRoot     = fullfile(projectRoot, 'results');
settings.tempdataSvPth  = fullfile(settings.resultRoot, 'temp', ...
    string(datetime('now'), 'yyMMdd_HHmmss'));

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
