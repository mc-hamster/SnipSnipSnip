set documentPath to POSIX path of ((path to desktop as text) & "example.sss")
set outputPath to ((path to desktop as text) & "opened-document.png")
set outputPOSIXPath to POSIX path of outputPath

tell application id "com.oontz.SnipSnipSnip"
    openSnipDocument given path:documentPath, outputPath:outputPOSIXPath, format:"png", overwrite:true
end tell
