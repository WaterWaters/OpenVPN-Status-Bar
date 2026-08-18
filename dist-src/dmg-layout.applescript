-- DMG 窗口布局脚本（由 build.sh 调用）
-- 用法: osascript dmg-layout.applescript <挂载点>
-- 每一步独立 try 容错：某项失败不阻断其余项，保证"背景图/图标位置"尽力生效。
on run argv
    set mountPoint to item 1 of argv
    set bgPath to mountPoint & "/.background/background.png"
    tell application "Finder"
        set dmgFolder to (POSIX file mountPoint as alias)
        open dmgFolder
        tell window 1
            try
                set current view to icon view
            end try
            try
                set toolbar visible to false
            end try
            try
                set statusbar visible to false
            end try
            try
                set the bounds to {400, 100, 1060, 500}
            end try

            -- 图标视图选项：大小 / 背景图（AppleScript 兼容写法）
            try
                set icon size of icon view options of window 1 to 96
            end try
            try
                set background picture of icon view options of window 1 to (POSIX file bgPath as alias)
            end try

            -- 图标位置
            try
                set position of item "VPNStatusBar.app" to {185, 175}
            end try
            try
                set position of item "Applications" to {475, 175}
            end try
        end tell
        try
            update without registering applications
            delay 2
        end try
        try
            close window 1
        end try
    end tell
    return "OK"
end run