set outputPath to ((path to downloads folder as text) & "private-capture.png")
set outputPOSIXPath to POSIX path of outputPath

tell application id "com.oontz.SnipSnipSnip"
    captureFullscreen given display:"current", privateCapture:true, outputPath:outputPOSIXPath, format:"png", overwrite:true
end tell
