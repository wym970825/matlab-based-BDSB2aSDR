# One-shot extractor: tracking2 channel body -> trackOneChannel.m
from pathlib import Path

root = Path(__file__).resolve().parents[1]
src_path = root / "tracking" / "tracking2_v6_fix2.m"
src = src_path.read_text(encoding="utf-8", errors="replace").splitlines(True)

# Lines 96-919 (1-based): body inside `if Ch(c_i).PRN ~= 0` through collect print
# Line 96 is trkBuf; 921 is `end % if`
body = src[95:920]  # 0-based inclusive of line 920 (print)


def dedent_block(lines, n=4):
    out = []
    for ln in lines:
        if ln.startswith(" " * n):
            out.append(ln[n:])
        else:
            out.append(ln)
    return out


body = dedent_block(body, 4)
text = "".join(body)
text = text.replace("Ch(c_i)", "ch")

# BCNAV2 decode block (flexible)
import re

text = re.sub(
    r"\[eph\(finalTRes\.PRN\),\s*subFrameStart\(c_i\),\s*TOW\(c_i\)\]\s*=\s*\.\.\.\s*"
    r"\n\s*BCNAV2decoding\(finalTRes\.I_P\);\s*%#ok<AGROW>",
    "[ephPrn, subFrameStart, towVal] = BCNAV2decoding(finalTRes.I_P);",
    text,
)
text = text.replace("subFrameStart(c_i)", "subFrameStart")
text = text.replace("TOW(c_i)", "towVal")
text = text.replace("eph(finalTRes.PRN)", "ephPrn")

text = text.replace(
    "warning('Not able to read the specified number of samples for tracking, exiting!')\n"
    "                fclose(fid);\n"
    "                return\n",
    "warning('Not able to read the specified number of samples for tracking, exiting channel early!')\n"
    "                break\n",
)
# after dedent, indent is 4 spaces less for that block
text = text.replace(
    "warning('Not able to read the specified number of samples for tracking, exiting!')\n"
    "            fclose(fid);\n"
    "            return\n",
    "warning('Not able to read the specified number of samples for tracking, exiting channel early!')\n"
    "            break\n",
)

old_seek = (
    "    % Move the starting point of processing. Can be used to start the\n"
    "    % signal processing at any point in the data record (e.g. for long\n"
    "    % records). In addition skip through that data file to start at the\n"
    "    % appropriate sample (corresponding to code phase).\n"
    "    fseek(fid, ...\n"
    "        (settings.skipNumberOfBytes + settings.size_per_sample*(ch.codePhase-1)), ...\n"
    "        'bof');\n"
    "    ftell(fid);\n"
)
new_seek = (
    "    % Seek to this channel code-phase start (private file handle)\n"
    "    seekBytes = settings.skipNumberOfBytes + "
    "settings.size_per_sample * (ch.codePhase - 1);\n"
    "    if fseek(fid, seekBytes, 'bof') ~= 0\n"
    "        error('trackOneChannel:SeekFailed', "
    "'fseek failed for PRN %d codePhase=%g', ch.PRN, ch.codePhase);\n"
    "    end\n"
)
if old_seek not in text:
    print("SEEK BLOCK NOT FOUND")
    idx = text.find("fseek(fid")
    print(repr(text[max(0, idx - 120) : idx + 220]))
else:
    text = text.replace(old_seek, new_seek, 1)

# Drop trailing "end % if a PRN" if present and Tres assign
text = text.replace(
    "        % Collect into return array (channel index aligned with Ch / preRun2)\n"
    "        % This restores the trackResults -> postNavigation pipeline.\n"
    "        Tres(c_i) = finalTRes;\n"
    "        fprintf('Channel %d PRN %02d tracking results collected into Tres(%d).\\n', ...\n"
    "            c_i, ch.PRN, c_i);\n"
    "\n"
    "    end % if a PRN is assigned\n",
    "    fprintf('Channel %d PRN %02d tracking results collected.\\n', c_i, ch.PRN);\n",
)
text = text.replace(
    "    % Collect into return array (channel index aligned with Ch / preRun2)\n"
    "    % This restores the trackResults -> postNavigation pipeline.\n"
    "    Tres(c_i) = finalTRes;\n"
    "    fprintf('Channel %d PRN %02d tracking results collected into Tres(%d).\\n', ...\n"
    "        c_i, ch.PRN, c_i);\n"
    "\n",
    "    fprintf('Channel %d PRN %02d tracking results collected.\\n', c_i, ch.PRN);\n"
    "\n",
)
text = text.replace("end % for channelNr\n", "")
text = text.replace("    end % if a PRN is assigned\n", "")

