set afterItemID to "00000000-0000-0000-0000-000000000001"

tell application id "com.oontz.SnipSnipSnip"
    captureFullscreen given destination:"append", afterItemID:afterItemID, appearance:"plain", output:"editor"
end tell
