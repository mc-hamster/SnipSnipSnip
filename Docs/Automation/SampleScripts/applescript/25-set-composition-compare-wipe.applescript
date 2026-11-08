set beforeItemID to "00000000-0000-0000-0000-000000000001"
set afterItemIDValue to "00000000-0000-0000-0000-000000000002"

tell application id "com.oontz.SnipSnipSnip"
    set composition compare mode given mode:"wipe", firstItemID:beforeItemID, secondItemID:afterItemIDValue, wipePosition:0.4
end tell
