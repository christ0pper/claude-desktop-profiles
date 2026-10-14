// Claude Desktop Profiles - launcher.
// Unofficial community tool; not affiliated with or endorsed by Anthropic.
//
// Opens Claude Desktop with an isolated profile folder (Chromium's --user-data-dir), so each
// profile keeps its own login, chats and settings. The profile name comes from --profile=<name>
// or from this file's name: "Claude Work.exe" opens the "Work" profile.
//
// Compiled by install.ps1 with the C# 5 compiler that ships with Windows (.NET Framework 4.x),
// so keep this file free of newer C# syntax.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;

static class Launcher
{
    const string Title = "Claude Desktop Profiles";
    const string StoreFamily = "Claude_pzs8sxrjxfjjc";   // Microsoft Store package family (same on every PC)
    const string BackupName = "Claude.default-profile";   // must match scripts\Common.ps1
    const string NamePattern = @"^[A-Za-z0-9][A-Za-z0-9 _-]{0,39}$";

    static bool dryRun;

    [STAThread]
    static int Main(string[] args)
    {
        try { return Run(args); }
        catch (Exception ex) { return Fail("Unexpected error: " + ex.Message); }
    }

    static int Run(string[] args)
    {
        string profile = null;
        var passThrough = new List<string>();
        foreach (string a in args)
        {
            if (a == "--dry-run") dryRun = true;
            else if (a.StartsWith("--profile=", StringComparison.OrdinalIgnoreCase)) profile = a.Substring("--profile=".Length);
            else passThrough.Add(a);
        }
        if (profile == null)
        {
            Match m = Regex.Match(Path.GetFileNameWithoutExtension(Application.ExecutablePath), @"^Claude[ _-]+(.+)$", RegexOptions.IgnoreCase);
            if (m.Success) profile = m.Groups[1].Value;
        }
        if (!IsValidProfileName(profile))
            return Fail("Could not tell which profile to open.\nName this file \"Claude <Profile>.exe\" or pass --profile=<Profile>.");

        string root = Environment.GetEnvironmentVariable("CLAUDE_PROFILES_ROOT");
        if (string.IsNullOrEmpty(root))
            root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "ClaudeProfiles");
        string profileDir = Path.Combine(root, profile);
        if (!Directory.Exists(profileDir))
            return Fail("Profile '" + profile + "' does not exist:\n" + profileDir + "\n\nCreate it with:  install.ps1 -Name \"" + profile + "\"");

        string exe, dataRoot;
        FindClaude(out exe, out dataRoot);
        if (exe == null)
            return Fail("Claude Desktop was not found.\nInstall it from https://claude.ai/download, then try again.");

        // A sign-in (scripts\SignIn.ps1) temporarily parks the default profile. If that was interrupted, put it back first.
        if (Directory.Exists(Path.Combine(dataRoot, BackupName)))
        {
            int rc = RunHidden("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File " + Quote(Path.Combine(root, @"bin\Restore.ps1")));
            if (rc == 2)
                return Fail("A profile sign-in is still in progress (or was interrupted while Claude was open).\nQuit Claude from the system tray (right-click > Quit), then try again.");
            if (rc != 0)
                return Fail("Could not restore the default Claude profile automatically (code " + rc + ").\nCheck the folder:\n" + dataRoot + "\nNothing was changed.");
        }

        var cmd = new StringBuilder(Quote("--user-data-dir=" + profileDir));
        foreach (string a in passThrough) cmd.Append(' ').Append(Quote(a));

        if (dryRun)
        {
            Console.WriteLine(exe);
            Console.WriteLine(cmd.ToString());
            return 0;
        }
        Process.Start(new ProcessStartInfo(exe, cmd.ToString()) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(exe) });
        return 0;
    }

    static bool IsValidProfileName(string name)
    {
        return name != null && Regex.IsMatch(name, NamePattern)
            && !name.Equals("bin", StringComparison.OrdinalIgnoreCase)
            && !name.Equals("default", StringComparison.OrdinalIgnoreCase);
    }

    // Microsoft Store install first, then the classic installer (%LOCALAPPDATA%\AnthropicClaude).
    static void FindClaude(out string exe, out string dataRoot)
    {
        exe = null; dataRoot = null;
        string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        foreach (string pkg in StorePackagePaths(StoreFamily))
        {
            string candidate = Path.Combine(pkg, @"app\claude.exe");
            if (File.Exists(candidate))
            {
                exe = candidate;
                dataRoot = Path.Combine(local, @"Packages\" + StoreFamily + @"\LocalCache\Roaming");
                return;
            }
        }
        string classic = Path.Combine(local, @"AnthropicClaude\claude.exe");
        if (File.Exists(classic))
        {
            exe = classic;
            dataRoot = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern int GetPackagesByPackageFamily(string packageFamilyName, ref uint count, IntPtr packageFullNames, ref uint bufferLength, IntPtr buffer);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern int GetPackagePathByFullName(string packageFullName, ref uint pathLength, StringBuilder path);

    static List<string> StorePackagePaths(string family)
    {
        var result = new List<string>();
        try
        {
            uint count = 0, len = 0;
            GetPackagesByPackageFamily(family, ref count, IntPtr.Zero, ref len, IntPtr.Zero);
            if (count == 0) return result;
            IntPtr names = Marshal.AllocHGlobal((int)count * IntPtr.Size);
            IntPtr buffer = Marshal.AllocHGlobal((int)len * 2);
            try
            {
                if (GetPackagesByPackageFamily(family, ref count, names, ref len, buffer) != 0) return result;
                for (int i = 0; i < count; i++)
                {
                    string fullName = Marshal.PtrToStringUni(Marshal.ReadIntPtr(names, i * IntPtr.Size));
                    uint pathLen = 0;
                    GetPackagePathByFullName(fullName, ref pathLen, null);
                    var path = new StringBuilder((int)pathLen);
                    if (GetPackagePathByFullName(fullName, ref pathLen, path) == 0) result.Add(path.ToString());
                }
            }
            finally { Marshal.FreeHGlobal(names); Marshal.FreeHGlobal(buffer); }
        }
        catch (EntryPointNotFoundException) { }   // Windows versions without the packaging API
        return result;
    }

    // Quotes one argument using the rules CommandLineToArgvW / the MSVC runtime use to split it again.
    static string Quote(string arg)
    {
        if (arg.Length > 0 && arg.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return arg;
        var sb = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in arg)
        {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') sb.Append('\\', slashes * 2 + 1);
            else sb.Append('\\', slashes);
            slashes = 0;
            sb.Append(c);
        }
        sb.Append('\\', slashes * 2).Append('"');
        return sb.ToString();
    }

    static int RunHidden(string file, string args)
    {
        using (var p = Process.Start(new ProcessStartInfo(file, args) { UseShellExecute = false, CreateNoWindow = true }))
        {
            if (!p.WaitForExit(120000)) return -1;
            return p.ExitCode;
        }
    }

    static int Fail(string message)
    {
        if (dryRun) Console.Error.WriteLine(message);
        else MessageBox.Show(message, Title, MessageBoxButtons.OK, MessageBoxIcon.Warning);
        return 1;
    }
}
