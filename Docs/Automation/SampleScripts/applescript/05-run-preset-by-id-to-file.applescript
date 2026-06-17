set outputPath to ((path to desktop as text) & "preset-capture.png")
set outputPOSIXPath to POSIX path of outputPath

tell application id "com.oontz.SnipSnipSnip"
    runCapturePreset given id:"00000000-0000-0000-0000-000000000000", outputPath:outputPOSIXPath, format:"png", overwrite:true
end tell
