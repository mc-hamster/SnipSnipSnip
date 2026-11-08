set outputPath to ((path to downloads folder as text) & "comparison.html")
set outputPOSIXPath to POSIX path of outputPath

tell application id "com.oontz.SnipSnipSnip"
    export current screenshot given outputPath:outputPOSIXPath, format:"html", appearance:"app-default", overwrite:true
end tell
