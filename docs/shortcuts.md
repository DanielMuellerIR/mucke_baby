# Shortcuts

Mucke, Baby! provides five native actions in macOS Shortcuts: play a saved radio station, stop radio, set volume, get the current track title, and bookmark the current track title. Actions use the same player and library as the windows and menu bar. They can run while the app is in the background. A title result contains the original broadcast metadata, including mix/version information.

Choose stations from the app’s enabled local stations. The saved identifier is the local UUID: renaming a station or repairing its URL keeps the shortcut valid. A deleted or disabled station produces an error. A shortcut cannot supply an arbitrary stream URL.

Volume accepts a finite number from 0 through 100, including fractions. It updates the app’s global volume; per-station correction and equalizer remain in effect. Values outside the range produce an error without changing volume.

Starting the already active station does not reconnect it. Starting another station is refused while recording is enabled: turn recording off in the app first. The action never enables recording or silently changes that preference. Stop closes radio and any active recording through the regular player cleanup. Title and bookmark actions report a useful error when no current title is available; a bookmark is reported as saved only after persistence succeeds. Bookmarking an existing title preserves its existing identity.

The deployment target remains macOS 14.2. Building requires Xcode’s Swift compiler, App Intents constant extraction data and `appintentsmetadataprocessor`. `build.sh` derives the extraction protocol list from the installed toolchain and places `Metadata.appintents` in bundle resources before signing. Build lists and compiler intermediates remain outside the bundle. `AppShortcuts.strings` localizes phrases; `Localizable.strings` contains action names, parameters, summaries and errors.
