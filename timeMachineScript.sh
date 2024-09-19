#!/bin/bash

# Enable the "exit on error" (this is used for exiting when the backup disk cannot be mounted).
set -e

# The UUID of the backup volume is the only input to this script.
# The script expects that either the backup volume is not encrypted or if it is encrypted,
# the password is stored in the keychain as a generic password with the UUID of the backup
# volume and can be accessed by the current user without a password prompt via
# `security -q find-generic-password -a $backupVolumeUUID -w`
backupVolumeUUID="your-backup-volume-uuid-goes-here"

# =========================================================== OPTIONS ===========================================================
# The script checks whether automatic backups are enabled and if the auto backup interval is
# less than or equal to the backupInterval variable, in which case, the script waits for
# the backup to start automatically. Otherwise, it starts a backup manually in auto mode.
backupInterval="3600" # in seconds (1 hour)

# The script will not start a backup if the current time is in between noBackupPeriodBegin and noBackupPeriodEnd.
noBackupPeriodBegin="23:00"
noBackupPeriodEnd="09:00"

# ====================================================== UTILITY FUNCTIONS ======================================================
# Function to determine if the backup should be started manually
should_start_backup_manually() {
    local backupInterval=$1

    local isAutoBackupEnabled=$(defaults read /Library/Preferences/com.apple.TimeMachine.plist AutoBackup)
    if [ "$isAutoBackupEnabled" = "0" ]; then
        echo 1
    else
        local autoBackupInterval=$(defaults read /Library/Preferences/com.apple.TimeMachine.plist AutoBackupInterval)
        if [ "$autoBackupInterval" -gt "$backupInterval" ]; then
            echo 1
        else
            echo 0
        fi
    fi
}

# Function to get backup device information (defines global variables backupDeviceIdentifier, backupVolumeName, backupPhysicalStore)
get_backup_device_info() {
    local backupVolumeUUID=$1

    backupDeviceIdentifier=$(diskutil info $backupVolumeUUID | awk 'BEGIN{FS=":";}/Device Identifier:/{printf $NF}END{printf "\n"};' | xargs)
    backupVolumeName=$(diskutil info $backupVolumeUUID | awk 'BEGIN{FS=":";}/Volume Name:/{print $NF}END{printf "\n"};' | xargs)
    backupPhysicalStore=$(diskutil info $backupVolumeUUID | awk 'BEGIN{FS=":";}/APFS Physical Store:/{print $NF}END{printf "\n"};' | xargs)

    echo "   Backup Volume UUID:         $backupVolumeUUID"
    echo "   Backup Device Identifier:   $backupDeviceIdentifier"
    echo "   Backup Volume Name:         $backupVolumeName"
    echo "   Backup APFS Physical Store: $backupPhysicalStore"
}

# Function to check if the current time is within the no-backup period (it exits with 0 if during no-backup period)
check_no_backup_period() {
    local currentHourMinute=$(date +%H:%M)
    if [[ "$currentHourMinute" > "$noBackupPeriodBegin" ]] || [[ "$currentHourMinute" < "$noBackupPeriodEnd" ]]; then
        echo "It is too late to run a backup, move along, nothing to see here. Current time ($currentHourMinute) is in between $noBackupPeriodBegin and $noBackupPeriodEnd."
        exit 0
    fi
}

# Function to check if the backup volume is mounted and mount it if it is not (it exits with error if the disk cannot be mounted)
check_and_mount_backup_volume() {
    local backupVolumeName=$1
    local backupDeviceIdentifier=$2
    local backupVolumeUUID=$3

    # Check if backup volume is mounted, and mount it if it is not the case
    if ! mount | grep -q "/Volumes/$backupVolumeName"; then
        check_no_backup_period # Check if the current time is within the no-backup period

        echo "Backup Volume '$backupVolumeName' is not mounted. Need to mount the backup volume."
        if diskutil info $backupDeviceIdentifier | grep 'Locked:\s*Yes'; then
            local backupVolumePassword=$(security -q find-generic-password -a $backupVolumeUUID -w | xxd -p -r | rev | cut -c 1- | rev)
            diskutil quiet apfs unlockVolume $backupDeviceIdentifier -user $backupVolumeUUID -passphrase $backupVolumePassword
        else
            # Disk is either not encrypted or it is unlocked at the moment, mount it directly
            diskutil quiet mount $backupDeviceIdentifier
        fi
        echo "Waiting 5 seconds to make sure the disk is accessible."
        sleep 5 # it takes some time for the disk to be accessible after a restart or a mount
    else
        echo "Backup Volume '$backupVolumeName' is already mounted."
    fi
}

# Function to calculate the seconds since the last backup (defines a global variable secondsSinceLastBackup)
calculate_seconds_since_last_backup() {
    # Get current timestamp
    local currentTimestamp=$(date "+%s")
    echo "   Current time (timestamp): $(date "+%Y-%m-%d %H:%M:%S") ($currentTimestamp)"

    # Get the latest backup time
    local latestBackupTime=$(tmutil latestbackup | xargs -I {} basename -s .backup {} | cut -d '-' -f 1-4)
    latestBackupTime=${latestBackupTime:-"1970-01-01-010000"}
    latestBackupTime=$(date -j -f "%Y-%m-%d-%H%M%S" $latestBackupTime "+%Y-%m-%d %H:%M:%S")
    local latestBackupTimestamp=$(date -j -f "%Y-%m-%d %H:%M:%S" "$latestBackupTime" "+%s") # -j is for parsing the input date
    echo "   Latest backup time (timestamp): $latestBackupTime ($latestBackupTimestamp)"

    # Calculate the difference in seconds
    secondsSinceLastBackup=$((currentTimestamp - latestBackupTimestamp))
}

