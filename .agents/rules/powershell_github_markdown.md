# PowerShell & GitHub CLI Markdown Escaping Rule

## Problem
In PowerShell on Windows, the backtick character (`` ` ``) is the escape character.
When passing inline Markdown text containing backticks inside double quotes (`"..."`) or double-quoted here-strings (`@"..."@`) to shell commands:
- `` `a `` becomes ASCII 0x07 (Bell) -> corrupting strings like `` `am32` `` into `\m32`
- `` `b `` becomes ASCII 0x08 (Backspace) -> corrupting strings like `` `blheli_s` `` or `` `bluejay` `` into `\lheli_s` / `\luejay`
- `` `f `` becomes ASCII 0x0C (Form feed) -> corrupting strings like `` `flrtr` `` into `\lrtr`
- `` `t `` becomes ASCII 0x09 (Tab) -> corrupting strings like `` `timeout` ``
- `` `h `` escapes `h` -> rendering as `\hw5`

## Mandatory Rule
1. **Never inline Markdown with backticks in PowerShell commands.**
2. When creating PRs, editing PRs, or posting comments via GitHub CLI (`gh`):
   - Always write the text to a temporary markdown file via `write_to_file`.
   - Pass `--body-file <filepath>` to `gh pr create`, `gh pr edit`, `gh pr comment`, or `gh issue comment`.
   - Delete the temporary file afterwards.
