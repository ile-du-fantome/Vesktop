#!/usr/bin/env bash

# Push-to-talk helpers for a Jay [complex-shortcuts] binding.
#
# The press action remembers whether the microphone was muted, unmutes it, and
# (optionally) attenuates the default audio sink. The release action restores
# the microphone's original mute state, restores the remembered volume, and
# notifies Vesktop over its control socket.
#
# This file can be used in two ways:
#
#   * Execute it from Jay:  ptt.sh press  /  ptt.sh release
#   * Source it from bash: . ~/.local/bin/ptt.sh

# Audio categories whose volume is attenuated while the PTT key is held.
# 1.0 leaves the volume untouched. Add entries for other output types.
#
# Example:
#
# [headphones]=0.75
#
# Categories not listed use PTT_ATTENUATION_DEFAULT.
declare -A PTT_ATTENUATION=(
    [speakers]=0.5
)
PTT_ATTENUATION_DEFAULT=1.0

# File remembering the pre-attenuation sink id and volume between press and
# release.
_PTT_STATE_FILE="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/vesktop-ptt-sink-volume"

# File remembering whether the microphone was muted when the button was pressed,
# so release only re-mutes a microphone that press unmuted.
_PTT_SOURCE_STATE_FILE="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/vesktop-ptt-source-muted"

# Vesktop control socket provided by the PTT fork.
_PTT_VESKTOP_SOCK="${XDG_RUNTIME_DIR:-/tmp}/vesktop.sock"
_PTT_VESKTOP_START="run-shortcut:pushToTalkKeyStart"
_PTT_VESKTOP_STOP="run-shortcut:pushToTalkKeyStop"

# Print the output category of the current default audio sink:
# speakers, headphones, headset, hdmi, or unknown.
_ptt_sink_category() {
    local dev_id route_info port form_factor icon

    if ! command -v wpctl >/dev/null 2>&1; then
        printf 'Warning: wpctl not found; not attenuating output volume\n' >&2
        printf 'unknown\n'
        return 1
    fi

    # The active output route of the default sink's device names the port in
    # use, such as analog-output-lineout or analog-output-headphones.
    dev_id=$(wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null |
        awk -F'"' '/device\.id/ { print $2; exit }')
    if [ -n "$dev_id" ] && command -v pw-dump >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        route_info=$(pw-dump "$dev_id" 2>/dev/null | jq -r '
            .[0] as $d
            | [ (([ $d.info.params.Route[]? | select(.direction == "Output") | .name ] | first) // ""),
                ($d.info.props["device.form-factor"] // ""),
                ($d.info.props["device.icon-name"] // "") ]
            | join("|")' 2>/dev/null)
        # "|" never appears in these names, and as a non-whitespace IFS
        # character it preserves empty fields.
        IFS='|' read -r port form_factor icon <<< "$route_info"
    fi

    case $port in
        # External speakers are often plugged into line out.
        analog-output-lineout | analog-output-speaker*) printf 'speakers\n'; return 0 ;;
        *headphone*) printf 'headphones\n'; return 0 ;;
        *headset*) printf 'headset\n'; return 0 ;;
        hdmi-*) printf 'hdmi\n'; return 0 ;;
    esac
    # Bluetooth devices expose their type as a form factor rather than a port.
    case $form_factor in
        speaker) printf 'speakers\n'; return 0 ;;
        headphone) printf 'headphones\n'; return 0 ;;
        headset | hands-free) printf 'headset\n'; return 0 ;;
    esac
    case $icon in
        *speaker*) printf 'speakers\n'; return 0 ;;
        *headphone*) printf 'headphones\n'; return 0 ;;
        *headset*) printf 'headset\n'; return 0 ;;
    esac
    printf 'unknown\n'
}

# Print 1 if the default audio source is muted, 0 otherwise.
_ptt_source_muted() {
    local volume
    volume=$(wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>/dev/null) || return 1
    [ -n "$volume" ] || return 1
    case $volume in
        *'[MUTED]'*) printf '1\n' ;;
        *) printf '0\n' ;;
    esac
}

