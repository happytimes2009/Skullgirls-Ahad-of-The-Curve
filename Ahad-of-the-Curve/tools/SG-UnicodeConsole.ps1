if (-not ([System.Management.Automation.PSTypeName]'SGConsoleNative').Type) {
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential)]
public struct SGConsoleCoord
{
    public short X;
    public short Y;
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct SGConsoleFontInfo
{
    public uint cbSize;
    public uint nFont;
    public SGConsoleCoord dwFontSize;
    public int FontFamily;
    public int FontWeight;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
    public string FaceName;
}

public static class SGConsoleNative
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int nStdHandle);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool GetCurrentConsoleFontEx(IntPtr hConsoleOutput, bool maximumWindow, ref SGConsoleFontInfo info);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool SetCurrentConsoleFontEx(IntPtr hConsoleOutput, bool maximumWindow, ref SGConsoleFontInfo info);

    [DllImport("kernel32.dll", EntryPoint = "WriteConsoleW", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool WriteConsoleW(IntPtr hConsoleOutput, string text, uint length, out uint written, IntPtr reserved);

    private static IntPtr OutputHandle()
    {
        return GetStdHandle(-11);
    }

    public static string FontName()
    {
        IntPtr handle = OutputHandle();
        if (handle == IntPtr.Zero || handle == new IntPtr(-1)) return "";
        SGConsoleFontInfo info = new SGConsoleFontInfo();
        info.cbSize = (uint)Marshal.SizeOf(typeof(SGConsoleFontInfo));
        if (!GetCurrentConsoleFontEx(handle, false, ref info)) return "";
        return info.FaceName == null ? "" : info.FaceName;
    }

    public static bool SetFont(string name)
    {
        IntPtr handle = OutputHandle();
        if (handle == IntPtr.Zero || handle == new IntPtr(-1)) return false;
        SGConsoleFontInfo info = new SGConsoleFontInfo();
        info.cbSize = (uint)Marshal.SizeOf(typeof(SGConsoleFontInfo));
        if (!GetCurrentConsoleFontEx(handle, false, ref info)) return false;
        info.FaceName = name;
        info.FontFamily = 54;
        info.FontWeight = 400;
        info.dwFontSize.X = 0;
        info.dwFontSize.Y = 16;
        if (!SetCurrentConsoleFontEx(handle, false, ref info)) return false;
        return string.Equals(FontName(), name, StringComparison.OrdinalIgnoreCase);
    }

    public static bool WriteUnicode(string text)
    {
        IntPtr handle = OutputHandle();
        if (handle == IntPtr.Zero || handle == new IntPtr(-1)) return false;
        uint written;
        return WriteConsoleW(handle, text, (uint)text.Length, out written, IntPtr.Zero)
            && written == (uint)text.Length;
    }
}
'@ -ErrorAction Stop
    } catch {
        Write-Warning 'Native Unicode console support could not be loaded; using normal console output.'
    }
}

function Initialize-SGUnicodeConsole {
    try {
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $global:OutputEncoding = [Console]::OutputEncoding
    } catch {
        Write-Warning 'Console UTF-8 configuration failed.'
    }

    if (-not ([System.Management.Automation.PSTypeName]'SGConsoleNative').Type) { return }

    try {
        $current = [SGConsoleNative]::FontName()
        if ($current -and $current -notmatch '^(Consolas|Lucida Console)$') {
            if (-not [SGConsoleNative]::SetFont('Consolas')) {
                [void][SGConsoleNative]::SetFont('Lucida Console')
            }
        }
    } catch {
        Write-Warning 'Could not select a Unicode console font. Windows Terminal may be required.'
    }
}
