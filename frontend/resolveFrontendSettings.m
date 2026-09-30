function settings = resolveFrontendSettings(settings)
%RESOLVEFRONTENDSETTINGS Normalize an exclusive off/pb/tf_v1 configuration.
% Missing Frontend.mode preserves the legacy EnablePB choice. TF thresholds
% stay in ADC amplitude units, independent of acquisition/tracking stage.
    input = struct();
    if isfield(settings,'Frontend') && ~isempty(settings.Frontend)
        assert(isstruct(settings.Frontend) && isscalar(settings.Frontend), ...
            'Frontend:InvalidConfig','Frontend must be a scalar structure.');
        input = settings.Frontend;
    end
    if isfield(input,'mode') && ~isempty(input.mode)
        mode = lower(char(string(input.mode)));
    elseif isfield(settings,'EnablePB') && settings.EnablePB
        mode = 'pb';
    else
        mode = 'off';
    end
    if strcmp(mode,'tf_v2')
        error('Frontend:NotImplemented','TF v2 is a research extension, not implemented.');
    end
    assert(ismember(mode,{'off','pb','tf_v1'}),'Frontend:InvalidMode', ...
        'Frontend.mode must be off, pb, or tf_v1.');
    fs = settings.samplingFreq;
    assert(isnumeric(fs) && isscalar(fs) && isfinite(fs) && fs>0, ...
        'Frontend:InvalidRate','samplingFreq must be positive and finite.');
    f = struct('mode',mode,'samplingFreq',fs);
    if strcmp(mode,'tf_v1')
        assert(settings.fileType==2 && ismember(lower(char(settings.dataType)),{'int8','int16'}), ...
            'Frontend:UnsupportedFormat','TF v1 requires interleaved signed int8/int16 IQ.');
        t = struct('centerHz',-450000,'stopbandWidthHz',400000, ...
            'transitionEachSideHz',150000,'firTaps',[], ...
            'referenceTaps',641,'referenceSamplingFreqHz',25000000, ...
            'kaiserBeta',5.65326,'thresholdAmplitude',[], ...
            'thresholdSource','PB_settings.Th_static_tracking_or_Th_static', ...
            'triangleSpanUs',12,'pulseTailMarginUs',2, ...
            'boundaryPolicy','raw_with_invalid_flag');
        if isfield(input,'TF') && ~isempty(input.TF)
            assert(isstruct(input.TF) && isscalar(input.TF), ...
                'Frontend:InvalidConfig','Frontend.TF must be a scalar structure.');
            names = fieldnames(t);
            for k = 1:numel(names)
                if isfield(input.TF,names{k}), t.(names{k}) = input.TF.(names{k}); end
            end
        end
        positive = {'stopbandWidthHz','transitionEachSideHz','referenceSamplingFreqHz','triangleSpanUs'};
        for k = 1:numel(positive), checkScalar(t.(positive{k}),positive{k},true); end
        checkScalar(t.centerHz,'centerHz',false);
        checkScalar(t.kaiserBeta,'kaiserBeta',false);
        checkScalar(t.pulseTailMarginUs,'pulseTailMarginUs',false);
        assert(t.kaiserBeta>=0 && t.pulseTailMarginUs>=0,'Frontend:InvalidConfig', ...
            'Kaiser beta and pulse margin must be nonnegative.');
        checkTaps(t.referenceTaps);
        if isempty(t.firTaps)
            D = max(1,ceil((t.referenceTaps-1)/2*fs/t.referenceSamplingFreqHz));
        else
            checkTaps(t.firTaps); D = (t.firTaps-1)/2;
        end
        assert(abs(t.centerHz)+t.stopbandWidthHz/2+t.transitionEachSideHz<fs/2, ...
            'Frontend:InvalidBand','The full TF band and transitions must lie inside Nyquist.');
        assert(strcmp(t.boundaryPolicy,'raw_with_invalid_flag'), ...
            'Frontend:InvalidBoundaryPolicy','Unsupported TF boundary policy.');
        if isempty(t.thresholdAmplitude)
            assert(isfield(settings,'PB_settings'),'Frontend:MissingThreshold','Missing PB/TF amplitude threshold.');
            if isfield(settings.PB_settings,'Th_static_tracking') && ~isempty(settings.PB_settings.Th_static_tracking)
                threshold = settings.PB_settings.Th_static_tracking;
                source = 'PB_settings.Th_static_tracking';
            elseif isfield(settings.PB_settings,'Th_static') && ~isempty(settings.PB_settings.Th_static)
                threshold = settings.PB_settings.Th_static;
                source = 'PB_settings.Th_static';
            else
                error('Frontend:MissingThreshold','Missing PB/TF amplitude threshold.');
            end
        else
            threshold = t.thresholdAmplitude; source = 'Frontend.TF.thresholdAmplitude';
        end
        checkScalar(threshold,'thresholdAmplitude',true);
        K = round(t.triangleSpanUs*1e-6*fs/2); P = round(t.pulseTailMarginUs*1e-6*fs);
        assert(K>=1,'Frontend:InvalidWindow','Triangle must span at least one sample per side.');
        t.effectiveTaps = 2*D+1; t.D = D; t.K = K; t.P = P;
        t.A = D+P+K; t.H = D+P+2*K;
        t.effectiveThresholdAmplitude = threshold; t.resolvedThresholdSource = source;
        t.actualTriangleSpanUs = 2*K/fs*1e6; t.actualPulseTailMarginUs = P/fs*1e6;
        f.TF = t;
    end
    % Preserve configured-but-inactive TF settings for later explicit mode changes.
    if ~strcmp(mode,'tf_v1') && isfield(input,'TF'), f.TF = input.TF; end
    hashInput = struct('frontend',f,'dataType',settings.dataType,'fileType',settings.fileType);
    if strcmp(mode,'pb') && isfield(settings,'PB_settings'), hashInput.PB = settings.PB_settings; end
    f.configHash = frontendHash(hashInput);
    settings.Frontend = f;
    settings.EnablePB = strcmp(mode,'pb');
    % Synchronize the legacy byte-size field for callers using initSettings
    % name/value overrides instead of the JSON finalizer.
    settings.size_per_sample=frontendSampleBytes(settings.dataType,settings.fileType);
end

function checkScalar(x,name,positive)
    assert(isnumeric(x) && isreal(x) && isscalar(x) && isfinite(x), ...
        'Frontend:InvalidConfig','%s must be a finite real scalar.',name);
    if positive, assert(x>0,'Frontend:InvalidConfig','%s must be positive.',name); end
end

function checkTaps(x)
    assert(isnumeric(x) && isscalar(x) && isfinite(x) && x>=3 && ...
        x==round(x) && mod(x,2)==1,'Frontend:InvalidTaps','FIR taps must be an odd integer >=3.');
end
