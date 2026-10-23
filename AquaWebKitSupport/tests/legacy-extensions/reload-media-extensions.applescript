tell application "Safari" to activate
tell application "System Events" to tell process "Safari"
 click menu item "Show Extension Builder" of menu "Develop" of menu bar 1
 delay 1
 repeat with extensionName in {"Media Player API Test"}
  set entries to groups of group 1 of UI element 1 of scroll area 1 of window "Extension Builder"
  set selectedEntry to false
  repeat with entry in entries
   if exists static text (extensionName as text) of entry then
    click static text (extensionName as text) of entry
    set selectedEntry to true
    exit repeat
   end if
  end repeat
  if not selectedEntry then error "Extension missing: " & extensionName
  delay 1
  set reloaded to false
  set controls to entire contents of group 2 of UI element 1 of scroll area 1 of window "Extension Builder"
  repeat with itemRef in controls
   if class of itemRef is button then
    if name of itemRef is "Reload" or name of itemRef is "Install" then
     click itemRef
     set reloaded to true
     exit repeat
    end if
   end if
  end repeat
  if not reloaded then error "Install/Reload button missing: " & extensionName
  delay 1
 end repeat
 click button 1 of window "Extension Builder"
end tell
