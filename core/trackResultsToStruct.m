function trk = trackResultsToStruct(trackResults)
%TRACKRESULTSTOSTRUCT Convert TrackResults2 array (or structs) for navigation.
%
% postNavigation expects a homogeneous struct array. TrackResults2 handle
% objects are converted field-by-field with field-set normalization so that
% empty slots and tracked slots can share one struct array.

    if isempty(trackResults)
        trk = trackResults;
        return;
    end

    if isstruct(trackResults)
        trk = trackResults;
        return;
    end

    if ~isa(trackResults, 'TrackResults2')
        error('trackResultsToStruct:UnsupportedType', ...
            'Unsupported trackResults type: %s', class(trackResults));
    end

    n = numel(trackResults);
    cells = cell(1, n);
    for k = 1:n
        cells{k} = trackResults(k).toStruct();
        % Normalize status to char for postNavigation filter
        if isfield(cells{k}, 'status')
            if isstring(cells{k}.status)
                cells{k}.status = char(cells{k}.status);
            end
            if isempty(cells{k}.status)
                cells{k}.status = '-';
            end
        else
            cells{k}.status = '-';
        end
        if ~isfield(cells{k}, 'PRN') || isempty(cells{k}.PRN)
            cells{k}.PRN = 0;
        end
    end

    % Union of all field names (stable order from first non-empty)
    allFields = fieldnames(cells{1});
    for k = 2:n
        fk = fieldnames(cells{k});
        for i = 1:numel(fk)
            if ~ismember(fk{i}, allFields)
                allFields{end+1} = fk{i}; %#ok<AGROW>
            end
        end
    end

    for k = 1:n
        for i = 1:numel(allFields)
            f = allFields{i};
            if ~isfield(cells{k}, f)
                cells{k}.(f) = [];
            end
        end
        cells{k} = orderfields(cells{k}, allFields);
    end

    trk = [cells{:}];
end
