/*
 * Vesktop, a desktop app aiming to give you a snappier Discord Experience
 * Copyright (c) 2025 Vendicated and Vesktop contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { app } from "electron";
import { chmodSync, rmSync } from "fs";
import { createServer, Server } from "net";
import { tmpdir } from "os";
import { join } from "path";

import { IpcCommands, IpcEvents } from "shared/IpcEvents";

import { sendRendererCommand } from "./ipcCommands";
import { mainWin } from "./mainWindow";
import { Settings, State } from "./settings";
import { handle } from "./utils/ipcWrappers";

/**
 * External control socket for push-to-talk and (self-)mute actions.
 *
 * Listens on a Unix domain socket (${XDG_RUNTIME_DIR}/vesktop-ipc.sock) so
 * that compositor keybinds and scripts can drive Discord's voice features
 * without focusing the Vesktop window:
 *
 *   echo ptt-down | nc -U "$XDG_RUNTIME_DIR/vesktop-ipc.sock"
 *
 * (add -N for fire-and-forget clients that should not wait for the response)
 *
 * Commands (newline separated, one "ok"/"err: ..." response per line):
 *   ping                         -> "pong"
 *   help                         -> list of commands
 *   ptt-down / ptt-up            -> synthesize a trusted keyDown/keyUp of the
 *                                   PTT key Discord is configured with
 *                                   (reported by the renderer), driving
 *                                   Discord's own push-to-talk handling
 *   ptt-key [mod+...]<keyCode>   -> manually override the PTT key used by
 *                                   ptt-down/ptt-up (e.g. "F13",
 *                                   "control+shift+alt+p"); with no argument,
 *                                   report the currently cached key
 *   ptt-force-down/-up           -> engine-level PTT via the media engine's
 *                                   setForceAudioInput (experimental; does
 *                                   not depend on keybind configuration)
 *   mute / unmute / toggle-mute  -> Discord self-mute (in-app, not PipeWire)
 */

interface PttShortcut {
    /** Electron keyCode of the trigger key, e.g. "F13". */
    keyCode: string;
    /** Electron modifiers held for the trigger, e.g. ["control"]. */
    modifiers: string[];
}

/**
 * The PTT key ptt-down/ptt-up synthesize. Normally reported by the renderer
 * (which reads Discord's configured keybind); a manual `ptt-key` override is
 * persisted in State.store.pttKeyOverride and takes precedence over the
 * renderer's reports.
 */
let pttShortcut: PttShortcut | null = State.store.pttKeyOverride ?? null;

let server: Server | null = null;

export function getRpcSocketPath() {
    return join(process.env.XDG_RUNTIME_DIR || tmpdir(), "vesktop-ipc.sock");
}

handle(IpcEvents.SET_PTT_KEY, (_e, shortcut: PttShortcut | null) => {
    // A manual `ptt-key` override takes precedence over the renderer's report.
    if (State.store.pttKeyOverride != null) return;
    pttShortcut = shortcut;
    console.log(
        "[vesktop-rpc] push-to-talk key:",
        shortcut ? [...shortcut.modifiers, shortcut.keyCode].join("+") : "(none)"
    );
});

function sendPttKey(down: boolean) {
    if (!pttShortcut)
        throw new Error(
            "Discord's push-to-talk keybind is not known. Configure a push-to-talk keybind in " +
            "Discord's settings, or set one manually with the `ptt-key` command."
        );
    if (!mainWin || mainWin.isDestroyed()) throw new Error("main window is not available");

    mainWin.webContents.sendInputEvent({
        type: down ? "keyDown" : "keyUp",
        keyCode: pttShortcut.keyCode,
        modifiers: pttShortcut.modifiers as ("control" | "shift" | "alt" | "meta")[]
    });
}