# If early break before finalTRes created, ensure variable exists at end
# Insert after trkBuf PRN assign a placeholder? Better ensure final merge always runs
# after loopCnt - if break early, still partsave/merge. Good.

header = r'''function [finalTRes, ch] = trackOneChannel(ch, settings, c_i, TrkedNr)
%TRACKONECHANNEL Single-channel B2a tracking (private IF file handle).
%
%   [finalTRes, ch] = trackOneChannel(ch, settings, c_i, TrkedNr)
%
% Designed for serial or parfor multi-SV scheduling. Each call opens its own
% IF file so workers do not share file identifiers.
%
% Inputs:
%   ch       - channel struct (PRN, codePhase, acquiredFreq, ...)
%   settings - receiver settings
%   c_i      - channel index (for status prints)
%   TrkedNr  - total tracked channel count (status print)
%
% Outputs:
%   finalTRes - TrackResults2 for this PRN
%   ch        - possibly updated channel (e.g. after REACQ)

    if nargin < 3 || isempty(c_i), c_i = 1; end
    if nargin < 4 || isempty(TrkedNr), TrkedNr = 1; end

    finalTRes = TrackResults2(settings, 0);
    if isempty(ch) || ~isfield(ch, 'PRN') || ch.PRN == 0
        return;
    end

    codePeriods = settings.msToProcess;
    if (settings.fileType == 1), dataAdaptCoeff = 1; else, dataAdaptCoeff = 2; end
    Nin1ms = settings.samplingFreq * 1e-3;

    useKF = false;
    if isfield(settings, 'KF') && isstruct(settings.KF) && isfield(settings.KF, 'enable')
        useKF = settings.KF.enable;
    end
    useFLL = false;
    if isfield(settings, 'FLL') && isstruct(settings.FLL) && isfield(settings.FLL, 'enable')
        useFLL = settings.FLL.enable;
    end
    useFLLfold = false;
    if isfield(settings, 'FLL') && isstruct(settings.FLL) && isfield(settings.FLL, 'useBpskFold')
        useFLLfold = settings.FLL.useBpskFold;
    end

    el_Spc = settings.dllCorrelatorSpacing;
    PDIcode = settings.intTime;
    [tau1code, tau2code] = calcLoopCoef(settings.dllNoiseBandwidth, ...
        settings.dllDampingRatio, 1.0);
    if ~isfield(settings, 'longCoh_ms'), settings.longCoh_ms = 20; end

    % --- private IF handle (parfor-safe) ---
    targetfile = fullfile(settings.filePath, settings.fileName);
    [fid, msg] = fopen(targetfile, 'rb');
    if fid <= 0
        error('trackOneChannel:OpenFailed', 'Unable to open %s: %s', targetfile, msg);
    end
    cleaner = onCleanup(@() local_fclose(fid)); %#ok<NASGU>

'''

footer = r'''
end % trackOneChannel

function local_fclose(fid)
    if ~isempty(fid) && fid > 0
        try, fclose(fid); catch, end %#ok<CTCH>
    end
end

function e = costasPhaseErrCycles(P)
if isempty(P) || ~isfinite(real(P)) || ~isfinite(imag(P)) || (real(P)==0 && imag(P)==0)
    e = 0;
    return;
end
e = atan2(imag(P), real(P)) / (2*pi);
if e > 0.25
    e = e - 0.5;
elseif e < -0.25
    e = e + 0.5;
end
end

function [b, a] = designFLL2ndLPF(fc_Hz, zeta, fs_Hz)
if nargin < 2 || isempty(zeta), zeta = 0.707; end
fc_Hz = max(fc_Hz, 0.01);
zeta  = max(zeta, 0.05);
T  = 1/fs_Hz;
wn = 2*pi*fc_Hz;
K  = 2/T;
A0 = K^2 + 2*zeta*wn*K + wn^2;
A1 = 2*(wn^2 - K^2);
A2 = K^2 - 2*zeta*wn*K + wn^2;
b = [wn^2, 2*wn^2, wn^2] / A0;
a = [1, A1/A0, A2/A0];
end
'''

out_path = root / "tracking" / "trackOneChannel.m"
out_path.write_text(header + text + footer, encoding="utf-8")
print("Wrote", out_path)
out = out_path.read_text(encoding="utf-8")
checks = [
    "Ch(c_i)",
    "Tres(",
    "subFrameStart(c_i)",
    "fclose(fid);",
    "function [finalTRes, ch]",
    "seekBytes",
    "costasPhaseErrCycles",
]
for s in checks:
    print(f"  {s!r}: {s in out}")
print("lines", len(out.splitlines()))
