"""Prepare isolated candidate fixes; never edit the running receiver."""
from pathlib import Path
import hashlib
import json
import shutil

root = Path(__file__).resolve().parents[2]
dest = root / 'results/semiphysical_recompute/20260930_restart_isolated/candidate_code'
dest.mkdir(parents=True, exist_ok=True)
# Preserve the class's private-function resolution when testing a copy.
(dest / 'private').mkdir(exist_ok=True)
for helper in (root / 'channelCtrl/private').glob('*.m'):
    shutil.copy2(helper, dest / 'private' / helper.name)
patches = {}

source = root / 'include/Calc_CNo_PLD.m'
code = source.read_text('utf-8')
start = code.index('Zm = mean(Z);')
end = code.index('CNo(1) =', start)
code = code[:start] + 'DataCNo = localCarrierToNoise(Z, T);\n' + code[end:]
start = code.index('    Zm = mean(Z);')
end = code.index('    CNo(2) =', start)
code = code[:start] + '    PilotCNo = localCarrierToNoise(Z, T);\n' + code[end:]
code += '''
end

function cn0 = localCarrierToNoise(power, integrationSec)
% Real, nonnegative VSM estimate. Negative moments carry no signal evidence;
% taking abs of a complex estimate invents a positive carrier/noise ratio.
    cn0 = NaN;
    if isempty(power) || any(~isfinite(power)) || integrationSec <= 0
        return;
    end
    meanPower = mean(power);
    discriminant = meanPower^2 - var(power);
    if meanPower <= 0 || discriminant <= 0
        cn0 = 0;  % log10(0)=-Inf: an observed window with no carrier evidence.
        return;
    end
    carrierPower = sqrt(discriminant);
    noisePower = max(meanPower-carrierPower, 2*eps(meanPower));
    cn0 = carrierPower / noisePower / integrationSec;
end
'''
(dest / source.name).write_text(code, encoding='utf-8')
patches['include/Calc_CNo_PLD.m'] = source.name

source = root / 'common/leastSquarePos.m'
code = source.read_text('utf-8')
old = '''    dop(3)  = sqrt(Q(1,1) + Q(2,2));
    dop(4)  = sqrt(Q(3,3));'''
new = '''    % Horizontal/vertical axes are local ENU, not ECEF X/Y/Z.
    [lat, lon, ~] = cart2geo(pos(1), pos(2), pos(3), 5);
    Renu = [-sind(lon), cosd(lon), 0; ...
        -sind(lat)*cosd(lon), -sind(lat)*sind(lon), cosd(lat); ...
        cosd(lat)*cosd(lon), cosd(lat)*sind(lon), sind(lat)];
    Qenu = Renu * Q(1:3,1:3) * Renu.';
    dop(3)  = sqrt(max(0, Qenu(1,1) + Qenu(2,2)));
    dop(4)  = sqrt(max(0, Qenu(3,3)));'''
assert old in code
code = code.replace(old, new)
(dest / source.name).write_text(code, encoding='utf-8')
patches['common/leastSquarePos.m'] = source.name

source = root / 'tracking/trackOneChannel.m'
code = source.read_text('utf-8')
old = '''        if all(isfinite(tempCNoValue)) && numel(tempCNoValue) >= 3 && (tempCNoValue(3) > 0)
            cnoDrive = [tempCNoValue(3), tempCNoValue(3)];
        end'''
new = '''        if numel(tempCNoValue) >= 3
            if isfinite(tempCNoValue(3)) && tempCNoValue(3) > 0
                cnoDrive = [tempCNoValue(3), tempCNoValue(3)];
            elseif mod(loopCnt, settings.CNoInterval) == 0
                % A completed unusable/zero-power window is evidence of lost
                % signal. -1 remains reserved for no observation yet.
                cnoDrive = [0, 0];
            end
        end'''
assert old in code
code = code.replace(old, new)
(old, new) = ('''            S4 = sqrt(max(0,S4result.S4_ori.^2 - S4result.S4_corr.^2));''',
'''            if latestScintResValid && isfinite(S4result.S4_ori) && isfinite(S4result.S4_corr)
                S4 = sqrt(max(0,S4result.S4_ori.^2 - S4result.S4_corr.^2));
            else
                S4 = NaN; % max(0,NaN) must not turn unavailable data into zero S4.
            end''')
assert old in code
code = code.replace(old,new)
(dest / source.name).write_text(code, encoding='utf-8')
patches['tracking/trackOneChannel.m'] = source.name

source = root / 'channelCtrl/NH_stateMachine.m'
code = source.read_text('utf-8')
old = '~all(isfinite(obj.LastCN0)) || ~all(obj.LastCN0 > 0)'
assert old in code
code = code.replace(old, '~all(isfinite(obj.LastCN0)) || ~all(obj.LastCN0 >= 0)')
(dest / source.name).write_text(code, encoding='utf-8')
patches['channelCtrl/NH_stateMachine.m'] = source.name

source = root / 'channelCtrl/scint_calculator.m'
code = source.read_text('utf-8')
code = code.replace('A   = sqrt(Ip*Ip + Qp*Qp);',
                    'A   = Ip*Ip + Qp*Qp; % intensity (power), not voltage amplitude')
needle = '        tickSinceUpdate double  = 0'
assert needle in code
code = code.replace(needle,
                    '        processedTicks double = 0\n        warmupMs double = 150000\n' + needle)
