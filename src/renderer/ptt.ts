/*
 * Vesktop, a desktop app aiming to give you a snappier Discord Experience
 * Copyright (c) 2025 Vendicated and Vesktop contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { find, findByPropsLazy, waitFor } from "@vencord/types/webpack";
import { IpcCommands } from "shared/IpcEvents";

import { onIpcCommand } from "./ipcCommands";
import { VesktopLogger } from "./logger";

// Discord's voice action creators. toggleSelfMute toggles the in-app,
// Flux-tracked self mute (keeping the UI in sync), unlike the connection-
// level MediaEngineConnection.setSelfMute, which bypasses the store.
const MediaEngineActions = findByPropsLazy("toggleSelfMute", "toggleSelfDeaf");

/*
 * MediaEngineStore resolution.
 *
 * Vencord's own binding (Vencord.Webpack.Common.MediaEngineStore) is resolved
 * by store *name*, which Discord may mangle, and Discord lazy-loads its voice
 * stack, so the store may not exist until voice is used. Resolve the store
 * ourselves, by shape, tolerating any export layout ({default: store},
 * {MediaEngineStore: store}, {SomeMangledName: store}, or the store itself).
 */
interface MediaEngineConnectionLike {
    setForceAudioInput(force: boolean): void;
}

interface MediaEngineLike {
    eachConnection(cb: (conn: MediaEngineConnectionLike) => void): void;
}

interface MediaEngineStoreLike {
    isSelfMute(): boolean;
    getModeOptions(): { shortcut?: unknown; };
    addChangeListener(cb: () => void): void;
    getMediaEngine(): MediaEngineLike;
}

function asMediaEngineStore(value: any): MediaEngineStoreLike | null {
    if (typeof value?.isSelfMute === "function"
        && typeof value?.getModeOptions === "function"
        && typeof value?.addChangeListener === "function")
        return value;
    return null;
}

function extractMediaEngineStore(moduleExports: any): MediaEngineStoreLike | null {
    if (asMediaEngineStore(moduleExports)) return moduleExports;
    for (const key of Object.keys(moduleExports ?? {})) {
        try {
            const store = asMediaEngineStore(moduleExports[key]);
            if (store) return store;
        } catch { }
    }
    return null;
}

let mediaEngineStore: MediaEngineStoreLike | null = null;

function getMediaEngineStore(): MediaEngineStoreLike {
    if (!mediaEngineStore) {
        const found = find(moduleExports => extractMediaEngineStore(moduleExports) != null);
        mediaEngineStore = found ? extractMediaEngineStore(found) : null;
    }
    if (!mediaEngineStore)
        throw new Error("Discord's media engine store is not loaded yet; " +
            "join a voice channel (or open Discord's voice settings) once and try again");
    return mediaEngineStore;
}

// Wait for the store module to be (lazy-)loaded by Discord's webpack, then
// keep the reported PTT shortcut up to date with the store's change events.
waitFor(moduleExports => extractMediaEngineStore(moduleExports) != null, (moduleExports: any) => {
    const store = extractMediaEngineStore(moduleExports);
    if (!store || store === mediaEngineStore) return;
    mediaEngineStore = store;
    reportPttShortcut();
    store.addChangeListener(reportPttShortcut);
});

/**
 * Report the push-to-talk keybind Discord is configured with to the main
 * process, which caches it for the RPC socket's ptt-down/ptt-up commands.
 *
 * The shortcut is read from MediaEngineStore.getModeOptions().shortcut.
 * Discord stores keybind keys as [deviceType, keyCode] pairs where keyCode is
 * the legacy DOM keyCode (Ctrl=17, Shift=16, Alt=18, letters=65..90,
 * F1-F24=112..135; F13=124 is displayed as "UNK124" by Discord's keybind UI).
 * Plain strings (KeyboardEvent.code style) are also accepted, just in case.
 */
let lastReported: string | null = null;

function reportPttShortcut() {
    try {
        const shortcut: unknown = mediaEngineStore?.getModeOptions?.().shortcut;
        const parsed = toElectronShortcut(shortcut);
        // The change listener fires for every media engine state change
        // (volumes, speaking, ...); only report actual shortcut changes.
        const serialized = JSON.stringify(parsed);
        if (serialized === lastReported) return;
        lastReported = serialized;
        VesktopNative.ptt.reportShortcut(parsed);
    } catch (err) {
        VesktopLogger.log("[ptt] failed to read push-to-talk shortcut:", err);
    }
}

const MODIFIER_NAMES: Record<string, string> = {
    ctrl: "control",
    control: "control",
    shift: "shift",
    alt: "alt",
    meta: "meta",
    super: "meta",
    mod: "meta"
};

// Legacy DOM keyCodes of the modifier keys.
const MODIFIER_KEYCODES: Record<number, string> = {
    16: "shift",
    17: "control",
    18: "alt",
    91: "meta",
    92: "meta",
    93: "meta"
};

// Legacy DOM keyCode -> Electron keyCode, for the keys without an
// algorithmic mapping below.
const NAMED_KEYCODES: Record<number, string> = {
    8: "Backspace",
    9: "Tab",
    13: "Enter",
    27: "Escape",
    32: "Space",
    33: "PageUp",
    34: "PageDown",
    35: "End",
    36: "Home",
    37: "Left",
    38: "Up",
    39: "Right",
    40: "Down",
    45: "Insert",
    46: "Delete",
    186: ";",
    187: "=",
    188: ",",
    189: "-",
    190: ".",
    191: "/",
    192: "`",
    219: "[",
    220: "\\",
    221: "]",
    222: "'"
};

