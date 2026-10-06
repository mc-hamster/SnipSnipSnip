-- Select an app window, dialog, or utility panel; menus and system overlays are excluded.
tell application id "com.oontz.SnipSnipSnip"
    captureWindow given interactive:true, output:"clipboard"
end tell
