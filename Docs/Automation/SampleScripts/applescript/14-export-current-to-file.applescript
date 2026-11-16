set outputPath to ((path to downloads folder as text) & "current-screenshot.png")
set outputPOSIXPath to POSIX path of outputPath

tell application id "com.oontz.SnipSnipSnip"
    export current screenshot given outputPath:outputPOSIXPath, format:"png", overwrite:true
end tell