# Function to wait for the backup to complete if there is any in progress
wait_for_backup_to_complete_if_in_progress() {
    local tmutil_currentphase=$(tmutil currentphase)
    while [ "$tmutil_currentphase" != "BackupNotRunning" ]; do
        local rawPercentCompleted=$(tmutil status | grep _raw_Percent | xargs | sed -e 's/[^0-9.]*//g')
        local fractionOfProgressBar=$(tmutil status | grep FractionOfProgressBar | xargs | sed -e 's/[^0-9.]*//g')

        rawPercentCompleted=${rawPercentCompleted:-0}
        fractionOfProgressBar=${fractionOfProgressBar:-1}

        local percentCompleted=$(awk "BEGIN {print $rawPercentCompleted/$fractionOfProgressBar}")

        # timeRemaining info of tmutil is not accurate at all
        # local timeRemaining=$(tmutil status | grep TimeRemaining | xargs | sed -e 's/[^0-9.]*//g')
        local timeRemaining=40

        # multiply the remaining time with a factor to make it more acceptable
        local sleepDuration=$(awk "BEGIN {print (1-($percentCompleted))*$timeRemaining}")
        # Don't let the sleep duration be greater than sleepDurationLimit seconds (time machine time estimation is very unreliable)
        local sleepDurationLimit=60
        sleepDuration=$(awk -v n1="$sleepDuration" -v limit="$sleepDurationLimit" 'BEGIN {print (n1<limit)?n1:limit}')

        if [ "$tmutil_currentphase" = "ThinningPostBackup" ]; then
            sleepDuration=5
            echo "    Backup is almost finished tmutil_currentphase=$tmutil_currentphase, will check again in $sleepDuration seconds."
        else
            echo "    A backup is still in progress with tmutil_currentphase=$tmutil_currentphase ($percentCompleted completed), will check again in $sleepDuration seconds."
        fi

        sleep $sleepDuration

        tmutil_currentphase=$(tmutil currentphase)
        if [ "$tmutil_currentphase" = "BackupNotRunning" ]; then
            echo "   Backup is finished, tmutil_currentphase is now $tmutil_currentphase. Waiting a second to make sure the disk ops are settled down."
            sleep 1
        fi
    done
}

# Function to check the time since the last backup and start or wait for a new backup if necessary (defines a global variable secondsSinceLastBackup)
check_and_backup_if_needed() {
    local backupInterval=$1

    calculate_seconds_since_last_backup

    if [[ $secondsSinceLastBackup -lt $backupInterval ]]; then
        echo "A backup was completed $secondsSinceLastBackup seconds ago (< $backupInterval), will check the next time this script is triggered."
    else
        echo "No backup has been completed since $secondsSinceLastBackup seconds (>= $backupInterval), will wait for the backup to start."
        tmutil_currentphase=$(tmutil currentphase)
        if [ $tmutil_currentphase = "BackupNotRunning" ]; then
            # If auto backup is disabled or the frequency is low, start the backup manually in "auto" mode
            if [ $(should_start_backup_manually "$backupInterval") = "1" ]; then
                tmutil startbackup --auto
            fi

            while [ $tmutil_currentphase = "BackupNotRunning" ]; do
                waitDuration=30
                echo "    Waiting for backup to start (tmutil_currentphase is $tmutil_currentphase) for $waitDuration seconds." # it takes a few seconds for auto backup to kick-in
                sleep $waitDuration
                tmutil_currentphase=$(tmutil currentphase)
            done
            echo "   Backup has started (tmutil_currentphase is now $tmutil_currentphase)."
        else
            echo "   A backup is already in progress (tmutil_currentphase is $tmutil_currentphase)."
        fi
    fi

    wait_for_backup_to_complete_if_in_progress
}

# Function to unmount and eject the backup disk
unmount_and_eject_backup_disk() {
    local backupVolumeUUID=$1
    local backupDeviceIdentifier=$2
    local backupPhysicalStore=$3
    local backupVolumeName=$4

    # Don't exit immediately on error and go on with the disk eject sequence
    set +e

    # timemachine snapshots are sometimes mounted for some reason.. unmount such snapshots first
    mount | grep $backupVolumeUUID | cut -d ' ' -f 3 | xargs -I{} sh -c "diskutil quiet unmount '{}' || diskutil unmount force '{}'"

    # You should specify a whole disk, but all volumes of the whole disk are attempted to be unmounted even if you specify a partition.
    diskutil quiet unmountDisk $backupDeviceIdentifier || diskutil unmountDisk force $backupDeviceIdentifier
    diskutil quiet unmountDisk $backupPhysicalStore || diskutil unmountDisk force $backupPhysicalStore

    # And then eject the disk
    { hdiutil detach -quiet "$backupDeviceIdentifier" || hdiutil detach -force -debug -verbose "$backupDeviceIdentifier"; } && echo "Backup disk '$backupVolumeName' is ejected."
}

# ========================================================== MAIN SCRIPT ==========================================================

echo "================================================================================"
echo "timeMachineScript.sh is launched."

get_backup_device_info "$backupVolumeUUID"

check_and_mount_backup_volume "$backupVolumeName" "$backupDeviceIdentifier" "$backupVolumeUUID"

check_and_backup_if_needed "$backupInterval"

unmount_and_eject_backup_disk "$backupVolumeUUID" "$backupDeviceIdentifier" "$backupPhysicalStore" "$backupVolumeName"

echo "================================================================================"
