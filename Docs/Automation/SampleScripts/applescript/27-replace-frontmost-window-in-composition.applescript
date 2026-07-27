set itemID to "00000000-0000-0000-0000-000000000001"

tell application id "com.oontz.SnipSnipSnip"
    captureFrontmostWindow given destination:"replace", replaceItemID:itemID, output:"editor"
end tell
