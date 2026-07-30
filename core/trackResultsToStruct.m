function trk = trackResultsToStruct(trackResults)
%TRACKRESULTSTOSTRUCT Convert TrackResults2 array (or structs) for navigation.
%
% postNavigation and legacy helpers expect struct-array semantics
% (especially status character aggregation). TrackResults2 is a handle
% class; convert when needed while preserving field names.

    if isempty(trackResults)
        trk = trackResults;
        return;
    end

    if isstruct(trackResults)
        trk = trackResults;
        return;
    end

    if isa(trackResults, 'TrackResults2')
        n = numel(trackResults);
        trk = repmat(struct(), 1, n);
        for k = 1:n
            trk(k) = trackResults(k).toStruct();
            % Ensure status is char for postNavigation active-channel filter
            if isstring(trk(k).status)
                trk(k).status = char(trk(k).status);
            end
            if isempty(trk(k).status)
                trk(k).status = '-';
            end
        end
        return;
    end

    error('trackResultsToStruct:UnsupportedType', ...
        'Unsupported trackResults type: %s', class(trackResults));
end
