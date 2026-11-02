# artcraft OHOS launch verification (ASCII-only comments, PS 5.1 safe)
# Usage: powershell -File verify-launch.ps1
$ErrorActionPreference = 'Continue'
$bundle = 'com.egui.device_spike'
$hap = 'D:\xuqiu\craft\artcraft\crates\desktop\artcraft\gen\ohos\entry_desktop\build\default\outputs\default\entry_desktop-default-signed.hap'

Write-Host '=== 1. uninstall old ==='
hdc shell "bm uninstall -b $bundle" 2>&1 | Select-Object -First 2

Write-Host '=== 2. install new HAP ==='
hdc install $hap 2>&1 | Select-Object -First 3

Write-Host '=== 3. clear hilog buffer ==='
hdc shell "hilog -r" 2>&1 | Out-Null

Write-Host '=== 4. launch ==='
hdc shell "aa start -a EntryAbility -b $bundle" 2>&1 | Select-Object -First 3

Start-Sleep -Seconds 10

Write-Host '=== 5. liveness (pid) ==='
hdc shell "pidof $bundle" 2>&1
hdc shell "ps -ef | grep $bundle" 2>&1 | Select-String -NotMatch 'grep' | Select-Object -First 2

Write-Host '=== 6. startup hilog (Rust stdout + Tauri + crashes) ==='
hdc shell "hilog -x | grep -E 'RustStdoutStderr|NativeAbility|JSAPP' | tail -n 120" 2>&1

Write-Host '=== 7. crash check ==='
hdc shell "ls -t /data/log/faultlog/faultlogger/ 2>/dev/null | head -n 5" 2>&1

Write-Host '=== 8. screenshot ==='
hdc shell "snapshot_display -f /data/local/tmp/artcraft2.jpeg" 2>&1 | Select-Object -First 1
hdc file recv /data/local/tmp/artcraft2.jpeg D:\xuqiu\craft\artcraft\artcraft2.jpeg 2>&1 | Select-Object -First 1
Write-Host 'DONE'
