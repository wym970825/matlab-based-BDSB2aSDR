function [colors, palette] = data1020_purple_orange()
%DATA1020_PURPLE_ORANGE Exact sequential palette from the user's reference.
% Source: H:/dme_L5_Scintillation-v3/apps/analysis/
%         plot_sec4_pps_heatmaps_rightbar.m, localColorMap (RMSE/MAE).
% sRGB anchors, D65 CIELAB interpolation and 257 samples are preserved.
    anchors = [53,36,88;101,67,116;150,97,121;197,135,123; ...
        230,167,113;244,187,111]/255;
    lab = localRgbToLab(anchors);
    positions = (lab(:,1)-lab(1,1))/(lab(end,1)-lab(1,1));
    colors = localLabToRgb(interp1(positions,lab,linspace(0,1,257),'linear'));
    colors([1,end],:) = anchors([1,end],:);
    palette = struct('name','Muted purple-orange sequential', ...
        'anchorRGB',anchors,'anchorPositions',positions.', ...
        'samples',257,'interpolation','Linear CIELAB, D65 white point', ...
        'source','H:/dme_L5_Scintillation-v3/apps/analysis/plot_sec4_pps_heatmaps_rightbar.m');
end

function lab = localRgbToLab(rgb)
    m = [0.4124564,0.3575761,0.1804375; ...
        0.2126729,0.7151522,0.0721750;0.0193339,0.1191920,0.9503041];
    linearRgb = rgb/12.92;
    nonlinear = rgb>0.04045;
    linearRgb(nonlinear) = ((rgb(nonlinear)+0.055)/1.055).^2.4;
    xyz = (linearRgb*m.')./[0.95047,1,1.08883];
    delta = 6/29;
    transformed = xyz/(3*delta^2)+4/29;
    cubeRoot = xyz>delta^3;
    transformed(cubeRoot) = xyz(cubeRoot).^(1/3);
    lab = [116*transformed(:,2)-16, ...
        500*(transformed(:,1)-transformed(:,2)), ...
        200*(transformed(:,2)-transformed(:,3))];
end

function rgb = localLabToRgb(lab)
    m = [0.4124564,0.3575761,0.1804375; ...
        0.2126729,0.7151522,0.0721750;0.0193339,0.1191920,0.9503041];
    fy = (lab(:,1)+16)/116;
    transformed = [fy+lab(:,2)/500,fy,fy-lab(:,3)/200];
    delta = 6/29;
    xyz = 3*delta^2*(transformed-4/29);
    cubic = transformed>delta;
    xyz(cubic) = transformed(cubic).^3;
    linearRgb = (xyz.*[0.95047,1,1.08883])/m.';
    rgb = 12.92*linearRgb;
    nonlinear = linearRgb>0.0031308;
    rgb(nonlinear) = 1.055*linearRgb(nonlinear).^(1/2.4)-0.055;
    rgb = max(0,min(1,rgb));
end