needle = '            obj.SI_buf    = nan(obj.bufLen, 1);'
assert needle in code
code = code.replace(needle, '''            if isfield(settings,'KF') && isfield(settings.KF,'scintWarmup_ms')
                obj.warmupMs = max(0, settings.KF.scintWarmup_ms);
            end
''' + needle, 1)
code = code.replace('            obj.tickSinceUpdate = obj.tickSinceUpdate + 1;',
                    '            obj.processedTicks = obj.processedTicks + 1;\n            obj.tickSinceUpdate = obj.tickSinceUpdate + 1;')
# Reset uses aligned spacing distinct from tickUpdate's assignment.
needle = '            obj.result          = scint_calculator.emptyResult();'
assert needle in code
code = code.replace(needle, '            obj.processedTicks = 0;\n' + needle)
needle = '            if obj.ptr < 200, return; end   % need at least 200 samples'
assert needle in code
code = code.replace(needle, '''            % Require a full window and exclude filter startup after reset.
            if obj.ptr < obj.bufLen || obj.processedTicks < obj.warmupMs*obj.fs/1000
                obj.result = scint_calculator.emptyResult();
                obj.newResultFlag = true;
                return;
            end''')
old = '''            S4corrsq = (100 / max(CN0_lin, 1e-6)) * ...
                       (1 + 500 / max(19 * CN0_lin, 1e-6));'''
new = '''            % Native-rate, complex white-Gaussian approximation:
            % Var(|s+n|^2)/|s|^4 = 2/rho + 1/rho^2, rho=(C/N0)*T.
            % Downsampled samples average M POWERS noncoherently, so their
            % independent thermal variance scales by 1/M, not T -> M*T.
            % DME/PB noise is not guaranteed Gaussian; retain raw S4 too.
            rho = max(CN0_lin / obj.fs, 1e-12);
            S4corrsq = (2/rho + 1/rho^2) / max(obj.longCoh_ms,1);'''
assert old in code
code = code.replace(old,new)
code = code.replace('l0   = max(crossIdx - 2, 1);','l0   = max(crossIdx - 2, 0);')
code = code.replace('            dt = 1e-3;','            dt = 1/obj.fs;')
code = code.replace('                dt = obj.longCoh_ms * 1e-3;',
                    '                dt = obj.longCoh_ms / obj.fs;')
code = code.replace('Normalised amplitude: SI = A / A_trend',
                    'Normalised intensity: SI = power / lowpass(power)')
code = code.replace('Amplitude low-pass (extract trend)', 'Intensity low-pass (extract trend)')
code = code.replace('raw amplitude scintillation index', 'raw intensity scintillation index')
code = code.replace('%   S4_corr = sqrt( (100/CN0) * (1 + 500/(19*CN0)) )',
                    '%   S4_corr = sqrt((2/rho + 1/rho^2)/M), rho=CN0/fs, M=longCoh_ms')
code = code.replace('% S4_corr = sqrt( (100/CN0) * (1 + 500/(19*CN0)) )',
                    '% S4_corr = sqrt((2/rho + 1/rho^2)/M); native coherent T=1/fs')
code = code.replace('S4 thermal-noise correction (Conker et al. 2003)',
                    'Native-rate white-Gaussian S4 thermal-noise approximation')
code = code.replace('S4_corr  — thermal-noise correction term (Conker et al. 2003)',
                    'S4_corr  — native-rate white-Gaussian thermal approximation')
code = code.replace('S4_corr  (Conker et al. 2003 thermal-noise term)',
                    'S4_corr  (native-rate white-Gaussian thermal-noise term)')
code = code.replace('normalised amplitude after de-trending', 'normalised intensity after de-trending')
code = code.replace('pilot prompt correlator outputs', 'pilot prompt correlator outputs (converted to intensity)')
(dest / source.name).write_text(code, encoding='utf-8')
patches['channelCtrl/scint_calculator.m'] = source.name

source = root / 'channelCtrl/TrackResults2.m'
code = source.read_text('utf-8')
old = '                sigmaPLL(k) = (180/pi) * sqrt( (B_l_pll ./ CN0_lin) .* (1 + 1 ./ (2 .* T_coh .* CN0_lin)) );'
new = '''                % The carrier discriminator tracks the pilot branch.
                % Summing pilot+data C/N0 overstates its available signal power.
                if isfield(settings,'pilotTRKflag') && settings.pilotTRKflag == 1
                    branchCno = obj.PilotCNo(k);
                else
                    branchCno = obj.DataCNo(k);
                end
                if isfinite(branchCno) && branchCno > 0
                    pllCN0 = 10^(branchCno/10);
                    sigmaPLL(k) = (180/pi) * sqrt((B_l_pll/pllCN0) * ...
                        (1 + 1/(2*T_coh*pllCN0)));
                end'''
assert old in code
code = code.replace(old,new)
(dest / source.name).write_text(code, encoding='utf-8')
patches['channelCtrl/TrackResults2.m'] = source.name

record = {p: dict(candidate=str(dest / candidate),
                 originalSha256=hashlib.sha256((root / p).read_bytes()).hexdigest(),
                 candidateSha256=hashlib.sha256((dest / candidate).read_bytes()).hexdigest())
          for p, candidate in patches.items()}
(dest / 'manifest.json').write_text(json.dumps(record, indent=2), encoding='utf-8')
print(f'Prepared {len(record)} isolated candidates in {dest}')
