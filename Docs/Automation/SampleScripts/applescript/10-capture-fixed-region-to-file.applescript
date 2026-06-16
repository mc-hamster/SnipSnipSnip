set outputPath to ((path to desktop as text) & "region.png")
set outputPOSIXPath to POSIX path of outputPath

tell application id "com.oontz.SnipSnipSnip"
    captureRegion given rect:"100,100,640,480", outputPath:outputPOSIXPath, format:"png", overwrite:true
end tell
