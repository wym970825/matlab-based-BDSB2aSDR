from pathlib import Path
import hashlib
import shutil

here = Path(__file__).resolve().parent
root = Path('F:/matlab-GNSSsdr/BDS/S4repair_basedOnSDR-v2')
out = root / 'results/data1020_pb_02_04_05_s4'
out.mkdir(exist_ok=True)
files = sorted((root / '+s4repair').rglob('*.m')) + sorted(root.glob('*.m'))
files += [root / 'resources/rffe/X310_GNSS_L5_RFFE_HRF.mat']
rows = [(str(p.relative_to(root)).replace('\\', '/'), hashlib.sha256(p.read_bytes()).hexdigest()) for p in files]
text = '# 原计算源码与前端资源 SHA-256\n\n| 文件 | SHA-256 |\n| --- | --- |\n'
text += ''.join(f'| {p} | {h} |\n' for p, h in rows)
snapshot = out / 'source_sha256.md'
if snapshot.exists():
    print('Source snapshot unchanged:', snapshot.read_text(encoding='utf-8') == text)
else:
    snapshot.write_text(text, encoding='utf-8')
code = out / 'programs'
code.mkdir(exist_ok=True)
for p in here.iterdir():
    if p.suffix in ('.m', '.ps1', '.py', '.md'):
        shutil.copy2(p, code / p.name)
shutil.copy2(here / 'RUN.md', out / 'RUN.md')
print('Source files recorded:', len(rows))
