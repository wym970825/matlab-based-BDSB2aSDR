function acqResults = runAcquisition(fid, settings, dataAdaptCoeff)
%RUNACQUISITION B2a acquisition stage with optional pulse blanking.

    coarseMs = 1;
    if isfield(settings, 'coarseNoncohMs') && ~isempty(settings.coarseNoncohMs)
        coarseMs = max(1, round(settings.coarseNoncohMs));
    end
    samplesNeededMs = max(coarseMs, round(settings.fineNoncoh) + 1);
    data = readIfBlock(fid, settings, dataAdaptCoeff, samplesNeededMs);

    if isfield(settings, 'EnablePB') && settings.EnablePB
        pb = pulseBlanker(settings);
        debugPlot = isfield(settings, 'PB_settings') && ...
            isfield(settings.PB_settings, 'debugplot') && ...
            logical(settings.PB_settings.debugplot);
        if debugPlot
            [data, fig] = pb.f_mitigate(data, settings.usrp.scaleK, ...
                settings.usrp.gain, settings.samplingFreq);
            cleaner = onCleanup(@() localCloseFigure(fig));
            if isfield(settings, 'resultRoot') && ~isempty(settings.resultRoot)
                acqFigDir = fullfile(settings.resultRoot, 'figures', 'AcqResult');
                if ~exist(acqFigDir, 'dir'), mkdir(acqFigDir); end
                saveas(fig, fullfile(acqFigDir, 'pb_acquisition.png'));
            end
        else
            data = pb.mitigate(data);
        end
    end

    fprintf('   Acquiring satellites (list = %s)...\n', ...
        mat2str(settings.acqSatelliteList));
    acqResults = acquisition_robust_v2fft(data, settings, ...
        'STA', 'INIT', 'USEFFT', false);
end

function localCloseFigure(fig)
    if ~isempty(fig) && isgraphics(fig)
        close(fig);
    end
end
