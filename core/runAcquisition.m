function acqResults = runAcquisition(fid, settings, dataAdaptCoeff)
%RUNACQUISITION Acquisition through the selected frontend with physical origin.

    settings = resolveFrontendSettings(settings);
    source = IFSource(settings,'acquisition');
    sourceCleaner = onCleanup(@() delete(source));
    inputStart = ftell(fid)/source.BytesPerSample;
    source.seekAbs(max(inputStart,source.Halo));
    inputStart = source.tellLogical();

    coarseMs = 1;
    if isfield(settings, 'coarseNoncohMs') && ~isempty(settings.coarseNoncohMs)
        coarseMs = max(1, round(settings.coarseNoncohMs));
    end
    samplesNeededMs = max(coarseMs, round(settings.fineNoncoh) + 1);
    sampleCount = round(settings.samplingFreq/(settings.codeFreqBasis/settings.codeLength))*samplesNeededMs;
    debugPlot = strcmp(source.Mode,'pb') && isfield(settings,'PB_settings') && ...
        isfield(settings.PB_settings,'debugplot') && logical(settings.PB_settings.debugplot);
    if debugPlot
        data = source.readRawRange(inputStart,sampleCount);
        source.seekAbs(inputStart+numel(data));
    else
        [data,meta] = source.read(sampleCount);
        assert(meta.validCount==sampleCount,'runAcquisition:InvalidFrontend', ...
            'Acquisition requires a complete valid frontend interval.');
    end
    assert(numel(data)==sampleCount,'readIfBlock:EOF','Not enough samples for acquisition.');
    assert(dataAdaptCoeff==settings.fileType,'runAcquisition:Format','IF format coefficient mismatch.');
    fseek(fid,source.tellLogical()*source.BytesPerSample,'bof');

    if debugPlot
            pb = source.Mitigator;
            [data, fig] = pb.f_mitigate(data, settings.usrp.scaleK, ...
                settings.usrp.gain, settings.samplingFreq);
            cleaner = onCleanup(@() localCloseFigure(fig));
            if isfield(settings, 'resultRoot') && ~isempty(settings.resultRoot)
                acqFigDir = fullfile(settings.resultRoot, 'figures', 'AcqResult');
                if ~exist(acqFigDir, 'dir'), mkdir(acqFigDir); end
                saveas(fig, fullfile(acqFigDir, 'pb_acquisition.png'));
            end
    end

    fprintf('   Acquiring satellites (list = %s)...\n', ...
        mat2str(settings.acqSatelliteList));
    acqResults = acquisition_robust_v2fft(data, settings, ...
        'STA', 'INIT', 'USEFFT', false);
    acqResults.acqInputStartAbs = inputStart;
    acqResults.acqInputCount = numel(data);
    acqResults.frontendInfo = source.Info;
end

function localCloseFigure(fig)
    if ~isempty(fig) && isgraphics(fig)
        close(fig);
    end
end
