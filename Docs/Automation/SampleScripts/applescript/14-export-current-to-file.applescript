set outputPath to ((path to desktop as text) & "current-screenshot.png")
set outputPOSIXPath to POSIX path of outputPath

tell application id "com.oontz.SnipSnipSnip"
    exportCurrentScreenshot given outputPath:outputPOSIXPath, format:"png", overwrite:true
end tell
