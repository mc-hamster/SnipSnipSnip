-- Drag a region, or click an outlined app window, dialog, or utility panel.
tell application id "com.oontz.SnipSnipSnip"
    captureRegion given interactive:true, output:"editor"
end tell
