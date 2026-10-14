# Claude Desktop Profiles (Windows)

Run several Claude Desktop accounts side by side on one Windows PC, for example **Personal** and **Work**, each with its own login, chats, settings and Claude Code history.

> **Unofficial.** This is a community tool. It is not made, endorsed or supported by Anthropic. It relies on how Claude Desktop currently stores its data, which may change in future releases.

```
Claude (your normal app)   -> default profile   -> e.g. personal account
Claude Work.exe            -> profile "Work"    -> work account
Claude Client A.exe        -> profile "Client A" -> another account
```

## Requirements

- Windows 10 or 11
- [Claude Desktop](https://claude.ai/download). Developed and tested with the Microsoft Store version. The classic installer (`%LOCALAPPDATA%\AnthropicClaude`) is supported in code but has not been tested yet; reports welcome.
- Nothing else. The scripts use Windows PowerShell 5.1 and the .NET Framework C# compiler, both built into Windows.

## Quick start

1. **Download** this repository (Code > Download ZIP, then extract it, or `git clone`).
2. **Create a profile.** In PowerShell, from the repository folder:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1 -Name Work
   ```
   This creates `%USERPROFILE%\ClaudeProfiles\Work` and puts **Claude Work** on your Desktop and in the Start Menu.
3. **Sign the profile in.** In your web browser, make sure claude.ai is signed in to the account this profile should use (or signed out). Then run:
   ```powershell
   powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\ClaudeProfiles\bin\SignIn.ps1" -Name Work
   ```
   Follow the prompts: quit Claude, sign in in the window that opens, then quit Claude again. Keep the PowerShell window open until it says **Done**.
4. **Use it.** Open **Claude Work** for work and your normal **Claude** app for everything else. Both can be open at the same time.

Optional: `-Icon .\my-icon.png` gives the launcher your own icon (use a PNG with a transparent background, or an `.ico`). Without it, a coloured letter badge is generated.

## How it works

Claude Desktop is built on Electron, which keeps all of its state in one *user data folder*. The launcher starts the same installed Claude Desktop with `--user-data-dir=%USERPROFILE%\ClaudeProfiles\<Name>`, so each profile is a fully separate copy of that state. Nothing in Claude Desktop is modified, and Store updates keep working: the launcher finds the current install each time it starts.

### Why signing in needs a script

When you sign in, Claude Desktop opens your **web browser**. The browser then hands the result back with a `claude://` link, and Windows always delivers that link to the normal Claude app (the default profile). A profile never receives it, so it cannot finish signing in on its own.

`SignIn.ps1` works around this for the one-time sign-in:

1. It waits until Claude is fully quit, then renames the default data folder to `Claude.default-profile`.
2. It creates a directory junction named `Claude` that points at the profile, and opens Claude. The `claude://` link now lands in the profile.
3. When you quit Claude, it removes the junction and renames the default folder back.

Safety: data is only ever renamed or linked, never deleted. If the script is interrupted (the window is closed, Ctrl+C, a crash), the default profile is restored automatically the next time you open any profile launcher, or by running `Restore.ps1`. Restoring refuses to run while Claude is open, and refuses to guess if it finds an unexpected folder layout.

**The browser decides the account.** Sign-in reuses whatever account your browser is signed in to on claude.ai and Google. If a profile ends up on the wrong account, sign out of claude.ai in the browser (or pick the right Google account) and run `SignIn.ps1` again. The script warns you if the profile ends up on the same account as your default app.

## Moving existing Claude Code chats into a profile

Regular chats are stored on Anthropic's servers and appear in any app signed in to that account. **Claude Code chats are different:** Claude Desktop lists them from local files in its data folder, filed by account. A new profile therefore starts with an empty Claude Code list, even for an account you have used before in the normal app.

```powershell
cd "$env:USERPROFILE\ClaudeProfiles\bin"
.\Copy-CodeSessions.ps1 -Name Work -List      # which accounts have chats, and in which folders
.\Copy-CodeSessions.ps1 -Name Work -WhatIf    # preview
.\Copy-CodeSessions.ps1 -Name Work            # copy the chats of the account Work is signed in to
```

Files are copied (never moved) and existing files are never overwritten. Quit the profile first. Conversation transcripts live in `%USERPROFILE%\.claude`, which every profile shares, so the copied chats open with their full history.

## Running profiles side by side

- **Shared Claude Code configuration.** All profiles use the same `%USERPROFILE%\.claude` folder: settings, `CLAUDE.md` files, skills and MCP servers apply everywhere. Only the chat lists and logins are separate.
- **Don't point two profiles at the same project folder at once.** Two Claude Code sessions editing the same files can overwrite each other.
- **Claude in Chrome** connects to one app at a time, since all profiles share the same browser extension.
- **Memory.** Each running profile is a full Claude Desktop (roughly 1.5 GB or more with Claude Code sessions). Quit profiles you are not using from the system tray.
- **Taskbar.** The running window shows Claude's own icon; only the launcher carries the profile icon. Pin the Start Menu entry (*Claude &lt;Name&gt;* > Pin to taskbar) to tell them apart.

## Commands

| Command | What it does |
|---|---|
| `install.ps1 -Name <Name> [-Icon <png/ico>] [-NoDesktopIcon] [-NoStartMenu]` | Create a profile, or update its launcher and icon. Never touches profile data. |
| `bin\SignIn.ps1 -Name <Name>` | Sign a profile in to an account. |
| `bin\Copy-CodeSessions.ps1 -Name <Name> [-List] [-AccountId <id>] [-WhatIf]` | Copy Claude Code chats from the normal app into a profile. |
| `bin\Restore.ps1` | Put the default profile back after an interrupted sign-in. |
| `bin\Uninstall.ps1 -Name <Name> [-DeleteData] [-Force]` | Remove a profile's launchers; with `-DeleteData`, also its data. |
| `Claude <Name>.exe [--profile=<Name>] [args...]` | The launcher. Extra arguments are passed to Claude Desktop. |

Set `CLAUDE_PROFILES_ROOT` to keep profiles somewhere other than `%USERPROFILE%\ClaudeProfiles`.

## Troubleshooting

**Clicking the profile does nothing / it only opens after quitting the normal Claude.** A sign-in is probably still in progress or was interrupted while Claude was open. Quit Claude from the system tray (right-click > Quit, since closing the window only hides it) and open the profile again; it repairs itself.

**The profile keeps asking me to sign in.** Signing in from inside the profile window cannot complete (see *Why signing in needs a script*). Use `SignIn.ps1`.

**Both apps show the same account.** The browser was signed in to that account during `SignIn.ps1`. Sign out of claude.ai in the browser and run it again. To switch the *normal* app instead, just sign out and in there; it receives sign-in links directly.

**"Running scripts is disabled on this system".** Use `powershell -ExecutionPolicy Bypass -File ...` as shown above, or run `Unblock-File` on the downloaded files.

**The Desktop still shows an old icon.** Press F5 on the Desktop; Windows caches icons.

## Development

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
```

The test suite needs no extra modules. It runs entirely in a temporary folder against a fake Claude install, including full sign-in, interruption and restore cycles, so it never touches your real Claude data. The launcher (`src\Launcher.cs`) is compiled by `install.ps1` with the C# 5 compiler that ships with Windows, so keep it free of newer C# syntax.

## Limitations

- Windows only.
- Relies on undocumented Claude Desktop details: the user data folder layout, the `claude-code-sessions` folder structure, and Electron's `--user-data-dir` switch. A Claude Desktop update could change any of these.
- Check your organization's policies before using a work account this way.

## Legal

Released under the [MIT License](LICENSE). "Claude" and "Anthropic" are trademarks of Anthropic, PBC; this project is not affiliated with Anthropic. Please don't ship Anthropic logos or mascots as launcher icons in forks of this project.
