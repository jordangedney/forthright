# lib/ — the fr standard library

Small, self-hosted `.fr` modules for building programs (the focus right now is
terminal/TUI apps). Everything here is plain fr on top of the kernel; nothing is
privileged.

## Loading: `include`

The kernel word **`include PATH`** loads another source file, then resumes where it
left off. Paths are relative to the directory you run `fr` from (the project root).
`include` is **load-once** (a path already included is skipped), so modules can pull
their own dependencies without double-loading — the diamond `tui → draw → term →
prelude` loads `prelude` exactly once.

So a program just declares what it needs and runs as a single file:

```forth
\ myapp.fr
include lib/tui.fr        \ pulls in draw, key, term, math, prelude transitively

raw-on hide-cursor clear
1 1 40 10 s" Demo" panel
3 3 s" press a key…" label
getkey drop
show-cursor reset raw-off bye
```
```sh
./fr myapp.fr
```

(You can still list files explicitly — `./fr lib/prelude.fr lib/term.fr myapp.fr` —
but `include` is the ergonomic way.)

## Modules

| module       | what it gives you | key words |
|--------------|-------------------|-----------|
| `prelude.fr` | the core vocabulary (everything derivable from the kernel) | `over rot nip 2dup negate 1+ cells , see trace key u. .n '` |
| `math.fr`    | integer helpers | `2* 2/ abs min max <= >= /mod mod within +! clamp` |
| `string.fr`  | addr/len strings | `count blank c, s, place s=` |
| `fmt.fr`     | number→text, padding | `u>str u>hex u.r .r .x type-pad` |
| `term.fr`    | ANSI + termios (cbreak) | `at clear fg24 nord-* box raw-on raw-off raw-timed term-size reverse` |
| `key.fr`     | decode keystrokes incl. escape sequences | `getkey KEY-UP/DOWN/LEFT/RIGHT/HOME/END/ENTER/ESC/BS/TAB` |
| `draw.fr`    | panels / rules / rects on term | `panel hline vline clear-rect at-type` |
| `tui.fr`     | widgets | `label status-bar menu-draw menu-run accept` |
| `time.fr`    | clock + sleep | `now-ms sleep-ms` |
| `io.fr`      | files | `open-r open-w read-fd write-fd close-fd zpath` |
| `ptrace.fr`  | process control + ptrace | `fork wait4 traceme getregs peekdata watch` |

## Conventions & gotchas

- **Strings** are `(addr len)` pairs (what the kernel's `s"` leaves). `."` prints
  inline. Compiled (inside a `:` definition) each `s"`/`."` has its own storage; in
  **interpret mode** the `s"` buffer is *transient* — two interpreted `s"` in one
  phrase alias the same buffer, so copy one out (`place`, `cmove`) if you need both.
- TUI words assume you've entered cbreak with `raw-on` (and usually `hide-cursor`);
  restore with `raw-off` / `show-cursor` before exit.
- `open-r`/`open-w` want a **NUL-terminated** path — use `zpath ( addr len -- zaddr )`.
- `include` paths are resolved from the **current directory**, not the including file.

## Status

`prelude math string fmt term key draw time io ptrace` are implemented and tested
(`./test.sh` covers them). `tui` has `label/status-bar/menu/accept` working; richer
widgets (scrolling lists, multi-field forms) are the next layer to grow here.
