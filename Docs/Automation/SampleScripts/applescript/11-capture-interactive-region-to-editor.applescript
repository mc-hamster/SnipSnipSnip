-- Region and Window use the same fresh window bounds to identify the target under the pointer.
-- Drag a region, or click an outlined app window, dialog, or utility panel.
tell application id "com.oontz.SnipSnipSnip"
    capture region given interactive:true, output:"editor"
end tell