function legacyKeyCodeToElectron(code: number): string | null {
    if (code >= 65 && code <= 90) return String.fromCharCode(code + 32); // A-Z -> a-z
    if (code >= 48 && code <= 57) return String.fromCharCode(code); // 0-9
    if (code >= 112 && code <= 135) return `F${code - 111}`; // F1-F24
    return NAMED_KEYCODES[code] ?? null;
}

function toElectronShortcut(shortcut: unknown): { keyCode: string; modifiers: string[]; } | null {
    const keys: (string | number)[] = [];
    const collect = (value: unknown) => {
        if (typeof value === "string" || typeof value === "number") {
            keys.push(value);
        } else if (Array.isArray(value)) {
            // [deviceType, keyCode] pair: take the keyCode, but only for the
            // keyboard device (0); mouse/gamepad buttons cannot be
            // synthesized as key events.
            if (typeof value[0] === "number" && value.length >= 2) {
                if (value[0] === 0) collect(value[1]);
            } else {
                value.forEach(collect);
            }
        }
    };
    collect(shortcut);
    if (!keys.length) return null;

    const modifiers: string[] = [];
    let keyCode: string | null = null;

    for (const key of keys) {
        let modifier: string | undefined;
        if (typeof key === "number") {
            modifier = MODIFIER_KEYCODES[key];
            if (!modifier) keyCode = legacyKeyCodeToElectron(key);
        } else {
            modifier = MODIFIER_NAMES[key.toLowerCase()];
            // KeyboardEvent.code style ("KeyM", "Digit1") -> Electron keyCode ("m", "1").
            // Names like "F13", "Space" or "ArrowUp" are passed through unchanged.
            if (/^Key[A-Z]$/.test(key)) keyCode = key.slice(3).toLowerCase();
            else if (/^Digit\d$/.test(key)) keyCode = key.slice(5);
            else if (!modifier) keyCode = key;
        }
        if (modifier && !modifiers.includes(modifier)) modifiers.push(modifier);
    }

    return keyCode ? { keyCode, modifiers } : null;
}

onIpcCommand(IpcCommands.SELF_MUTE, (data?: { muted?: boolean }) => {
    const store = getMediaEngineStore();
    const target = data?.muted ?? !store.isSelfMute();
    if (store.isSelfMute() !== target) MediaEngineActions.toggleSelfMute();
    return { muted: target };
});

// Engine-level push-to-talk: force audio input on every active voice
// connection. Does not depend on Discord's keybind handling, but bypasses
// Discord's UI state for PTT (sounds, indicators).
// data.reportKey instead asks us to (re-)report Discord's configured PTT
// keybind to the main process (used after `ptt-key auto` clears a manual
// override); lastReported is reset because the manual override may have
// suppressed reports in the meantime.
onIpcCommand(IpcCommands.PTT, (data?: { active?: boolean; reportKey?: boolean }) => {
    if (data?.reportKey) {
        lastReported = null;
        reportPttShortcut();
        return;
    }
    getMediaEngineStore().getMediaEngine()
        .eachConnection(conn => conn.setForceAudioInput(!!data?.active));
});

// Diagnostics for why the media engine store / PTT keybind cannot be found.
onIpcCommand(IpcCommands.PTT_DEBUG, () => {
    const result: Record<string, unknown> = {
        resolvedStore: mediaEngineStore != null,
        lastReported
    };

    try {
        result.commonMediaEngineStore = Vencord.Webpack.Common?.MediaEngineStore != null;
    } catch (err) {
        result.commonMediaEngineStoreError = String(err);
    }

    try {
        result.findStoreByName = Vencord.Webpack.findStore("MediaEngineStore") != null;
    } catch (err: any) {
        result.findStoreByNameError = String(err?.message ?? err);
    }

    try {
        const all = Vencord.Webpack.findAll(() => true);
        result.modulesSearched = all.length;

        // Any module (or nested export) that has any of the probed methods,
        // with the method names found on it - reveals mangled/renamed APIs.
        const probes = ["isSelfMute", "getModeOptions", "getMediaEngine", "toggleSelfMute"];
        const nearMisses: unknown[] = [];
        outer: for (const moduleExports of all) {
            let candidates: any[];
            try {
                candidates = [moduleExports, ...Object.values(moduleExports ?? {})];
            } catch {
                continue;
            }
            for (const candidate of candidates) {
                try {
                    if (candidate == null || typeof candidate !== "object") continue;
                    const found = probes.filter(p => typeof candidate[p] === "function");
                    const ctorName = candidate.constructor?.displayName ?? candidate.constructor?.name;
                    if (found.length || ctorName === "MediaEngineStore") {
                        nearMisses.push({
                            ctorName,
                            found,
                            prototypeMethods: Object.getOwnPropertyNames(Object.getPrototypeOf(candidate)).slice(0, 50)
                        });
                        if (nearMisses.length >= 5) break outer;
                    }
                } catch { }
            }
        }
        result.nearMisses = nearMisses;
    } catch (err: any) {
        result.scanError = String(err?.message ?? err);
    }

    return result;
});
