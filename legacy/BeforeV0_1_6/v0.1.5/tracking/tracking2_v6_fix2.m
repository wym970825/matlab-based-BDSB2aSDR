function [Tres, Ch] = tracking2_v6_fix2(fid, Ch, settings)
%TRACKING2_V6_FIX2 Multi-channel B2a tracking (serial or parfor).
%
%   [trackResults, channel] = tracking2_v6_fix2(fid, channel, settings)
%
% Each satellite is tracked by trackOneChannel with a **private** IF file
% handle (Option A in docs/optimization_plan.md). Multi-SV runs use parfor
% when enabled, capped at settings.parMaxWorkers (default 6).
%
%   settings.useParfor      - true (default): parfor when >=2 active SVs
%   settings.parMaxWorkers  - max local workers (default 6)
%
% Input fid is retained for API compatibility; tracking does not share it
% across channels (avoids concurrent fseek/fread races).

%--------------------------------------------------------------------------
%                         CU Multi-GNSS SDR
% (C) Developed for BDS B2a SDR by Yafeng Li, Nagaraj C. Shivaramaiah
% and Dennis M. Akos.
%
%                         KF-FLL-Aided + par-fast-matlab
% Xiaoyeyimier version 6 using FLL aided PLL (try KF)
% work with NH_stateMachine.m TrackResults2.m and trackOneChannel.m
%--------------------------------------------------------------------------

    %% Count active channels
    TrkedNr = 0;
    nCh = settings.numberOfChannels;
    for c_i = 1:nCh
        if Ch(c_i).status == 'T' || Ch(c_i).PRN ~= 0
            TrkedNr = TrkedNr + 1;
        end
    end

    Tres = TrackResults2.createArray(settings, nCh);

    % Parallel policy
    useParfor = true;
    if isfield(settings, 'useParfor') && ~isempty(settings.useParfor)
        useParfor = logical(settings.useParfor);
    end
    parMaxWorkers = 6;
    if isfield(settings, 'parMaxWorkers') && ~isempty(settings.parMaxWorkers)
        parMaxWorkers = max(1, round(settings.parMaxWorkers));
    end
    parMaxWorkers = min(parMaxWorkers, 6);  % hard cap: max 6 cores

    activeMask = false(1, nCh);
    for c_i = 1:nCh
        activeMask(c_i) = (Ch(c_i).PRN ~= 0);
    end
    nActive = nnz(activeMask);

    doPar = useParfor && nActive >= 2;
    nWorkers = 0;
    if doPar
        nWorkers = ensureTrackParPool(min(parMaxWorkers, nActive));
        doPar = nWorkers >= 2;
    end

    if doPar
        fprintf(['tracking2: parfor multi-SV  active=%d  workers=%d  ' ...
            'cap=%d  msToProcess=%d\n'], nActive, nWorkers, parMaxWorkers, ...
            settings.msToProcess);
        trCell = cell(1, nCh);
        chCell = cell(1, nCh);
        ChSnap = Ch;  % broadcast copy
        % Slice by channel index; each worker opens its own IF file.
        parfor c_i = 1:nCh
            if ChSnap(c_i).PRN ~= 0
                [trCell{c_i}, chCell{c_i}] = trackOneChannel( ...
                    ChSnap(c_i), settings, c_i, TrkedNr);
            end
        end
        for c_i = 1:nCh
            if ~isempty(trCell{c_i})
                Tres(c_i) = trCell{c_i};
            end
            if ~isempty(chCell{c_i})
                Ch(c_i) = mergeChannelStruct(Ch(c_i), chCell{c_i});
            end
        end
    else
        if nActive >= 2
            fprintf(['tracking2: serial multi-SV  active=%d  ' ...
                '(parfor off or pool unavailable)\n'], nActive);
        else
            fprintf('tracking2: serial single-SV  active=%d\n', nActive);
        end
        for c_i = 1:nCh
            if Ch(c_i).PRN ~= 0
                [tr, chOut] = trackOneChannel(Ch(c_i), settings, c_i, TrkedNr);
                Tres(c_i) = tr;
                Ch(c_i) = mergeChannelStruct(Ch(c_i), chOut);
            end
        end
    end

    % Parent fid is left open for caller (openIfFile / onCleanup).
    if nargin >= 1 && ~isempty(fid) && fid > 0
        % no-op: tracking uses private handles only
    end
end

function chOut = mergeChannelStruct(chBase, chNew)
%MERGECHANNELSTRUCT Copy only fields already on chBase (avoid dissimilar struct).
    chOut = chBase;
    if isempty(chNew)
        return;
    end
    fn = fieldnames(chBase);
    for i = 1:numel(fn)
        f = fn{i};
        if isfield(chNew, f)
            chOut.(f) = chNew.(f);
        end
    end
end
