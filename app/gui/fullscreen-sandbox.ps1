# fullscreen-sandbox.ps1 - toggles the Windows Sandbox window on this PC to full screen.
#
# Windows Sandbox is a remote-desktop client underneath, and Ctrl+Alt+Break toggles its full-screen
# mode (no title bar; the guest resizes to the whole monitor). This brings the window to the front
# and sends that key combination. Run it again, or press Ctrl+Alt+Break, to leave full screen.
#
#   powershell -NoProfile -File fullscreen-sandbox.ps1
if (-not ('SbxFs.U' -as [type])) {
    Add-Type -Namespace SbxFs -Name U -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int c);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, System.UIntPtr extra);
'@
}
$p = Get-Process WindowsSandboxRemoteSession -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $p) { Write-Error 'No Windows Sandbox window found'; exit 1 }
$h = $p.MainWindowHandle
if ([SbxFs.U]::IsIconic($h)) { [void][SbxFs.U]::ShowWindow($h, 9) }   # SW_RESTORE
[void][SbxFs.U]::SetForegroundWindow($h)
Start-Sleep -Milliseconds 400
# Ctrl+Alt+Break: VK_CONTROL 0x11, VK_MENU 0x12, VK_CANCEL 0x03 (Break, with the extended-key flag)
$up = 2; $ext = 1
[SbxFs.U]::keybd_event(0x11, 0x1D, 0, [UIntPtr]::Zero)
[SbxFs.U]::keybd_event(0x12, 0x38, 0, [UIntPtr]::Zero)
[SbxFs.U]::keybd_event(0x03, 0x46, $ext, [UIntPtr]::Zero)
[SbxFs.U]::keybd_event(0x03, 0x46, $ext -bor $up, [UIntPtr]::Zero)
[SbxFs.U]::keybd_event(0x12, 0x38, $up, [UIntPtr]::Zero)
[SbxFs.U]::keybd_event(0x11, 0x1D, $up, [UIntPtr]::Zero)
