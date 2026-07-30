function [channel] = preRun2(acqResults, settings)

channel                 = [];
channel.PRN             = 0;
channel.acquiredFreq    = 0;
channel.codePhase       = 0;
channel.codeFreq        = 0;
channel.status          = '-';
channel.weilPhase   = 0;   % NEW: Weil(100) start phase from acquisition
channel.polarityRef = 1;   % NEW: +1/-1 from acquisition (pilot Psum sign)

channel = repmat(channel, 1, settings.numberOfChannels);
SatList = settings.acqSatelliteList;
% --- 1) 统一“是否捕获成功”的判据（兼容 NaN 和 0 两种风格）
cf = acqResults.carrFreq(:).';
if all(isnan(cf))
    acquiredMask = false(size(cf));
else
    acquiredMask = isfinite(cf) & (cf ~= 0);
end

% --- 2) 只在已捕获的星里按强度排序（更合理）
pm = acqResults.peakMetric(:).';
pm(~acquiredMask) = -inf;  % 未捕获的排到最后
[~, idxSorted] = sort(pm, 'descend');

% --- 3) 初始化通道：PRN 必须用 SatList 映射
nInit = min(settings.numberOfChannels, sum(acquiredMask));
for ii = 1:nInit
    k = idxSorted(ii);              % k 是 acqResults 的索引（1..length(SatList)）
    prn = SatList(k);               % 真正的 PRN

    channel(ii).PRN          = prn;
    channel(ii).acquiredFreq = acqResults.carrFreq(k);
    channel(ii).codePhase    = acqResults.codePhase(k);
    channel(ii).codePhaseAbs = acqResults.codePhaseAbs(k);
    channel(ii).codeFreq     = settings.codeFreqBasis;
    channel(ii).status       = 'T';
    channel(ii).weilPhase   = acqResults.weilPhase(k);
    channel(ii).polarityRef = acqResults.polarityRef(k);

end
end
