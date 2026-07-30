function acqResults = runAcquisition(fid, settings, dataAdaptCoeff)
%RUNACQUISITION B2a acquisition stage with optional pulse blanking.

    samplesNeededMs = settings.fineNoncoh + 2;
    data = readIfBlock(fid, settings, dataAdaptCoeff, samplesNeededMs);

    if isfield(settings, 'EnablePB') && settings.EnablePB
        pb = pulseBlanker(settings);
        data = pb.f_mitigate(data, settings.usrp.scaleK, ...
            settings.usrp.gain, settings.samplingFreq);
    end

    fprintf('   Acquiring satellites (list = %s)...\n', ...
        mat2str(settings.acqSatelliteList));
    acqResults = acquisition_robust_v2fft(data, settings, ...
        'STA', 'INIT', 'USEFFT', false);
end