async function runCommand(line: string): Promise<string> {
    const [command, ...args] = line.split(/\s+/);

    switch (command) {
        case "ping":
            return "pong";
        case "help":
            return "commands: ping, help, ptt-down, ptt-up, ptt-key <keyCode>, " +
                "ptt-force-down, ptt-force-up, mute, unmute, toggle-mute";
        case "ptt-down":
            sendPttKey(true);
            return "ok";
        case "ptt-up":
            sendPttKey(false);
            return "ok";
        case "ptt-key": {
            const arg = args.join(" ").trim();
            if (!arg)
                return "current push-to-talk key: " +
                    (pttShortcut ? [...pttShortcut.modifiers, pttShortcut.keyCode].join("+") : "(none)") +
                    (State.store.pttKeyOverride != null ? " (manual override)" : "");

            // "ptt-key auto" / "ptt-key clear": drop the manual override and
            // go back to the keybind auto-detected from Discord.
            if (arg === "auto" || arg === "clear") {
                State.store.pttKeyOverride = null;
                pttShortcut = null;
                await sendRendererCommand(IpcCommands.PTT, { reportKey: true });
                return "ok";
            }

            // e.g. "ptt-key F13" or "ptt-key control+shift+alt+p"
            const parts = arg.split("+").map(part => part.trim()).filter(Boolean);
            const MODIFIER_NAMES: Record<string, string> = {
                ctrl: "control",
                control: "control",
                shift: "shift",
                alt: "alt",
                meta: "meta",
                super: "meta",
                mod: "meta"
            };
            const keyCode = parts.pop();
            if (!keyCode) throw new Error("usage: ptt-key [modifier+...]<Electron keyCode, e.g. F13>");
            const modifiers: string[] = [];
            for (const part of parts) {
                const modifier = MODIFIER_NAMES[part.toLowerCase()];
                if (!modifier) throw new Error(`unknown modifier: ${part}`);
                if (!modifiers.includes(modifier)) modifiers.push(modifier);
            }
            pttShortcut = { keyCode, modifiers };
            State.store.pttKeyOverride = pttShortcut;
            return "ok";
        }
        case "ptt-debug":
            return JSON.stringify(await sendRendererCommand(IpcCommands.PTT_DEBUG), null, 2);
        case "ptt-force-down":
            await sendRendererCommand(IpcCommands.PTT, { active: true });
            return "ok";
        case "ptt-force-up":
            await sendRendererCommand(IpcCommands.PTT, { active: false });
            return "ok";
        case "mute":
            await sendRendererCommand(IpcCommands.SELF_MUTE, { muted: true });
            return "ok";
        case "unmute":
            await sendRendererCommand(IpcCommands.SELF_MUTE, { muted: false });
            return "ok";
        case "toggle-mute":
            await sendRendererCommand(IpcCommands.SELF_MUTE, {});
            return "ok";
        default:
            throw new Error(`unknown command: ${command}`);
    }
}

export function startRpcServer() {
    // Unix domain sockets only; Windows could use a named pipe instead.
    if (process.platform === "win32") return;
    if (Settings.store.rpcSocketEnabled === false) return;

    const socketPath = getRpcSocketPath();

    // Remove a stale socket left behind by a previous (crashed) instance.
    rmSync(socketPath, { force: true });

    server = createServer(conn => {
        // One-shot request/response semantics: each connection carries one or
        // more complete commands, gets one response line per command, and is
        // then closed by the server. This works with both fire-and-forget
        // clients (`nc -N`, which exits right after sending) and clients that
        // wait for the response (plain `nc`, which exits when we close).
        conn.on("data", data => {
            conn.on("data", () => { /* ignore any further data on this one-shot connection */ });
            void (async () => {
                for (const line of data.toString().split("\n")) {
                    if (!line.trim()) continue;
                    try {
                        conn.write(await runCommand(line.trim()) + "\n");
                    } catch (err: any) {
                        conn.write(`err: ${err?.message ?? String(err)}\n`);
                    }
                }
                conn.end();
            })();
        });
        conn.on("error", () => { /* client went away; nothing to do */ });
    });

    server.on("error", err => console.error("[vesktop-rpc] server error:", err));

    server.listen(socketPath, () => {
        try {
            chmodSync(socketPath, 0o600);
        } catch { }
        console.log(`[vesktop-rpc] listening on ${socketPath}`);
    });

    app.on("will-quit", () => {
        server?.close();
        rmSync(socketPath, { force: true });
    });
}