# Remember whether the microphone was muted before ptt_press unmutes it.
_ptt_remember_source() {
    # A previous press is still in effect; keep its remembered original state.
    [ -f "$_PTT_SOURCE_STATE_FILE" ] && return 0
    local muted
    # If the state cannot be read, assume it was muted, matching the old
    # unconditional re-mute behavior.
    muted=$(_ptt_source_muted) || muted=1
    printf '%s\n' "$muted" > "$_PTT_SOURCE_STATE_FILE"
}

# Restore the microphone mute state remembered by _ptt_remember_source, if any.
_ptt_restore_source() {
    local muted=1
    if [ -f "$_PTT_SOURCE_STATE_FILE" ]; then
        read -r muted < "$_PTT_SOURCE_STATE_FILE"
        rm -f "$_PTT_SOURCE_STATE_FILE"
    fi
    if [ "$muted" = 1 ] && command -v wpctl >/dev/null 2>&1; then
        wpctl set-mute @DEFAULT_AUDIO_SOURCE@ 1
    fi
}

# Attenuate the default sink's volume by its category's factor, remembering the
# original volume for ptt_release.
_ptt_attenuate() {
    local category factor sink_id volume attenuated

    category=$(_ptt_sink_category)
    factor=${PTT_ATTENUATION[$category]:-$PTT_ATTENUATION_DEFAULT}
    # Compare the factor with awk.
    if awk -v f="$factor" 'BEGIN { exit !(f >= 1) }'; then
        return 0
    fi

    # A previous press is still in effect. Keep its remembered original volume.
    [ -f "$_PTT_STATE_FILE" ] && return 0

    sink_id=$(wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null |
        awk 'NR == 1 { gsub(/,/, "", $2); print $2 }')
    if [ -z "$sink_id" ]; then
        printf 'Warning: could not determine default sink id; not attenuating output volume\n' >&2
        return 1
    fi
    volume=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null)   # "Volume: 0.80 [MUTED]"
    volume=${volume#Volume: }
    volume=${volume%% *}
    if [ -z "$volume" ]; then
        printf 'Warning: could not read default sink volume; not attenuating output volume\n' >&2
        return 1
    fi

    # Remember the original before attenuating so ptt_release can restore it.
    printf '%s %s\n' "$sink_id" "$volume" > "$_PTT_STATE_FILE" || return 1

    attenuated=$(awk -v v="$volume" -v f="$factor" 'BEGIN { printf "%.3f", v * f }')
    wpctl set-volume "$sink_id" "$attenuated" 2>/dev/null
}

# Restore the volume remembered by _ptt_attenuate, if any.
_ptt_restore() {
    [ -f "$_PTT_STATE_FILE" ] || return 0
    local sink_id volume
    read -r sink_id volume < "$_PTT_STATE_FILE"
    rm -f "$_PTT_STATE_FILE"
    [ -n "$sink_id" ] && [ -n "$volume" ] || return 1
    # Target the remembered sink id, not @DEFAULT_AUDIO_SINK@, in case the
    # default changed while the button was held. Ignore errors if it's gone.
    wpctl set-volume "$sink_id" "$volume" 2>/dev/null
}

# Send a command to a running Vesktop instance. Silently does nothing when
# Vesktop (or its socket) is not running.
_ptt_vesktop() {
    [ -S "$_PTT_VESKTOP_SOCK" ] || return 0
    printf '%s\n' "$1" | nc -N -U -- "$_PTT_VESKTOP_SOCK" >/dev/null 2>&1
}

ptt_press() {
    if command -v wpctl >/dev/null 2>&1; then
        _ptt_remember_source
        wpctl set-mute @DEFAULT_AUDIO_SOURCE@ 0
    fi
    _ptt_vesktop "$_PTT_VESKTOP_START" &
    _ptt_attenuate
}

ptt_release() {
    _ptt_vesktop "$_PTT_VESKTOP_STOP" &
    _ptt_restore_source
    _ptt_restore
}

# Run directly from Jay; do nothing when sourced from ~/.bashrc.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case ${1:-} in
        press) ptt_press ;;
        release) ptt_release ;;
        *)
            printf 'Usage: %s press|release\n' "$0" >&2
            exit 2
            ;;
    esac
fi
