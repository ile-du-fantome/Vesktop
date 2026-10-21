# Vesktop PTT Arch Linux package

Builds the
[`ile-du-fantome/Vesktop`](https://github.com/ile-du-fantome/Vesktop) `ptt`
branch from the latest commit.

## Build and install

```sh
cd packaging/arch
makepkg -si
```

The package depends on `netcat` because the PTT integration uses `nc -U` to
send commands to the control socket. It also needs `pnpm`, `npm`, `nodejs`,
`git`, `pkgconf`, `glib2`, and `python` at build time.

To pick up a newer `ptt` commit after the package is already installed:

```sh
makepkg -sif
```

## Using the socket

```sh
echo run-shortcut:pushToTalkKeyStart | nc -N -U "$XDG_RUNTIME_DIR/vesktop.sock"
echo run-shortcut:pushToTalkKeyStop  | nc -N -U "$XDG_RUNTIME_DIR/vesktop.sock"
```

The `run-shortcut:<action>` actions and the `ptt-key`/`ptt-debug` commands are
described in the socket's `help` output. The socket is Linux-only.
