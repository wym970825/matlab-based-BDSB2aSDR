function plotAcquisition(acqResults, SatList)
%plotAcquisition  Bar plots for acquisition metrics and CN0.
%
% Usage:
%   plotAcquisition(acqResults, settings.acqSatelliteList)
%
% Inputs:
%   acqResults - struct from acquisition/acquisition_robust
%   SatList    - PRN list corresponding to acqResults vectors (x-axis labels)
%
% Plots:
%   1) peakMetric  (CPPR-like)
%   2) peakMetric2 (CPPM-like)
%   3) CN0_pilot   (dB-Hz) if available

% -----------------------------
% Validate inputs
% -----------------------------
if nargin < 2 || isempty(SatList)
    error('plotAcquisition requires SatList as the 2nd input.');
end

SatList = SatList(:).';
n = numel(SatList);

% Helper to fetch a field safely
getField = @(s, f, default) (isfield(s,f) && ~isempty(s.(f))) .* 0 + ...
    (isfield(s,f) && ~isempty(s.(f))) .* 1; %#ok<NASGU>
% (We won’t use getField trick; keep it simple below.)

if ~isfield(acqResults, 'peakMetric') || ~isfield(acqResults, 'peakMetric2')
    error('acqResults must contain fields peakMetric and peakMetric2.');
end

pm1 = acqResults.peakMetric(:).';
pm2 = acqResults.peakMetric2(:).';

% Basic length check: allow mismatch but warn and truncate to min
minLen = min([numel(pm1), numel(pm2), n]);
if numel(pm1) ~= n || numel(pm2) ~= n
    warning('Length mismatch: SatList=%d, peakMetric=%d, peakMetric2=%d. Truncating to %d.', ...
        n, numel(pm1), numel(pm2), minLen);
    SatList = SatList(1:minLen);
    pm1 = pm1(1:minLen);
    pm2 = pm2(1:minLen);
    n = minLen;
end

% Detect acquired satellites (robust to legacy carrFreq==0 and new NaN)
acqMask = false(1,n);
if isfield(acqResults, 'carrFreq') && ~isempty(acqResults.carrFreq)
    cf = acqResults.carrFreq(:).';
    if numel(cf) ~= n
        cf = cf(1:n);
    end
    % robust: acquired if carrFreq is finite and non-zero (or at least not NaN)
    acqMask = isfinite(cf) & (cf ~= 0);
else
    % fallback: use peakMetric finite as weak indicator
    acqMask = isfinite(pm1);
end

% CN0 (optional)
hasCN0 = isfield(acqResults, 'CN0_pilot') && ~isempty(acqResults.CN0_pilot);
if hasCN0
    cn0 = acqResults.CN0_pilot(:).';
    if numel(cn0) ~= n
        cn0 = cn0(1:n);
    end
    % sanitize
    cn0(~isfinite(cn0)) = NaN;
end

% Sanitize metrics
pm1(~isfinite(pm1)) = NaN;
pm2(~isfinite(pm2)) = NaN;

% Plot layout
nRows = 2 + hasCN0;  % 2 or 3 panels
figH = figure('Color','w', 'Name','Acquisition Metrics', 'NumberTitle','off');
set(figH, 'Position', [100, 100, 900, 320*nRows]);

% Common x settings
x = 1:n;
xLabels = string(SatList);

% -----------------------------
% Panel 1: peakMetric
% -----------------------------
ax1 = subplot(nRows,1,1);
plotBarWithHighlight(ax1, pm1, acqMask, 'PeakMetric1 (CPPR-like)', 'Metric', xLabels);

% -----------------------------
% Panel 2: peakMetric2
% -----------------------------
ax2 = subplot(nRows,1,2);
plotBarWithHighlight(ax2, pm2, acqMask, 'PeakMetric2 (CPPM-like)', 'Metric', xLabels);

% -----------------------------
% Panel 3: CN0 (optional)
% -----------------------------
if hasCN0
    ax3 = subplot(nRows,1,3);
    plotBarWithHighlight(ax3, cn0, acqMask, 'C/N0 (pilot, dB-Hz)', 'dB-Hz', xLabels);
end

% Link x-axes for synchronized zoom/pan
if hasCN0
    linkaxes([ax1,ax2,ax3],'x');
else
    linkaxes([ax1,ax2],'x');
end

end % function


% ======================================================================
% Local helper
% ======================================================================
function plotBarWithHighlight(ax, values, acqMask, ttl, ylab, xLabels)

axes(ax); %#ok<LAXES>
cla(ax);

n = numel(values);
x = 1:n;

% Base bars (all)
b1 = bar(ax, x, values, 'FaceColor', [0.65 0.65 0.65], 'EdgeColor', 'none'); %#ok<NASGU>
hold(ax, 'on');

% Highlight acquired bars
v2 = values;
v2(~acqMask) = NaN;
b2 = bar(ax, x, v2, 'FaceColor', [0.00 0.60 0.00], 'EdgeColor', 'none'); %#ok<NASGU>

hold(ax, 'off');

title(ax, ttl, 'Interpreter','none');
ylabel(ax, ylab, 'Interpreter','none');
grid(ax, 'on');
ax.YGrid = 'on';
ax.XGrid = 'off';
ax.Box = 'on';

% X ticks & labels
ax.XTick = x;
ax.XTickLabel = xLabels;
ax.XTickLabelRotation = 0;

% Make it readable if many PRNs
if n > 24
    ax.XTickLabelRotation = 45;
end

xlabel(ax, 'PRN');

% Auto y-limits with headroom
y = values(isfinite(values));
if isempty(y)
    ylim(ax, [0 1]);
else
    ymin = min(y);
    ymax = max(y);
    if ymin >= 0
        ylim(ax, [0, ymax * 1.15 + eps]);
    else
        pad = 0.15 * max(abs([ymin,ymax]));
        ylim(ax, [ymin - pad, ymax + pad]);
    end
end

% Legend (only once per axis)
legend(ax, {'All searched', 'Acquired'}, 'Location','best');

end
