# NMEA 0183 export and navigation replay

## Sentences

`exportNmea` writes the following sentences after PVT:

| Sentence | Content |
|----------|---------|
| **GGA** | UTC time, position, fix quality, RAIM-used SV count, HDOP, height |
| **GSA** | fix type, satellites actually used by LS/RAIM, PDOP/HDOP/VDOP |
| **GSV** | satellites in view, elevation, azimuth, optional tracking C/N0 |
| **ZDA** | UTC time and absolute date from week number plus week epoch |

The functions in `navigation/nmeaBuild*.m`, `nmeaChecksum.m`, and the NMEA
formatters do not contain BeiDou PRN mappings or time-system constants.
Constellation-specific choices are supplied by `settings.nmea`.

```matlab
settings.nmea.enable = true;
settings.nmea.talkerId = 'GB';
settings.nmea.utcOffsetSeconds = 4;
settings.nmea.weekEpoch = '2006-01-01';
settings.nmea.weekNumber = [];       % decoded eph.WN is preferred
settings.nmea.systemId = 4;          % optional NMEA 4.x GNSS system ID
settings.nmea.quality = 1;
settings.nmea.geoidSepM = 0;
settings.nmea.fileName = 'pvt.nmea';
settings.nmea.emitGGA = true;
settings.nmea.emitGSA = true;
settings.nmea.emitGSV = true;
settings.nmea.emitZDA = true;
```

Old configurations containing `nmea.bdtMinusUtc` remain supported as an
alias of `utcOffsetSeconds`. ZDA is omitted when no trustworthy absolute
date or valid position fix is available; GGA/GSA still record invalid-fix
epochs so receiver status remains continuous.

```matlab
exportNmea(navSolutions, settings, ...
    'trackResults', trackResults, 'eph', eph, 'outDir', outDir);
```

## Navigation replay

Use saved `Trk_Prn_*_final.mat` files to re-run navigation and replace a
run's `pvt.nmea` without acquisition or tracking:

```matlab
report = runNavigationFromTracking('results/batch/<batch>/<run>');
```

The input can also be the run's `temp` directory. Settings are restored from
`ui_results.mat`; when that is unavailable, `ui_config.json` is used. An
explicit JSON or settings struct can override the saved settings:

```matlab
report = runNavigationFromTracking(runDir, 'Config', 'updated_config.json');
```

The new NMEA log is generated at a temporary path and replaces the target
only after export succeeds. Refreshed navigation state is saved separately
as `navigation_replay.mat`; the original `ui_results.mat` is not rewritten.

`tests/resume_pvt_from_track.m` predates this entry and remains a manually
configured PVT smoke/recovery helper. It is not the normal replay API.
