set outputPath to ((path to downloads folder as text) & "comparison.html")
set outputPOSIXPath to POSIX path of outputPath

tell application id "com.oontz.SnipSnipSnip"
    exportCurrentScreenshot given outputPath:outputPOSIXPath, format:"html", appearance:"styled", overwrite:true
end tell
