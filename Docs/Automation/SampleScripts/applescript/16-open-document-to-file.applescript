set documentPath to POSIX path of ((path to downloads folder as text) & "example.sss")
set outputPath to ((path to downloads folder as text) & "opened-document.png")
set outputPOSIXPath to POSIX path of outputPath

tell application id "com.oontz.SnipSnipSnip"
    open snip document given path:documentPath, outputPath:outputPOSIXPath, format:"png", overwrite:true
end tell
