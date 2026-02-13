# zigbot

Simple Telegram bot in Zig:
- receives text messages from Telegram
- sends them to Pi (`pi.dev`) via `pi-sdk-zig` v0.1.0
- posts Pi's response back to the same chat

## Requirements

- Zig `0.15.2`
- `pi` CLI installed and authenticated
- Telegram bot token from BotFather

## Config File

Create `~/.config/zigbot/config.toml`:

```toml
telegram_bot_token = "123456:abc..."
pi_executable = "pi"
provider = "google"
# Omit model to use provider defaults.
polling_timeout_seconds = 30
heartbeat_interval_seconds = 300
```

Required fields:
- `telegram_bot_token`

Optional fields:
- `pi_executable` (defaults to `"pi"`)
- `provider`
- `model` (omit to use provider defaults)
- `polling_timeout_seconds` (defaults to `30`)
- `heartbeat_interval_seconds` (defaults to `300`, set `0` or a negative value to disable heartbeat runs)

## Run

```bash
zig build run
```

Use a custom config path:

```bash
zig build run -- /path/to/config.toml
```

Run a one-shot manual heartbeat:

```bash
zig build run -- beat
```

Run a one-shot manual heartbeat with a custom config path:

```bash
zig build run -- beat /path/to/config.toml
```

## Notes

- This implementation is intentionally simple and stateless per incoming message.
- Only plain text Telegram messages are processed.
- Zigbot passes the config file directory to Pi as the agent directory.
- Put optional agent instructions at `~/.config/zigbot/AGENTS.md` (or alongside a custom `config.toml` path).
- Put heartbeat instructions at `~/.config/zigbot/HEARTBEAT.md` (or `<config-dir>/HEARTBEAT.md` with a custom `config.toml` path).
- Put optional skills in `~/.config/zigbot/skills/<skill-name>/SKILL.md` (or `<config-dir>/skills/<skill-name>/SKILL.md` when using a custom config path).
- Zigbot auto-installs a `secrets_store` Pi extension in `<config-dir>/extensions/secrets` when it starts.
- Zigbot auto-installs a companion `secrets` skill in `<config-dir>/skills/secrets/SKILL.md`.
- The extension stores secrets in SQLite at `<config-dir>/secrets.sqlite3`.
- `secrets_store` actions: `set` (`key`, `value`), `get` (`key`), `list` (`prefix` optional), `delete` (`key`).
