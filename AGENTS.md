# Repository Guidelines

## Project Structure & Module Organization
- `src/` contains all Zig source modules.
- `src/main.zig` is the entrypoint, `src/app.zig` runs the bot loop and heartbeat flow.
- Integration modules live alongside app logic: `src/telegram.zig` (Telegram API), `src/pi_agent.zig` (Pi calls), `src/config.zig` (TOML config parsing), `src/errors.zig` (shared error types).
- Build configuration is in `build.zig` and dependencies in `build.zig.zon`.
- Runtime/local state is under `memory/` (do not treat it as source code).

## Build, Test, and Development Commands
- `zig build` builds and installs the `zigbot` binary into `zig-out/`.
- `zig build run` starts the Telegram bot using default config resolution.
- `zig build run -- /path/to/config.toml` runs with a custom config.
- `zig build run -- beat` runs one manual heartbeat, then exits.
- `zig test src/config.zig` runs current unit tests (config parser coverage lives here).
- `zig fmt src/*.zig build.zig` formats code before commit.

## Coding Style & Naming Conventions
- Follow Zig defaults, let `zig fmt` own formatting (4-space indentation, normalized layout).
- Use `camelCase` for functions/locals, `PascalCase` for types, and clear verb-first function names (`runHeartbeat`, `sendMessage`).
- Keep modules focused by concern (app loop vs transport vs config parsing).
- Prefer small, explicit error handling paths over implicit behavior.

## Testing Guidelines
- Add `test "..."` blocks near the code they validate (current pattern in `src/config.zig`).
- Name tests by behavior, for example: `test "parseTomlConfig rejects duplicate configured keys"`.
- Run targeted tests for touched files first, then broader checks when changing shared behavior.

## Commit & Pull Request Guidelines
- Recent history uses concise imperative commits, with partial Conventional Commit usage (for example `feat: ...`).
- Standardize on Conventional Commits where possible: `feat:`, `fix:`, `chore:`, `test:`, `ci:`.
- Keep commits small and scoped to one change.
- PRs should include: summary, user-visible behavior changes, config impact, and test evidence (commands run).

## Security & Configuration Tips
- Never commit secrets (especially `telegram_bot_token` in `config.toml`).
- Keep local config in `~/.config/zigbot/config.toml` or a private path outside version control.
