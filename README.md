# auto-eject-time-machine
A simple set of steps to create a simple script that is run each time a disk is mounted, at login and at regular intervals to automatically eject the TimeMachine disk (waiting for the backup to be completed if necessary).

The script is triggered after a new mount and at login so that if the backup disk is plugged between scheduled interval, the script can still check whether it has been more than backupInterval (3600 seconds) and wait for the backup to finish if necessary and eject the disk. (This is useful if your setup is so that your backup disk is mounted automatically when you plug in your laptop. Otherwise, the disk stays mounted until the script is launched next time.)

The script assumes that if auto backups are enabled, the auto backup interval is compatible with `backupInterval` parameter of the script. If auto backups are disabled or if they are enabled but the auto backup interval of Time Machine is greater than the `backupInterval` parameter, then the script manually triggers backups every `backupInterval` seconds.

The script assumes that either the backup disk is not encrypted or the encryption password is stored in the keychain as a generic password with the UUID of the backup volume and it can be accessed by the current user without a password prompt via `security -q find-generic-password -a $backupVolumeUUID -w` -- you can give permission at the password prompt. `security` binary will ask permission to access this login item. Basically the script queries the password of the backup disk so that it can mount the encrypted disk.

*Why?* I hate having to remember doing it manually, and have corrupted a hard-drive by removing it physically without ejecting it first.

## Setup Instructions

### `timeMachineScript.sh`:
1. Change line 11: use the UUID of your backup volume (Assuming the back up disk is mounted and named as "Backups of ..." -- `diskutil list | grep "Backups of" | awk '{print $NF}' | xargs  diskutil info | grep "Volume UUID:"` command can be used to display the UUID of the backup disk).
1. (optional) Modify line 17 if you like to change the back up frequency (Adjust StartInterval accordingly in the next section).
1. (optional) Modify lines 20 and 21 if you like to skip the backup during certain time periods.
1. Run `chmod +x timeMachineScript.sh`.
1. Move the script to a location of your choice (e.g. `~/bin/timeMachineScript.sh`).
1. (`tmutil latestbackup` command requires Full Disk Access privileges) Give `timeMachineScript.sh` Full Disk Access rights by opening the System Settings > Privacy & Security > Full Disk Access window and dragging & dropping the `timeMachineScript.sh` file into it.
1. (If the disk is encrypted `security` command requires permission to access the keychain)

### `local.username.timeMachineScript.plist`:
Use your Mac username to rename this file (e.g. `local.halilsen.timeMachineScript.plist`) and wherever you see `username` down below.

1. Change line 6  (Label): match the filename
1. Change line 11 (ProgramArguments): use the path to the bash script chosen for `timeMachineScript.sh` (e.g. `~/bin/timeMachineScript.sh`)
1. (optional) Change line 14 (StartOnMount): if you don't want/need the script to be triggered each time a disk is mounted.
1. (optional) Change line 16 (StartInterval): if you want/need the script to be triggered more or less frequently. 55% of the `backupInterval` works great.
1. (optional) Change line 18 (RunAtLoad): if you don't want/need the script to be triggered at login.
1. (optional) Modify lines 20 and 22 to your liking or remove lines 19 through 22 altogether if you don't want logging
1. Move the file to `/Users/username/Library/LaunchAgents`
1. To start the script, run `launchctl load -w ~/Library/LaunchAgents/local.username.timeMachineScript.plist`
1. To stop the script, run `launchctl unload -w ~/Library/LaunchAgents/local.username.timeMachineScript.plist`

DISCLAIMER: Use it at your own risk.
