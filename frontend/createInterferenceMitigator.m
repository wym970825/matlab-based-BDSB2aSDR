function mitigator = createInterferenceMitigator(settings,stage)
%CREATEINTERFERENCEMITIGATOR One exclusive frontend; legacy PB stage rules.
    if nargin<2, stage='tracking'; end
    settings = resolveFrontendSettings(settings);
    switch settings.Frontend.mode
        case 'off'
            mitigator = [];
        case 'pb'
            if strcmp(stage,'tracking') && isfield(settings.PB_settings,'Th_static_tracking')
                settings.PB_settings.Th_static = settings.PB_settings.Th_static_tracking;
            end
            mitigator = pulseBlanker(settings);
        case 'tf_v1'
            mitigator = TFBlankerV1(settings);
    end
end
