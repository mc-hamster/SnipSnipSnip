-- Repeating a selected app dialog or utility panel retains that window target.
tell application id "com.oontz.SnipSnipSnip"
    repeatLastCapture given output:"editor"
end tell
