# vitterm

A fast, native, GPU-accelerated terminal for macOS, written in Swift with Metal and AppKit.
The terminal emulation core is written from scratch, with no third-party emulator underneath.

## Features

- **Metal rendering**: instanced quads, a glyph atlas (grayscale plus color emoji), triple
  buffering, and vsync-paced frames that stop completely when idle.
- **Fonts**: any installed font, with OpenType features (`font-feature = ss01`) and **ligatures**
  through CoreText shaping. Shaping is cached per line. Box drawing, block elements and
  Powerline glyphs are drawn procedurally so they tile without gaps.
- **Themes**: 10 bundled themes, user themes in `~/.config/vitterm/themes`, automatic light/dark
  switching, and hot reload of the whole config.
- **Native tabs** (macOS window tabbing) and **splits** (draggable dividers, directional focus,
  resize, zoom, equalize).
- **Broadcast input**: type into every pane of a tab (⌘⌥I), choose individual panes (⌘⌥⇧I), or
  broadcast to every pane everywhere. Each pane encodes keys using its own terminal modes.
- **Search** in scrollback (⌘F): smart case, regex, matches across soft wraps.
- **Links**: OSC 8 hyperlinks and detected URLs; hold ⌘ and click to open.
- **Inline images**: the Kitty graphics protocol (PNG/RGB/RGBA, chunked, file/temp-file transfer,
  placement, deletion) and iTerm2 `OSC 1337 File=`.
- **Emulation**: xterm-compatible. Covers truecolor, 256 colors, styled/colored underlines
  (curly, dotted, dashed, double), alternate screen, scroll regions, mouse reporting (X10/normal/
  button/any, SGR and SGR-pixels), bracketed paste, focus events, synchronized output (2026),
  grapheme clustering (2027), the Kitty keyboard protocol, OSC 4/10/11/12/52/133, DECRQM,
  XTGETTCAP, XTVERSION, and reflow on resize.
- **IME** support (`NSTextInputClient`), Option as Alt (left/right/both), paste protection,
  file drag-and-drop, shell integration for zsh and fish (prompt marks with ⌘↑/⌘↓ to jump
  between prompts, and new tabs/splits open in the current directory).

## Building

Requires macOS 14+ and Xcode (for the offline Metal compiler; `swift run` also works without it,
because shaders then compile at launch).

```sh
./scripts/bundle.sh          # builds build/vitterm.app (release, ad-hoc signed)
open build/vitterm.app

swift run vitterm            # debug build without bundling
scripts/test.sh              # tests + performance regression check (see Testing)
swift run -c release vitbench     # benchmark suite
```

`vitterm -e <command>` runs a command instead of your shell.

## Security

Anything a terminal displays can try to attack it (a file you `cat`, a server you `ssh` to), so
vitterm treats all program output as untrusted:

- Replies to queries never echo program-supplied text back as input (no title reporting).
- Clipboard reads (OSC 52) are off by default; writes can be limited with `clipboard-write = ask`
  or `deny`, and are capped at 4 MB.
- ⌘-click opens only web and mail links directly. Other URL schemes, files that can run code
  (apps, scripts, installers) and file links naming another host are confirmed first. Hovering a
  link with ⌘ held shows where it really goes.
