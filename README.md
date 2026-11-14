# call-audio-recorder

One keyboard shortcut starts and stops an audio recording of a videocall on Linux
(GNOME, PipeWire or PulseAudio): your microphone plus everything played by the
speakers or headphones. A red dot with the elapsed time sits in the top bar while
it records. When you stop, you get a clean, echo-free mix that is suitable for
transcription, plus the two separate tracks (microphone, speakers) in full quality.

## Motivation

I tried several ways to record calls with both my microphone and what comes out of
the speakers, including OBS and other recorders, and was not satisfied with any of
them. I only wanted the audio from all sources: no video, no scenes, no per-app
setup. And the simple approaches had an echo problem: the microphone also picks up
the remote voices played by the speakers, so summing "microphone + speaker output"
records the other side twice, the second time delayed and coloured by the room.

This tool records the two sources separately and removes the speaker signal from
the microphone track offline, with an echo canceller, before mixing them. The
result is my voice plus the clean digital copy of the remote side, and it works
correctly.

## How it works

1. **Capture.** `record-call.sh` asks `pactl` for the default source (microphone)
   and the default sink, and starts one `ffmpeg` process with two PulseAudio
   inputs: the microphone and the sink's monitor source (`<sink>.monitor`, a
   digital tap of what is being played). Both are recorded at 48 kHz, 16 bit, to
   separate FLAC files: `mic.flac` (mono, 80 Hz high-pass) and `speakers.flac`
   (stereo). Using a single process keeps the two tracks aligned in time.
2. **Echo cancellation.** After you stop, `aec_mix.py` decodes both tracks to
   48 kHz mono and runs the Speex acoustic echo canceller from `libspeexdsp`
   (loaded through `ctypes`, no Python packages needed) in 10 ms frames with a
   200 ms filter tail, followed by the Speex residual echo suppressor. The
   speaker track is the reference; the cleaned microphone is then summed with the
   speaker track and passed through a limiter, giving `mixed.flac`.
3. **Fallback.** If the Speex step fails (for example `libspeexdsp` is not
   installed), the mix is built with ffmpeg alone: the microphone is ducked by a
   sidechain compressor keyed on the speaker track, then summed with it. This is
   cruder (your voice is attenuated while the other side talks) but still avoids
   the doubled remote voice.
4. **Opus.** `mixed.flac` is encoded to mono Opus at 48 kbit/s (VBR, `voip`
   tuning), a small file that is convenient to transcribe or share.
5. **`info.txt`.** Each recording has an `info.txt` with the start and end time,
   the duration, the host name, the names and descriptions of the microphone, sink
   and monitor that were recorded, the ffmpeg exit status, the mixing method that
   was actually used (`mix=speex_aec` or `mix=sidechain_duck`), and the final
   paths of the FLAC folder and of the Opus file.

While recording, files are written to
`~/.local/share/call-recorder/in-progress/<stamp>/` and moved to their final place
only after the mix is built, so a synced folder never sees half-written files. If
something goes wrong, the raw tracks are still there.

The tool only reads audio. It does not change the volume, the default devices, or
any PulseAudio/PipeWire routing, and it does not load any module.

## Requirements

On Ubuntu or Debian:

```sh
sudo apt install ffmpeg pulseaudio-utils libspeexdsp1 python3 python3-gi \
    gir1.2-ayatanaappindicator3-0.1 gnome-shell-extension-appindicator
```

| Package | Used for |
| --- | --- |
| `ffmpeg` | capture, FLAC and Opus encoding, fallback mix |
| `pulseaudio-utils` | `pactl`, to find the default microphone and sink |
| `libspeexdsp1` | echo cancellation (optional, see the fallback above) |
| `python3` | echo cancellation and the tray icon |
| `python3-gi`, `gir1.2-ayatanaappindicator3-0.1` | the tray icon |
| `gnome-shell-extension-appindicator` | lets GNOME Shell display tray icons |

It works with PipeWire through its PulseAudio server (`pipewire-pulse`), which is
the default on current Ubuntu, Debian and Fedora, and with plain PulseAudio.

On GNOME the AppIndicator extension must be enabled (Ubuntu ships it enabled; on
Debian enable "AppIndicator and KStatusNotifierItem Support" in the Extensions
app). Optional: `libnotify-bin` (`notify-send`) for the "Recording saved"
notification, and `gnome-terminal` for the terminal mode.

## Install

```sh
git clone <repository-url> ~/call-audio-recorder
~/call-audio-recorder/record-call.sh --help
```

There is nothing to build. Keep the three scripts and the `icons/` folder together.

### Bind a keyboard shortcut (GNOME)

In the Settings application:

1. Open **Settings → Keyboard → Keyboard Shortcuts → View and Customise Shortcuts**.
2. Choose **Custom Shortcuts** and press **+**.
3. Name: `Call recorder`. Command: `/path/to/record-call.sh --launch` (use the
   absolute path). Shortcut: press for example `Ctrl+Alt+R`.

Or from a terminal:

