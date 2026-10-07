"""Validate the local submission files without contacting App Store Connect."""
import hashlib
import json
from pathlib import Path
import struct
import subprocess

root = Path(__file__).resolve().parent
metadata = root / 'metadata/en-US'
limits = {'name': 30, 'subtitle': 30, 'promotional_text': 170,
          'description': 4000, 'release_notes': 4000}
report = {'version': '1.2.0', 'locale': 'en-US', 'metadata': {}, 'screenshots': []}
for field, limit in limits.items():
    value = (metadata / f'{field}.txt').read_text().rstrip('\n')
    assert 0 < len(value) <= limit, (field, len(value), limit)
    report['metadata'][field] = {'characters': len(value), 'limit': limit}
keywords = (metadata / 'keywords.txt').read_text().strip()
assert 0 < len(keywords.encode('utf-8')) <= 100
assert all(len(word) > 2 for word in keywords.split(','))
report['metadata']['keywords'] = {'bytes': len(keywords.encode()), 'limit': 100}
for field in ['support_url', 'marketing_url', 'privacy_url']:
    assert (metadata / f'{field}.txt').read_text().strip().startswith('https://')
slides = json.loads((root / 'slides.json').read_text())
assert 1 <= len(slides) <= 10
screenshots = sorted((root / 'screenshots/en-US').glob('*.png'))
assert len(screenshots) == len(slides)
for slide, file in zip(slides, screenshots):
    assert file.name == f'SnipSnipSnip-1.2.0-{slide["number"]}.png'
    assert (root / 'captures' / slide['source']).is_file()
    data = file.read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    width, height, depth, color = struct.unpack('>IIBB', data[16:26])
    assert (width, height, depth, color) == (1440, 900, 8, 2), file
    report['screenshots'].append({'file': str(file.relative_to(root)),
        'width': width, 'height': height, 'mode': 'RGB, no alpha',
        'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
report['previews'] = []
for file in sorted((root / 'previews/en-US').glob('*.mp4')):
    probe = json.loads(subprocess.check_output(['ffprobe', '-v', 'error',
        '-show_streams', '-show_format', '-of', 'json', str(file)]))
    video = next(s for s in probe['streams'] if s['codec_type'] == 'video')
    duration = float(probe['format']['duration'])
    assert (video['width'], video['height']) == (1920, 1080)
    assert video['codec_name'] == 'h264'
    assert video['pix_fmt'] == 'yuv420p'
    assert video['level'] <= 40
    assert video['field_order'] == 'progressive'
    num, den = map(int, video['avg_frame_rate'].split('/'))
    assert num / den <= 30
    assert 15 <= duration <= 30
    assert file.stat().st_size < 500_000_000
    audio = next(s for s in probe['streams'] if s['codec_type'] == 'audio')
    assert audio['codec_name'] == 'aac' and audio['channels'] == 2
    assert audio['sample_rate'] in ['44100', '48000']
    report['previews'].append({'file': str(file.relative_to(root)),
        'width': video['width'], 'height': video['height'], 'duration': duration,
        'fps': num / den, 'codec': video['codec_name'], 'bytes': file.stat().st_size,
        'sha256': hashlib.sha256(file.read_bytes()).hexdigest()})
(root / 'validation.json').write_text(json.dumps(report, indent=2) + '\n')
print(f'PASS: {len(screenshots)} opaque RGB screenshots, {len(report["previews"])} previews, metadata within limits.')
