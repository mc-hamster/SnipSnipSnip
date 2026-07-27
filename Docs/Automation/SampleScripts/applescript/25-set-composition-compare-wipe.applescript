set firstItemID to "00000000-0000-0000-0000-000000000001"
set secondItemID to "00000000-0000-0000-0000-000000000002"

tell application id "com.oontz.SnipSnipSnip"
    setCompositionCompareMode given mode:"wipe", firstItemID:firstItemID, secondItemID:secondItemID, wipePosition:0.4
end tell