- Pasted text is stripped of control characters (so it can't end bracketed paste early), and
  dropped or pasted file names are shell-quoted, including names containing newlines.
- Image protocols are size-limited (pixels, transfers, decompression, placement), Kitty file
  transfers only read regular files (`image-file-transfer = false` turns them off), and temp-file
  deletion is confined to real temp directories.
- Window titles, notifications and link previews are stripped of control and bidirectional-override
  characters; hyperlinks, image placements and grapheme clusters are length- and count-limited.
- Replies to queries are capped while the program isn't reading them, so a file full of queries
  can't exhaust memory.
- Working directories reported by programs (OSC 7) are only used from the local host, so a remote
  shell can't point new tabs or the window's proxy icon at local paths. The bash integration
  percent-encodes the directory, so directory names can't inject escape sequences.
- Desktop notifications from programs are rate-limited and can be turned off
  (`desktop-notifications = false`); clipboard reads can require confirmation (`clipboard-read = ask`).
- Image decoding is followed by a short back-off, so a stream of huge images can't freeze the UI.
- Secure Keyboard Entry (in the vitterm menu) stops other apps from reading your keystrokes. It
  also turns on automatically at password prompts.
- The app bundle is signed with the hardened runtime, and the debug hooks below exist only in
  debug builds and test builds.

## Configuration

`~/.config/vitterm/config` (⌘, creates and opens it). Changes apply as soon as you save.

```
font-family = JetBrains Mono
font-size = 13
font-feature = ss01
theme = light:Vit Light,dark:Vit Dark
background-opacity = 0.95
background-blur = 20
option-as-alt = left
keybind = cmd+shift+t=new_tab
keybind = ctrl+a=text:\x01
```

Run `vitterm` and press ⌘, to see every option in the generated template.

## Layout

| Path | Purpose |
| --- | --- |
| `Sources/VitCore` | Parser, terminal state, grid/scrollback/reflow, Unicode widths, search, selection, key encoding, images |
| `Sources/VitPTY` | `forkpty` process spawning, PTY read thread, resize |
| `Sources/VitRender` | Metal pipelines, CoreText shaping, glyph atlas, box drawing |
| `Sources/VitConfig` | Config parser, themes, keybindings, file watcher |
| `Sources/vitterm` | AppKit app: windows/tabs, split tree, input, mouse, search UI |
| `Sources/vitbench` | Benchmark suite (parse, PTY, render, reflow, search, memory) and performance gate |

## Performance

Measured on Apple Silicon with `vitbench` (200×60 cells, 10k-line scrollback, CPU time at
user-interactive priority):

| | |
| --- | --- |
| Parser throughput | ~700 MB/s plain text, 470 MB/s short code lines, 450 MB/s SGR-heavy, 365 MB/s Unicode, 300 MB/s cursor addressing |
| End to end through a PTY | ~180 MB/s, which is the macOS PTY limit (the kernel hands over ~1 KB per `read`); parsing keeps up |
| Frame build (CPU) | 0.1 ms static, 0.15–0.22 ms while scrolling 60 lines/frame, with or without ligatures |
| Search, 10k lines | 0.2 ms while typing a query, 1.2 ms after new output (index rebuild) |
| Resize with full scrollback | ~4 ms (reflow of 10k lines) |
| Scrollback memory | ~0.6 KB per line of typical output (60 MB for 100k lines) |
| Output-to-screen latency when idle | ~16–20 ms median (≈ one frame plus compositing) |
| Launch to first frame | ~170 ms |
| Idle CPU | 0%: no frames unless something changes, no polling timers, and the cursor stops blinking after 15 s without input |

How it gets there:

- **Parsing:**
  - SIMD scanning for printable ASCII.
  - Bulk UTF-8 decoding into batches that are written a row at a time.
  - A tight loop for CSI parameters.
  - No reference counting in the hot paths.
- **Scrolling:**
  - Recycled lines are cleared by resetting a high-water mark rather than zeroing memory.
  - With full scrollback, the line leaving the screen and the oldest line swap storage, so
    scrolling allocates and copies nothing in steady state.
  - Lines that scroll into scrollback are compacted to their content.
  - Full-width buffers are pooled for reuse.
- **Rendering:**
  - Lines are shaped once per change and cached by line identity.
  - CoreText runs are cached by content in a two-generation cache, so ligatures and complex
    scripts cost almost nothing after the first appearance.
  - Atlas lookups are cached per row.
  - The renderer copies only the visible, used cells under the lock.
- **Latency:**
  - Output arriving while idle is drawn immediately instead of waiting for the next display-link
    tick.
  - New windows and tabs commit their first frame with the window's transaction, so they never
    flash empty.
  - Hidden windows don't render.
  - While output streams continuously, frames are capped at 60 fps (on 100–120 Hz displays);
    interactive frames keep the full rate.
  - A frame is skipped rather than blocking the main thread when no drawable is free.
  - While frames are being drawn, the PTY thread doesn't wake the main thread per read; each
    display-link tick picks up the output.
- **Search:** one cached UTF-16 index per content version, with a direct scan for literal
  queries.

## Testing

```sh
scripts/test.sh              # unit + integration tests, then the performance regression check
scripts/test.sh --e2e        # also builds a test app (build/e2e) and drives it end to end (opens windows briefly)
scripts/test.sh --extended   # fuzz/differential tests at 20x size (~2 minutes)
```

| Suite | What it covers |
| --- | --- |
| `VitCoreTests` | Parser; terminal emulation checked against xterm behavior (cursor, modes, scrolling, erasing, tabs, alternate screens, reports, OSC/DCS/APC, Kitty keyboard and graphics, iTerm2 images); key encoding tables for legacy xterm and Kitty sequences; search, selection and links |
| ↳ property tests | Structural invariants after random input, including deliberately split sequences, wide characters and resizes; released memory is poisoned so stale reads are caught. Reflow round-trips preserve every logical line |
| ↳ differential tests | Optimized paths compared against simple reference implementations: batched printing vs per-character printing (every cell), and the search index vs per-line regex |
| `VitRenderTests` | Shaping (runs, styles, wide and combining characters, fallback fonts, Fira Code ligatures, run cache), glyph atlas growth, box drawing geometry for every line-drawing character, and offscreen Metal renders checked pixel by pixel (colors, cursor shapes, selection, search, underlines, images, overlays, caching) |
| `VitPTYTests` | Real child processes: output, exit status, window size and resize, input, large writes, hangup, environment, descriptor leaks |
| `VitConfigTests` | Every setting, diagnostics, includes, themes (completeness, contrast), keybindings, and live reload (including a config created after launch) |
| `E2ETests` | The built app driven by scripted actions: commands, splits, broadcast input, tabs, closing, hot reload, search, shell integration |
| `vitbench --check` | Performance budgets for throughput, frame time, search, reflow and memory; exits non-zero on a regression |

## Debugging aids

These only work in debug builds (`swift run vitterm`) and in test builds
(`TEST_HOOKS=1 APP=build/e2e/vitterm.app scripts/bundle.sh`), not in the normal app bundle.

- `VITTERM_SNAPSHOT=/tmp/out.png` renders the focused tab offscreen to a PNG after
  `VITTERM_SNAPSHOT_DELAY` seconds (set `VITTERM_SNAPSHOT_QUIT=1` to exit afterwards).
- `VITTERM_DEBUG_ACTIONS='new_split:right;;text:ls\r'` replays keybinding actions at startup.
- `VITTERM_DEBUG_DUMP=/tmp/state.json` writes windows, tabs, panes (with their text) and config as JSON.
- `VITTERM_DEBUG_LATENCY=/tmp/latency.txt` logs output-to-screen latency per idle update.
- `VITTERM_DEBUG_STARTUP=1` prints startup phase timings.
- `VITTERM_FUZZ_TRACE=/tmp/trace.txt` (tests) records the input being fuzzed, to reproduce crashes.
