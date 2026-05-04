# StayAwake

A macOS menu bar app that keeps your Mac awake while dev processes are running, and lets it sleep when they stop.

No configuration needed. Just run it.

## How it works

StayAwake polls your running processes every 10 seconds. If anything from its watchlist is running (Node, Docker, Python, Claude CLI, etc.) it prevents your Mac from sleeping. When they stop, sleep is restored automatically.

This means you can close your lid and walk away — your dev server, Docker containers, and long-running scripts keep going.

## Build

Requires Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh
```

Produces `dist/StayAwake.app` — a universal binary (Apple Silicon + Intel).

> First launch will ask for one-time admin access to configure passwordless sleep control.

## Menu bar

The sun icon appears in your menu bar — bright when preventing sleep, faded when idle. Click it for status, mode control, and settings.

## Modes

Three operating modes, accessible from the **Mode** submenu:

- **Auto** — Detect watched processes and toggle sleep automatically (default)
- **Always On** — Prevent sleep regardless of running processes
- **Always Off** — Allow sleep regardless of running processes

Mode is persisted in settings — survives restarts.

## Settings

Change the check interval, process watchlist, and launch-at-login via **Settings…** in the menu. Config saved to `~/.stayawake.json`.

## Default watchlist

```
node, npm, pnpm, yarn, bun
python, python3
docker, docker-compose
ruby, rails
go, cargo
java
vite, webpack, next, nuxt, gatsby
postgres, mysql, redis, mongod
claude
```

Add your own via Settings, or edit `~/.stayawake.json` directly.

## Requirements

- macOS 13 (Ventura) or later
- Xcode Command Line Tools (build only)

## Why StayAwake in the AI era

AI coding agents like Claude Code, Copilot, Cursor, and Devin run long autonomous sessions — generating code, running tests, deploying. If your Mac sleeps mid-task, the agent loses its connection, context resets, and work is wasted.

StayAwake solves this by detecting agent processes (`claude`, `node`, `python`, etc.) and keeping your Mac awake for exactly as long as they're running. Close the lid, walk away, come back to a finished task — not a stale SSH timeout or a half-completed refactor.

No manual toggling. No forgetting to turn it off. Sleep resumes the moment the agent exits.

## Known limitations

- Requires one-time sudoers setup per user (managed/locked-down Macs may not allow this)
- Not signed or notarized — requires right-click > Open on first launch
- Traps heat when lid is closed — do not put in a bag while awake
- Process matching is by name — a hung process that hasn't exited will keep the Mac awake

## License

MIT
