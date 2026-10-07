-- Repeating a selected app dialog or utility panel retains that window target.
tell application id "com.oontz.SnipSnipSnip"
    repeat last capture given output:"editor"
end tell
