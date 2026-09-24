# StayAwake

A macOS menu bar app that keeps your Mac awake — even with the lid closed — until you turn it off.

## How it works

Turn on **Keep Awake** in the menu and your Mac won't sleep, even with the lid closed. Close the lid and walk away — your dev server, Docker containers, and long-running scripts keep going. Turn it off and your normal sleep settings come back.

While on, StayAwake also keeps the display awake so your Mac doesn't idle into the screen saver or lock screen. Toggle this with **Prevent Screen Lock**.

## Build

Requires Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh
```

Produces `dist/StayAwake.app` — a universal binary (Apple Silicon + Intel).

> First launch will ask for one-time admin access to configure passwordless sleep control.

## Menu bar

The sun icon appears in your menu bar — bright when preventing sleep, faded when idle. Click it for:

- **Keep Awake** — on or off. Remembered across restarts
- **Prevent Screen Lock** — keep the display on while awake
- **Launch at Login**

## Config

Saved to `~/.stayawake.json`:

```json
{
  "mode": "on",
  "preventScreenLock": true
}
```

## Requirements

- macOS 13 (Ventura) or later
- Xcode Command Line Tools (build only)

## Why StayAwake in the AI era

AI coding agents like Claude Code, Copilot, Cursor, and Devin run long autonomous sessions — generating code, running tests, deploying. If your Mac sleeps mid-task, the agent loses its connection, context resets, and work is wasted.

Turn StayAwake on before you walk away. Close the lid, come back to a finished task — not a stale SSH timeout or a half-completed refactor.

## Known limitations

- Requires one-time sudoers setup per user (managed/locked-down Macs may not allow this)
- Not signed or notarized — requires right-click > Open on first launch
- Traps heat when lid is closed — do not put in a bag while awake, and turn it off when you're done
- Prevent Screen Lock only stops the *idle* lock — closing the lid, locking manually (⌃⌘Q), or a fast user switch still locks. It also keeps the display on, which costs battery

## License

MIT
