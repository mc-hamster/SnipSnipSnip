set insertionItemID to "00000000-0000-0000-0000-000000000001"

tell application id "com.oontz.SnipSnipSnip"
    capture fullscreen given destination:"append", afterItemID:insertionItemID, appearance:"plain", output:"editor"
end tell
