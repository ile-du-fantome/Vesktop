# Jay + Vesktop push-to-talk

Set up Vesktop PTT with Jay.

## 1. Install `ptt.sh`

```sh
install -Dm755 ptt.sh ~/.local/bin/ptt.sh
```

The script requires `bash`, `nc` (the Arch `netcat` package), and PipeWire's
`wpctl`. `pw-dump` and `jq` are optional. They are used to detect the output
device category for volume ducking. Vesktop's PTT keybind should be a key
Discord actually handles, such as `Ctrl+Shift+Alt+P` (not `F13`-`F24`).

## 2. Jay configuration

```toml
[complex-shortcuts.alt-0]
action = { type = "exec", exec = ["/home/user/.local/bin/ptt.sh", "press"] }
latch = { type = "exec", exec = ["/home/user/.local/bin/ptt.sh", "release"] }
```

## 3. Optional `.bashrc` import

If you also want the functions available in interactive shells for testing,
source `ptt.sh` in your bash configuration:

```bash
# Vesktop push-to-talk helpers
if [ -r "$HOME/.local/bin/ptt.sh" ]; then
    . "$HOME/.local/bin/ptt.sh"
fi
```

Then:

```sh
ptt_press
sleep 1
ptt_release
```

Or run the script directly:

```sh
~/.local/bin/ptt.sh press
~/.local/bin/ptt.sh release
```

The script only defines functions when sourced. The `press`/`release` arguments
are only handled when the script is executed.
