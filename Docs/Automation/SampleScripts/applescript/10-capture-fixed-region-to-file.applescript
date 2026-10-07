set outputPath to ((path to downloads folder as text) & "region.png")
set outputPOSIXPath to POSIX path of outputPath

tell application id "com.oontz.SnipSnipSnip"
    capture region given rect:"100,100,640,480", outputPath:outputPOSIXPath, format:"png", overwrite:true
end tell