```sh
SCHEMA=org.gnome.settings-daemon.plugins.media-keys
KEYPATH=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/call-recorder/

gsettings set "$SCHEMA.custom-keybinding:$KEYPATH" name 'Call recorder'
gsettings set "$SCHEMA.custom-keybinding:$KEYPATH" command "$HOME/call-audio-recorder/record-call.sh --launch"
gsettings set "$SCHEMA.custom-keybinding:$KEYPATH" binding '<Control><Alt>r'

# Register it. This list must also contain your existing custom shortcuts:
gsettings get "$SCHEMA" custom-keybindings
gsettings set "$SCHEMA" custom-keybindings "['$KEYPATH']"
```

If `gsettings get` shows other entries, include them in the list you set, otherwise
they are disabled.

## Usage

```sh
record-call.sh --launch       # tray icon; run it again to stop (use this for the shortcut)
record-call.sh                # record in the current terminal; Ctrl+C to stop
record-call.sh --terminal     # like --launch, but in a new terminal window
```

| Option | Meaning |
| --- | --- |
| `--launch` | Start recording with the tray icon. If a recording is already running, stop it instead. Falls back to `--terminal` when the tray libraries are missing. |
| `--terminal` | Same toggle behaviour, but the recording runs in a new `gnome-terminal` window that shows the status. |
| `--local-dir DIR` | Folder for the recordings. Default: `$CALL_REC_LOCAL_DIR`, or `~/Recordings/call-recorder`. |
| `--share-dir DIR` | Optional folder that receives only the mixed Opus file, for example a synced folder such as Dropbox or Nextcloud. Default: `$CALL_REC_SHARE_DIR`; if unset, there is no share folder. `--output-dir` is an alias. |
| `--duration N` | Stop automatically after `N` seconds (useful for testing). |
| `--headless` | No terminal interface. Used internally by the tray icon. |
| `-h`, `--help` | Show the help text. |

| Environment variable | Meaning |
| --- | --- |
| `CALL_REC_LOCAL_DIR` | Default for `--local-dir`. |
| `CALL_REC_SHARE_DIR` | Default for `--share-dir`. `CALL_REC_DIR` is accepted as an alias. |

A GNOME shortcut does not read your shell profile, so for the shortcut it is
simplest to put the options in the command itself, for example
`/path/to/record-call.sh --launch --share-dir /path/to/synced/folder`.

### Output

`<stamp>` is the start time, `YYYY-MM-DD_HH-MM-SS`.

```
~/Recordings/call-recorder/<stamp>/
    mixed.flac      echo-cancelled mix of microphone + speakers (mono)
    mic.flac        microphone only (mono)
    speakers.flac   speaker/headphone playback only (stereo)
    mixed.opus      compact copy of the mix
    info.txt        devices, times, mixing method
    ffmpeg.log      capture log
```

With a share folder, the Opus file is written there as `<share-dir>/<stamp>.opus`
instead of `mixed.opus`, and the FLAC tracks stay in the local folder only. If the
share folder cannot be written, the Opus file is kept in the local folder.

### Stopping

- Press the keyboard shortcut again (that is, run `record-call.sh --launch` again).
- Open the tray icon's menu and choose **Stop recording**.
- Middle-click the tray icon.
- In terminal mode, press `Ctrl+C`.

The icon shows `REC hh:mm:ss` while recording and `Saving…` while the mix is
built, which takes a few seconds for a short call and longer for a long one. A
desktop notification announces the saved file.

## Limitations and troubleshooting

- **Default devices at start time.** The recorder uses the microphone and the
  output device that are the defaults at the moment you start. Check the tray
  menu: it shows the names of both devices.
- **Switching devices mid-call.** If you change the output or the microphone
  during the call (for example by plugging in a headset), the recording keeps
  following the devices it started with and may miss part of the conversation.
  Stop and start again after switching.
- **Bluetooth headsets.** When the headset's own microphone is in use, Bluetooth
  switches to the hands-free profile (HFP/HSP), with low-quality mono audio in
  both directions. The recording captures what the system gets, so it will sound
  like that too. Using the laptop microphone, or a wired or USB headset, avoids
  this.
- **Headphones.** With headphones there is little or no echo to remove; the echo
  canceller is then harmless and the mix is simply both tracks summed.
- **No tray icon.** The icon needs AppIndicator support. If the Python bindings
  are missing, `--launch` opens a terminal window instead. If they are installed
  but the GNOME Shell extension is disabled, the recording still runs without a
  visible icon; press the shortcut again to stop it. The log of tray-mode
  recordings is `$XDG_RUNTIME_DIR/call-recorder/tray-recorder.log`.
- **"No monitor source for default sink".** The default output has no monitor
  source, so speaker audio cannot be captured; choose another output device.
- **Only one recording at a time.**
- **Consent.** Recording a call may require the consent of all participants,
  depending on where you and they are. Tell the participants that you are
  recording, and check the laws and policies that apply to you.

## License

MIT, see [LICENSE](LICENSE).
