function acqResults = runAcquisition(fid, settings, dataAdaptCoeff)
%RUNACQUISITION B2a acquisition stage with optional pulse blanking.

    samplesNeededMs = settings.fineNoncoh + 2;
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
                saveas(fig, fullfile(settings.resultRoot, 'pb_acquisition.png'));
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
