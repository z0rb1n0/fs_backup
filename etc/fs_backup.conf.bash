#!/bin/bash -eu

declare -r BACKUPS_PATH='/geoop_backup/files';
declare -r APP_HOME_PATH="${HOME}/.fs_backup";
declare -r LOCK_PATH="${APP_HOME_PATH}/run";
declare -r LOCK_FILE="${LOCK_PATH}/fs_backup.lock";
declare -r LOG_PATH="${APP_HOME_PATH}/log";
declare -r HOSTS_STATUSES_FILE='/var/log/fs_backup_hosts_statuses';


declare -i BK_PORT=22;

# if you enable this one, it is gonna be taxing on the
# remote machines, but it's also a crude way to detect data
# errors in the remote file system (by reading all the files),
# plus it's 100% resilient to changes on files
# (such as when people "touch" files back to the past
# for whatever reason)
declare -r -i USE_CHECKSUMS=0;
declare -r -i VERBOSE_MODE=1;

declare -r -i DEFAULT_BPS=2097152; # 0 for no limit
declare -r -i DEFAULT_COMP_LEVEL=9;

declare -r -i VERSION_HISTORY_COUNT=18; # how many entries we want to keep in the history. up to 20

# fields (colon-separated) are...

# 0: hostname/IP to backup
# 1: TCP port (default 22)
# 2: login name (default: current user)
# 3: maximum bandwidth (leave empty to stick with the default)
# 4: compression level. 0 disables compression. if omitted the parameter is not passed to rsync (internally -1)
# 5: pipe-separated list of exclusion patterns you don't want to backup
#    (passed to rsync as they are. rsync understands globs, so * and ? wildcards should work)
# 6: flag indicating that the server supports multiple --compare-dest, --copy-dest and --link-dest arguments (protol level 29 or higher).
#    (defaults to true)

# WARNING 1!!! Self-backup first: the first entry is this very host. Carefully plan path exclusions in order to avoid circular loop bombs
# WARNING 2!!! Rsync on some old RHEL releases (I.E. wildcat and bodev) doesn't support --compress-level or multiple comparison directories, so disable those features for those entries



# devsyslog-0 re enabled by Fabio: it is not a problem if we backup the machine during rotation/compression.
# please move entries out of the array declaration before commenting as comments impair multi-line processing
declare -a SRC_HOST_DATAS=( \
	'host.to.backup:22:root:::/exclude_files_in_this_path/*|/and_this_whole_path:' \
);

