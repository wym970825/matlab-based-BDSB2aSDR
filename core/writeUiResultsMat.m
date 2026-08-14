function writeUiResultsMat(path, results)
%WRITEUIRESULTSMAT Save the bounded, cross-entry UI result wrapper.
%
% Full tracking arrays belong in run_B2a_<tag>.mat and temp/.  The UI
% wrapper is intentionally navigation-focused so downstream positioning
% tools can load it without serializing gigabytes of tracking data.

    if ~(ischar(path) || (isstring(path) && isscalar(path)))
        error('writeUiResultsMat:BadPath', 'path must be a text scalar.');
    end
    if ~isstruct(results) || ~isscalar(results)
        error('writeUiResultsMat:BadResults', ...
            'results must be a scalar result struct.');
    end

    ui = results;
    if isfield(ui, 'trackResults')
        ui.trackResults = [];
    end
    % Acquisition diagnostics are small enough to remain useful for the UI
    % and replayAcquisitionChannels; tracking data is the only unbounded part.
    results = ui; %#ok<NASGU>
    if isfield(ui, 'settings'), settings = ui.settings; else, settings = struct(); end %#ok<NASGU>
    if isfield(ui, 'navSolutions'), navSolutions = ui.navSolutions; else, navSolutions = []; end %#ok<NASGU>
    if isfield(ui, 'eph'), eph = ui.eph; else, eph = []; end %#ok<NASGU>

    save(char(path), 'results', 'settings', 'navSolutions', 'eph', '-v7.3');
end
