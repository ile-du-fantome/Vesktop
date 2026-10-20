/*
 * Vesktop, a desktop app aiming to give you a snappier Discord Experience
 * Copyright (c) 2026 Vendicated and Vesktop contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { Logger } from "@vencord/types/utils";
import { waitFor } from "@vencord/types/webpack";
import { IpcCommands } from "shared/IpcEvents";

import { onIpcCommand } from "./ipcCommands";

const logger = new Logger("VesktopActions");

interface KeyBindAction {
    onTrigger(...args: any[]): void;
    isPressed?: boolean;
}

let keyBindActions: Record<string, KeyBindAction> | undefined;

waitFor(["dispatch", "subscribe"], FluxDispatcher => {
    FluxDispatcher.subscribe("KEYBINDS_REGISTER_GLOBAL_KEYBIND_ACTIONS", event => {
        keyBindActions = (event as { keybinds: Record<string, KeyBindAction> }).keybinds;
    });
});

function getKeyBindAction(name: string): KeyBindAction {
    const action = keyBindActions?.[name];
    if (!action) throw new Error(`Discord keybind action ${name} is not available`);
    return action;
}

/**
 * Actions handled by Discord's global keybind action registry. The main
 * process routes run-shortcut actions here when it cannot handle them itself.
 */
function handleAction(action: string) {
    logger.debug(`Handling action: ${action}`);

    switch (action) {
        case "toggleDeafen":
            getKeyBindAction("TOGGLE_DEAFEN").onTrigger();
            return;

        case "toggleStreamerMode":
            getKeyBindAction("TOGGLE_STREAMER_MODE").onTrigger();
            return;

        case "disconnectFromVoiceChannel":
            getKeyBindAction("DISCONNECT_FROM_VOICE_CHANNEL").onTrigger();
            return;

        case "pushToTalkNormalStart":
        case "pushToTalkNormalStop":
        case "pushToTalkNormalToggle": {
            const ptt = getKeyBindAction("PUSH_TO_TALK");
            const isPressed = action.includes("Toggle") ? !ptt.isPressed : action.includes("Start");
            ptt.onTrigger(isPressed, "default");
            return;
        }

        default:
            throw new Error(`Unknown action: ${action}`);
    }
}

onIpcCommand(IpcCommands.KEY_BINDS_HANDLE, handleAction);
