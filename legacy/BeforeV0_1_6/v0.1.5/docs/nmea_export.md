# NMEA 0183 export (GGA + GSV)

## Output

After PVT, `exportNmea` writes a text log (default `pvt.nmea`) with at least:

| Sentence | Content |
|----------|---------|
| **GGA** | UTC time, lat/lon, quality, nSat, HDOP, altitude (m), geoid sep |
| **GSV** | SVs in view: PRN, elev, az, SNR (C/N0 dB-Hz when track available) |

Talker default **`GB`** (BeiDou, NMEA 4.10). Alternatives: `BD`, `GN`.

Example:

```text
$GBGGA,095432.00,4018.3775,N,11644.7996,E,1,08,1.2,51.7,M,0.0,M,,*hh
$GBGSV,2,1,08,23,45,120,44,24,30,080,45,...*hh
$GBGSV,2,2,08,...*hh
```

## Settings (`initSettings`)

```matlab
settings.nmea.enable      = true;
settings.nmea.talkerId    = 'GB';
settings.nmea.bdtMinusUtc = 4;      % UTC field = BDT SOW − 4 s
settings.nmea.quality     = 1;      % autonomous GNSS fix
settings.nmea.geoidSepM   = 0;
settings.nmea.fileName    = 'pvt.nmea';
```

## API

```matlab
exportNmea(navSolutions, settings, 'trackResults', trackResults, 'outDir', outDir);
```

Called from `run_B2a` and `run_fullsky_pvt60` when `nmea.enable` is true.

## Files

| File | Role |
|------|------|
| `navigation/exportNmea.m` | Epoch loop, write file |
| `navigation/nmeaBuildGGA.m` | GGA builder |
| `navigation/nmeaBuildGSV.m` | GSV builder (≤4 SV/msg) |
| `navigation/nmeaChecksum.m` | XOR checksum |
| `navigation/nmeaFormatLatLon.m` | ddmm.mmmm / dddmm.mmmm |
| `navigation/nmeaFormatUtc.m` | SOW → hhmmss.ss |

## Notes

- Time source: `navSolutions.localTime` (BDT-scale SOW from SoftGNSS).
- Altitude: ellipsoidal height from `cart2geo` (geoid sep default 0).
- SNR: `trackResults.B2a_CNo` mapped by epoch ≈ ms index / `CNoInterval`.
- Jump-filtered display track is **not** applied to NMEA; NMEA uses raw nav epochs (invalid LLA → quality 0 GGA still emitted so timeline is continuous).
