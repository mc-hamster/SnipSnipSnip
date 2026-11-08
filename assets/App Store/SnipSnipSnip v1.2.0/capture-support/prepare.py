"""Patch only a disposable git-archive snapshot for deterministic campaign capture.

Usage: python3 prepare.py /absolute/path/to/snapshot
The shipped UI, feature gates, single-instance coordinator and app identity stay intact.
"""
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
campaign = pathlib.Path(__file__).resolve().parents[1]
if (root / '.git').exists() or root == campaign.parents[2]:
    raise SystemExit('Refusing to patch a Git checkout; use a disposable git-archive snapshot.')
support = root / 'SnipSnipSnip/Support/CompositionUITestLaunchSupport.swift'
text = support.read_text()
if 'SNIP_CAMPAIGN_DEMO' in text:
    raise SystemExit('Snapshot is already prepared; start with a fresh archive.')
text = text.replace('1.1.3', '1.2.0').replace('\\"build\\":156', '\\"build\\":179')
text = text.replace('https://snipsnipsnip.com', 'https://www.oontz.com/apps/snipsnipsnip/')
text = text.replace('            clipboardHistoryStore: clipboardHistoryStore,',
    '            videoRecoveryStore: VideoRecoveryStore(rootURL: rootURL.appendingPathComponent("VideoRecovery")),\n            clipboardHistoryStore: clipboardHistoryStore,')
text = text.replace('let width = ordinal.isMultiple(of: 2) ? 960 : 720', 'let width = 1600')
text = text.replace('let height = ordinal.isMultiple(of: 2) ? 600 : 760', 'let height = 1000')
needle = '        model.documents.installEditorController('
annotation = '        if isCapturingAppStoreScreenshots {\n            var style = AnnotationStyle.default(for: .arrow)\n            style.lineWidth = 8\n            controller.addAnnotation(Annotation(id: UUID(), kind: .arrow(ArrowShape(\n                start: CGPoint(x: 1270, y: 560), end: CGPoint(x: 990, y: 710),\n                label: "Review the copy", labelFontSize: 26\n            )), style: style))\n        }\n'
assert text.count(needle) == 1
text = text.replace(needle, annotation + needle)

needle = '        let colorSpace = CGColorSpaceCreateDeviceRGB()'
replacement = '''        if ProcessInfo.processInfo.arguments.contains("--snipsnipsnip-app-store-screenshots"),
           let directory = ProcessInfo.processInfo.environment["SNIP_CAMPAIGN_DEMO"],
           let image = NSImage(contentsOfFile: directory + (ordinal == 0 ? "/orbit-before.png" : "/orbit-after.png"))?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return image
        }
''' + needle
assert text.count(needle) == 1
text = text.replace(needle, replacement)
needle = '            CommandMenu("UI Testing") {'
replacement = needle + '''
                Button("Load Campaign Video") {
                    if let directory = ProcessInfo.processInfo.environment["SNIP_CAMPAIGN_DEMO"] {
                        documents.installCapturedRecording(CapturedVideoRecording(
                            sourceURL: URL(fileURLWithPath: directory + "/orbit-demo.mp4"),
                            kind: .window, sourceName: "Orbit — Release walkthrough",
                            bounds: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                            recordedAt: Date(), duration: 12,
                            preferences: VideoRecordingPreferences()
                        ))
                    }
                }
                .keyboardShortcut("v", modifiers: [.command, .option, .control])
                Button("Style Campaign Screenshot") {
                    if let editor = documents.editorController,
                       let template = editor.presentationTemplates.first {
                        editor.applyPresentationTemplate(id: template.id)
                    }
                }
                .keyboardShortcut("p", modifiers: [.command, .option, .control])
'''
assert text.count(needle) == 1
support.write_text(text.replace(needle, replacement))
test = (campaign / 'capture-support/AppStoreScreenshotAssetUITests.swift').read_text()
test = test.replace('__CAMPAIGN_DEMO__', str(campaign / 'demo'))
(root / 'SnipSnipSnipUITests/AppStoreScreenshotAssetUITests.swift').write_text(test)
print(f'Prepared isolated capture source: {root}')
