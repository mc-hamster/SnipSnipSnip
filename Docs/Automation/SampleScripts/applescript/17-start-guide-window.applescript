-- Guide automation is Pro-only; App Store requests return proFeatureRequired.
-- Guide needs Screen Recording and Accessibility; narration also needs Microphone.
-- Set up access in the app first. Unattended requests fail without showing permission UI.
tell application id "com.oontz.SnipSnipSnip"
    guide given action:"start", target:"window"
end tell
