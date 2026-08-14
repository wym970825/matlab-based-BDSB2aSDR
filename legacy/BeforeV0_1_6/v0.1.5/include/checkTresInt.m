function varargout = checkTresInt(TRes)
% checkTresInt - Validate TrackResults2 integrity
%
% Three branches based on input type:
%   1. TrackResults2 object -> checks field completeness & data validity
%   2. .mat file path       -> loads file, checks for 'TrackResults2', then branch 1
%   3. directory path       -> scans for Trk_Prn_\d{2}_final.mat files, branch 2 each
%
% Outputs:
%   Branch 1 & 2: flag (1x1 logical)
%   Branch 3:     [filesName (Nx1 cell), Usable (Nx1 logical)]

    if strcmpi(class(TRes), 'TrackResults2')
        % ===== Branch 1: TrackResults2 object =====
        varargout{1} = checkOne(TRes);

    elseif ischar(TRes) || isstring(TRes)
        TRes = char(TRes);

        if exist(TRes, 'file') == 2
            % ===== Branch 2: single .mat file =====
            varargout{1} = checkMatFile(TRes);

        elseif exist(TRes, 'dir') == 7
            % ===== Branch 3: directory path =====
            [filesName, Usable] = checkDirFiles(TRes);
            varargout{1} = filesName;
            varargout{2} = Usable;

        else
            error('checkTresInt:InvalidPath', ...
                'Input string is neither a valid file nor directory: %s', TRes);
        end

    else
        error('checkTresInt:InvalidInput', ...
            'TRes must be a TrackResults2 object, .mat filename, or directory path.');
    end
end

% -------------------------------------------------------------------------
function flag = checkOne(TRes)
% Core check: field existence, Nsize>0, double array of correct size, no NaN

    % Check all 5 required fields exist
    if ~isprop(TRes, 'I_P') || ~isprop(TRes, 'Q_P') || ...
       ~isprop(TRes, 'Pilot_I_P') || ~isprop(TRes, 'Pilot_Q_P') || ...
       ~isprop(TRes, 'Nsize')
        flag = false;
        return;
    end

    % Nsize must be > 0
    if TRes.Nsize <= 0
        flag = false;
        return;
    end

    % Each of the 4 data fields: must be double, correct length, no NaN
    dataFields = {'I_P', 'Q_P', 'Pilot_I_P', 'Pilot_Q_P'};
    for i = 1:length(dataFields)
        data = TRes.(dataFields{i});

        % Must be double and match Nsize in length
        if ~isa(data, 'double') || numel(data) ~= TRes.Nsize
            flag = false;
            return;
        end

        dataN = length(data);
        Ncutoff = floor(dataN/60e3)*60e3;
        % Must not contain any NaN
        if any(isnan(data(1:Ncutoff)))
            flag = false;
            return;
        end
    end

    flag = true;
end

% -------------------------------------------------------------------------
function flag = checkMatFile(matFilePath)
% Load a .mat file, verify it contains 'TrackResults2', then branch-1 check

    try
        S = load(matFilePath);
    catch
        flag = false;
        return;
    end

    if ~isfield(S, 'finalTRes')
        flag = false;
        return;
    end

    flag = checkOne(S.finalTRes);
end

% -------------------------------------------------------------------------
function [filesName, Usable] = checkDirFiles(dirPath)
% Scan directory for Trk_Prn_\d{2}_final.mat, check each

    listing = dir(fullfile(dirPath, 'Trk_Prn_*_final.mat'));

    % Filter: keep only names matching Trk_Prn_\d{2}_final.mat
    keep = false(size(listing));
    for k = 1:length(listing)
        keep(k) = ~isempty(regexp(listing(k).name, '^Trk_Prn_\d{2}_final\.mat$', 'once'));
    end
    listing = listing(keep);

    N = length(listing);
    if N == 0
        filesName = {};
        Usable = false(0, 1);
        warning('checkTresInt:NoFiles', ...
            'No files matching "Trk_Prn_\\d{2}_final.mat" found in: %s', dirPath);
        return;
    end

    filesName = cell(N, 1);
    Usable = false(N, 1);
    for i = 1:N
        filesName{i} = listing(i).name;
        Usable(i) = checkMatFile(fullfile(dirPath, listing(i).name));
    end
end
