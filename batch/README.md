# Directory batch processing

The function batchDirForOneSettings applies one receiver configuration to
every matching binary file in a directory. It accepts either a settings
struct returned by initSettings or a Web UI / JSON config file.

    cd('F:\matlab-GNSSsdr\BDS\B2a')
    setupPaths

    report = batchDirForOneSettings( ...
        'F:\Data\ExpKLHP\X310_IFData', ...
        'results\ui\260802_023720_944b90\ui_config.json');

Using a MATLAB settings struct:

    settings = initSettings('msToProcess', 60000, ...
        'acqSatelliteList', 1:60);
    report = batchDirForOneSettings( ...
        'F:\Data\ExpKLHP\X310_IFData', settings);

The default search is non-recursive *.bin. Useful options:

    report = batchDirForOneSettings(inputDir, settingsSource, ...
        'OutputRoot', 'F:\results\b2a_batch', ...
        'Recursive', false, ...
        'ContinueOnError', true, ...
        'OpenBaiduBrowser', false);

Each input gets a numbered output directory with an independent config,
temp directory, result MAT files, figures, NMEA, and report.json. The batch
root contains batch_report.json and batch_report.mat, updated after every
file so completed progress remains visible after a later failure.

MATLAB identifiers cannot contain a hyphen, so the callable function uses
the valid name batchDirForOneSettings and the executable script uses
batch_dir_ForOneSettings.m. The exact requested name
batch-dir-ForOneSettings.m is retained for discoverability, but MATLAB
cannot invoke a hyphenated script with run. Define inputDir,
settingsSource, and optional batchOptions before running the underscore
script.
