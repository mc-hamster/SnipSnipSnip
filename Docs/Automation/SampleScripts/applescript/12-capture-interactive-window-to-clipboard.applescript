-- Region and Window use the same fresh window bounds to identify the target under the pointer.
-- Select an app window, dialog, or utility panel; menus and system overlays are excluded.
tell application id "com.oontz.SnipSnipSnip"
    capture window given interactive:true, output:"clipboard"
end tell
