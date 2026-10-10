#!/usr/bin/env python3
"""Exercise checked-in automation samples against the disposable Debug fixture.
Start one app with --snipsnipsnip-composition-ui-testing --snipsnipsnip-automation-audit.
This tool never launches/quits the app or runs against ordinary user documents.
"""
import argparse, json, os, pathlib, subprocess, time

ROOT = pathlib.Path(__file__).resolve().parents[1]
SAMPLES = ROOT / 'Docs/Automation/SampleScripts'

def run(argv, **kwargs):
    return subprocess.run(argv, capture_output=True, text=True, timeout=90, **kwargs)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--surface', choices=['cli', 'applescript', 'url'], default='cli')
    parser.add_argument('--matrix', action='store_true', help='Also exercise layouts, comparisons, templates, formats and failure boundaries.')
    args = parser.parse_args()
    discovery = run(['osascript', '-l', 'JavaScript', '-e', 'ObjC.import("AppKit"); JSON.stringify(ObjC.unwrap($.NSRunningApplication.runningApplicationsWithBundleIdentifier("com.oontz.SnipSnipSnip.Dev")).map(a => ({pid: Number(a.processIdentifier), path: ObjC.unwrap(a.bundleURL.path)})))'])
    if discovery.returncode != 0:
        parser.error('Could not identify the development audit app: ' + discovery.stderr)
    apps = json.loads(discovery.stdout)
    if len(apps) != 1:
        parser.error('Exactly one isolated audit app must already be running.')
    expected_cli = pathlib.Path(apps[0]['path']) / 'Contents/Library/Helpers/snipsnipsnipctl'
    if args.cli.resolve() != expected_cli.resolve():
        parser.error('The CLI must belong to the running disposable Dev app, not a shipping copy.')
    command = run(['ps', '-p', str(apps[0]['pid']), '-o', 'command=']).stdout
    if not all(flag in command for flag in ['--snipsnipsnip-composition-ui-testing', '--snipsnipsnip-automation-audit']):
        parser.error('Refusing to mutate an app outside the disposable automation fixture.')
    args.output.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, SSSCTL=str(args.cli), OUTPUT_DIR=str(args.output), SSS_URL_SCHEME="snipsnipsnip-dev")
    results = []
    def cli(*values):
        result = run([str(args.cli), '--json', *values])
        try: return json.loads(result.stdout)
        except ValueError: raise RuntimeError(result.stderr or result.stdout)
    def payload(result):
        return next(iter(result.get('payload', {}).values()), {}).get('_0', {})
    def select_ids():
        summary = payload(cli('composition', 'layout', '--layout', 'steps'))
        return summary.get('selectedItemID') or summary.get('itemID')
    def snapshot():
        target = args.output / 'url-state.sss'
        response = cli('export', 'current', '--output', str(target), '--format', 'sss', '--overwrite')
        deadline = time.monotonic() + 10
        while response.get('error', {}).get('code') == 'busy' and time.monotonic() < deadline:
            time.sleep(0.05)
            response = cli('export', 'current', '--output', str(target), '--format', 'sss', '--overwrite')
        if response.get('status') != 'succeeded':
            raise RuntimeError('Cannot inspect disposable URL state: ' + json.dumps(response))
        return json.loads((target / 'document.json').read_text())['session']['currentSnapshot']['composition']
    def clipboard_counter():
        return int(run(['osascript', '-l', 'JavaScript', '-e', 'ObjC.import("AppKit"); $.NSPasteboard.generalPasteboard.changeCount']).stdout.strip())
    presets = payload(cli('presets', 'list'))
    if presets:
        env['PRESET_ID'] = presets[0]['id']
        env['PRESET_NAME'] = presets[0]['name']
    env['SSS_DOCUMENT'] = str(args.output / 'example.sss')
    if args.surface == 'url': cli('capture', 'fullscreen', '--open-editor')
    for sample in sorted((SAMPLES / args.surface).glob('*')):
        number = int(sample.name[:2])
        # Picker completion requires a human/native-UI test; do not leave a
        # pending selection behind while subsequent samples run.
        if number in (11, 12):
            results.append(dict(sample=sample.name, status='manual-picker-required'))
            continue
        if number == 16:
            cli('capture', 'fullscreen', '--open-editor')
            prepared = cli('export', 'current', '--output', env['SSS_DOCUMENT'], '--format', 'sss', '--overwrite')
            if prepared.get('status') != 'succeeded':
                raise RuntimeError('Could not prepare open-document fixture: ' + json.dumps(prepared))
        if number == 23:
            env['AFTER_ITEM_ID'] = select_ids()
        if number == 25:
            env['FIRST_ITEM_ID'] = select_ids()
            appended = payload(cli('capture', 'fullscreen', '--destination', 'append', '--open-editor'))
            env['SECOND_ITEM_ID'] = appended.get('itemID') or appended.get('selectedItemID')
        if number == 27:
            env['ITEM_ID'] = select_ids()
        if args.surface == 'url':
            before = snapshot()
            before_clipboard = clipboard_counter()
            html_path = args.output / 'comparison.html'
            old_html_time = html_path.stat().st_mtime_ns if html_path.exists() else 0
            dispatched = run(['bash', str(sample)], env=env)
            def matches(current):
                ids_before = [item['id'] for item in before['items']]
                ids_after = [item['id'] for item in current['items']]
                if number in (4,6): return clipboard_counter() > before_clipboard
                if number in (3,8,9,13): return ids_before != ids_after and len(ids_after) == 1
                if number == 23: return len(ids_after) == len(ids_before) + 1
                if number == 24 or number == 28: return current['layout']['mode'] == 'steps'
                if number == 25: return current['layout']['mode'] == 'compare' and current['comparison']['mode'] == 'wipe'
                if number == 26: return html_path.exists() and html_path.stat().st_mtime_ns > old_html_time
                if number == 27:
                    old_asset = next(item['assetID'] for item in before['items'] if item['id'] == env['ITEM_ID'])
                    new_asset = next(item['assetID'] for item in current['items'] if item['id'] == env['ITEM_ID'])
                    return ids_before == ids_after and old_asset != new_asset
                return current == before
            deadline = time.monotonic() + 10
            observed = False
            while time.monotonic() < deadline:
                time.sleep(0.2)
                if matches(snapshot()): observed = True; break
            ok = dispatched.returncode == 0 and observed
            results.append(dict(sample=sample.name, passed=ok, dispatchExitCode=dispatched.returncode,
                validation='observed document/clipboard/file effects' if number not in (1,17,18,19,20,21,22) else 'dispatch and unchanged document; error contract covered by CLI/AppleScript'))
            print(('PASS ' if ok else 'FAIL ') + sample.name, flush=True)
            continue
        if args.surface == 'cli':
            result = run(['bash', str(sample)], env=env)
        else:
            source = sample.read_text().replace("com.oontz.SnipSnipSnip", "com.oontz.SnipSnipSnip.Dev")
            # Substitute fixture inputs only; execute the checked-in procedure.
            source = source.replace('path to downloads folder', 'POSIX file ' + json.dumps(str(args.output) + '/'))
            for variable in ['PRESET_ID', 'AFTER_ITEM_ID', 'FIRST_ITEM_ID', 'ITEM_ID']:
                if number == {'PRESET_ID':3, 'AFTER_ITEM_ID':23, 'FIRST_ITEM_ID':25, 'ITEM_ID':27}[variable]:
                    source = source.replace('00000000-0000-0000-0000-000000000001' if variable != 'PRESET_ID' else '00000000-0000-0000-0000-000000000000', env[variable])
            if number == 5: source = source.replace('00000000-0000-0000-0000-000000000000', env['PRESET_ID'])
            if number == 25: source = source.replace('00000000-0000-0000-0000-000000000002', env['SECOND_ITEM_ID'])
            fixture = args.output / sample.name
            fixture.write_text(source)
            result = run(['osascript', str(fixture)])
        try: envelope = dict(status='succeeded', outputs=[]) if number == 2 and args.surface == 'cli' and result.returncode == 0 and env['PRESET_ID'] in result.stdout else json.loads(result.stdout)
        except ValueError: envelope = dict(status='transportFailure', stderr=result.stderr)
        expected = 'proFeatureRequired' if 17 <= number <= 22 else None
        error = envelope.get('error', {}).get('code')
        ok = error == expected if expected else envelope.get('status') == 'succeeded'
        files = []
        for output in envelope.get('outputs', []):
            if output.get('url'):
                from urllib.parse import urlparse, unquote
                path = pathlib.Path(unquote(urlparse(output['url']).path))
                exists = path.exists()
                files.append(dict(path=str(path), exists=exists, bytes=path.stat().st_size if exists else 0))
                ok = ok and exists
        entry = dict(sample=sample.name, passed=ok, exitCode=result.returncode, result=envelope, files=files)
        results.append(entry)
        print(('PASS ' if ok else 'FAIL ') + sample.name + (' ' + str(error) if error else ''), flush=True)
    if args.matrix:
        def check(name, values, expected=None):
            response = cli(*values)
            error = response.get('error', {}).get('code')
            ok = error == expected if expected else response.get('status') == 'succeeded'
            results.append(dict(matrix=name, passed=ok, result=response))
            print(('PASS ' if ok else 'FAIL ') + name + (' ' + str(error) if error else ''), flush=True)
            return response
        check('matrix fresh capture', ['capture', 'fullscreen', '--open-editor'])
        check('matrix append', ['capture', 'fullscreen', '--destination', 'append', '--open-editor'])
        for layout in ['auto', 'compare', 'steps', 'row', 'column', 'grid', 'freeform']:
            for axis in ['horizontal', 'vertical']:
                check('layout ' + layout + '/' + axis, ['composition', 'layout', '--layout', layout, '--axis', axis])
        check('full steps options', ['composition', 'layout', '--layout', 'steps', '--grid-columns', '3', '--target-aspect-ratio', '1.5', '--step-numbering', 'lowercase-roman', '--step-start-index', '4', '--step-captions', 'false', '--step-connector', 'arrow'])
        check('freeform geometry', ['composition', 'layout', '--layout', 'freeform', '--freeform-width', '1200', '--freeform-height', '800'])
        for mode in ['side-by-side', 'overlay', 'wipe', 'blink', 'difference', 'change-highlight']:
            for axis in ['horizontal', 'vertical']:
                check('compare ' + mode + '/' + axis, ['composition', 'compare', '--mode', mode, '--axis', axis, '--primary-label', 'Before "quoted" & é', '--secondary-label', 'After \n newline', '--wipe-position', '0.4', '--overlay-opacity', '0.5', '--blink-interval', '0.1', '--difference-intensity', '0.7', '--highlight-color', '#FF336680', '--highlight-threshold', '0.2'])
        for template in ['builtin.clean-grid', 'builtin.side-by-side', 'builtin.numbered-steps', 'builtin.freeform-board']:
            check('template ' + template, ['composition', 'template', '--id', template])
        check('animation setup', ['composition', 'compare', '--mode', 'blink', '--blink-interval', '0.1'])
        for format in ['png', 'jpeg', 'pdf', 'sss', 'gif', 'apng', 'mp4', 'html']:
            path = args.output / ('matrix output & é.' + format)
            response = check('export ' + format, ['export', 'current', '--output', str(path), '--format', format.upper(), '--overwrite'])
            if response.get('status') == 'succeeded':
                ok = path.exists() and (path.is_dir() or path.stat().st_size > 0)
                results.append(dict(matrix='artifact ' + format, passed=ok))
                if format == 'html':
                    html = path.read_text()
                    results.append(dict(matrix='HTML embedded pixels', passed='data:image/png;base64,' in html))
        check('refuse overwrite', ['export', 'current', '--output', str(args.output / 'matrix output & é.png'), '--format', 'png'], 'outputFailed')
        check('private capture', ['capture', 'fullscreen', '--private', '--copy'])
        check('private editable guard', ['export', 'current', '--output', str(args.output / 'private.sss'), '--format', 'sss'], 'confirmationRequired')
        check('private repeat', ['repeat-last', '--private', '--copy'])
        check('float output', ['export', 'current', '--float'])
        for name, values in [
            ('unknown option', ['capture', 'fullscreen', '--typo']),
            ('conflicting output', ['capture', 'fullscreen', '--copy', '--open-editor']),
            ('duplicate option', ['capture', 'fullscreen', '--output', '/tmp/a', '--output', '/tmp/b']),
            ('missing value', ['capture', 'fullscreen', '--output']),
            ('malformed rect', ['capture', 'region', '--rect', '1,bad,2,3,4']),
            ('nonfinite', ['composition', 'compare', '--mode', 'wipe', '--wipe-position', 'nan']),
            ('out of range', ['composition', 'compare', '--mode', 'wipe', '--wipe-position', '2']),
            ('invalid integer', ['composition', 'layout', '--layout', 'grid', '--grid-columns', '9999999999999999999999999']),
            ('replace missing ID', ['capture', 'fullscreen', '--destination', 'replace']),
            ('wrong destination ID', ['capture', 'fullscreen', '--destination', 'new', '--after-item-id', '00000000-0000-0000-0000-000000000001']),
        ]: check(name, values, 'invalidRequest')
        check('unknown preset', ['presets', 'run', '--id', '00000000-0000-0000-0000-000000000000'], 'targetUnavailable')
        check('unknown template', ['composition', 'template', '--id', 'missing-template'], 'targetUnavailable')
        check('missing document', ['open', '--file', str(args.output / 'missing.sss')], 'targetUnavailable')
        check('App Store UI Map guard', ['capture', 'frontmost-window', '--ui-map', '--copy'], 'proFeatureRequired')
    report = args.output / ('samples-' + args.surface + '.json')
    report.write_text(json.dumps(results, indent=2))
    print(report)
    return int(any(r.get('passed') is False for r in results))

if __name__ == '__main__':
    raise SystemExit(main())
