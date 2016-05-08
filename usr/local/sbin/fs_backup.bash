#!/bin/bash -eu


declare -r -x PATH='~/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin';


source /etc/fs_backup.conf.bash

declare -r ORIGINAL_IFS="${IFS}";

declare -i DEBUG_MODE=0;
declare -i DRY_RUN=0; # whether this should be a real backup or just a test

declare -r BACKTICK='`';
declare -r SINGLEQUOTE="'";

declare -i BPS=-1;
declare -i COMP_LEVEL=-1;


declare -a -i PREV_BKS_TSS=();


declare BK_USER='';

declare -i TIMESTAMP=-1;
declare -A -i RSYNC_STATUSES=();
declare LOG_FILE='';
declare LOG_TARGET='';


declare SRC_HOST_DATA='';
declare SRC_HOST_NAME='';



# cheap and ugly variable names
declare TMP_1='';
declare TMP_2='';



declare MOUNTS_BUF='';
declare EX_PATHS_FLD='';

declare -a TMP_LIST=();
declare -a EXCLUDE_MPS=();
declare -a EXCLUDE_LIST=();
declare -a COMPARE_LIST=();
declare -a HOST_INFO=();
declare -a EX_PATHS_LST=();
declare -i MULTIPLE_COMPARES_SUPPORTED=-1;




function trim_str() {
# very rudimentary and inefficient (should use internal expansions)
	exec sed -r 's/^[\t ]+//g; s/[\t ]+$//g;';
}


function clean_exit() {
	rm -f "${BACKUPS_PATH}/syncing";
	rm -f "${LOCK_FILE}";
	exit 0;
}

	umask 0077;


	# let's be polite
	renice 19 ${$} 1>'/dev/null';
	ionice -c2 -n7 -p${$} 1>'/dev/null';

	# creating needed directories
	for TMP_1 in "${APP_HOME_PATH}" "${LOCK_PATH}" "${LOG_PATH}"; do
		[ -d "${TMP_1}" ] || mkdir -p "${TMP_1}";
	done;

	# determining if this is a dry run and or if we're running in debug mode. Crude and clanky way
	if [ ${#} -gt 0 ]; then
		for TMP_1 in "${@}"; do
			([ "${TMP_1}" == '-d' ] || [ "${TMP_1}" == '--debug' ]) && DEBUG_MODE=1;
			[ "${TMP_1}" == '--dry-run' ] && DRY_RUN=1;
		done;
	fi;

	# dry run always implies debug mode
	[ ${DRY_RUN} -ne 0 ] && DEBUG_MODE=1;


	# cleanup in case of healthy signals
	trap "clean_exit;" HUP INT TERM;
	

	# checking for lock file...
	if (! (set -o noclobber; exec 2>'/dev/null'; printf '%d' ${$} 1>"${LOCK_FILE}")); then
		printf 'ERROR: Stale lock file (%s) or another instance running\n' "${LOCK_FILE}" 1>&2;
		exit 3;
	fi;

	

	# this will prevent the script from picking the same timestamp on quick
	# subsequent invocations (the lockfile is already in place)
	usleep 1100000;

	TIMESTAMP="$(date --utc +'%Y%m%d%H%M%S')";

	LOG_FILE="${TIMESTAMP}.log";
	if [ ${DEBUG_MODE} -eq 0 ]; then
		LOG_TARGET="${LOG_PATH}/${LOG_FILE}";
		# creating empty log file just not to create a broken symlink
		printf '' 1>"${LOG_PATH}/${LOG_FILE}";
		ln -s -f "${LOG_FILE}" "${LOG_PATH}/latest.log";
	else
		# debug mode does not use log files
		LOG_TARGET='/dev/stderr';
	fi;

	(


		# bash doesn't keep signal handlers across forks..
		trap "clean_exit;" HUP INT TERM;
		
		[ ${DRY_RUN} -ne 0 ] && printf 'Dry run mode is set. No data changes will occur\n';

		# listig previous backups
		PREV_BKS_TSS=();
		pushd "${BACKUPS_PATH}" || clean_exit 3;
		# only directories (no symlinks) with a valid name are accepted
		for TMP_1 in *; do
			if [[ "${TMP_1}" =~ ^[0-9]{14}$ ]] && [ -d "${TMP_1}" ] && [ ! -h "${TMP_1}" ]; then
				PREV_BKS_TSS+=(${TMP_1});
			fi;
		done;
		popd;

		if [ ${DRY_RUN} -eq 0 ]; then
			while [ ${#PREV_BKS_TSS[@]} -gt $((VERSION_HISTORY_COUNT - 1)) ]; do
				printf 'No backup history slots available for the new backup (%d are available, %d are in use). Deleting the oldest backup (%s/%s)\n' \
					${VERSION_HISTORY_COUNT} \
					${#PREV_BKS_TSS[@]} \
					"${BACKUPS_PATH}" \
					"${PREV_BKS_TSS[0]}" \
				;
				(cd "${BACKUPS_PATH}" && exec rm -r -v "${PREV_BKS_TSS[0]}") | (
					declare -i DELETED_ITEMS_COUNT=0;
					TMP_LIST=();
					while readarray -n 100000 -O 0 -t TMP_LIST && [ ${#TMP_LIST[@]} -gt 0 ]; do
						DELETED_ITEMS_COUNT=$((DELETED_ITEMS_COUNT + ${#TMP_LIST[@]}));
						TMP_1="${TMP_LIST[@]: -1:1}"; TMP_1="${TMP_1#*${BACKTICK}}"; TMP_1="${TMP_1%${SINGLEQUOTE}*}";
						printf '\t%d items deleted so far (last was "%s")\n' ${DELETED_ITEMS_COUNT} "${TMP_1}";
						TMP_LIST=();
					done;
				);
				# dirty trick: delete the element 0 of the array and shift the whole thing
				unset PREV_BKS_TSS[0];
				# we regenerate the array to reset the indexes.
				# If we were thorough we would re-enumerate the directories: a big deal of time my have been elapsed
				# during the deletion and God knows what could have changed, but let's assume nobody mucks around
				# with the storage
				PREV_BKS_TSS=("${PREV_BKS_TSS[@]}");
			done;
		else
			printf 'Dry run mode: not deleting previous entries in the backup history\n';
		fi;


		# we refresh the time stamp after deletion
		TIMESTAMP="$(date --utc +'%Y%m%d%H%M%S')";


		if [ ${#PREV_BKS_TSS[@]} -gt 0 ]; then
			printf 'List of previous backup directories we will compare the source against: %s\n' "${PREV_BKS_TSS[*]}";
		else
			printf 'Could not identify any valid directory of last backup. This will be a full backup\n';
		fi;



		printf 'Backup directory: "%s"\n' "${TIMESTAMP}";


		# creating snapshot directory if it doesn't exist
		if [ ${DRY_RUN} -eq 0 ]; then

			([ -d "${BACKUPS_PATH}/${TIMESTAMP}" ] || exec mkdir -v "${BACKUPS_PATH}/${TIMESTAMP}") || clean_exit 3;

			# creating/updating the link to the "currently being updated" backup directory
			rm -f -v "${BACKUPS_PATH}/syncing" &&
			ln -s -v "${TIMESTAMP}" "${BACKUPS_PATH}/syncing" &&


			pushd "${BACKUPS_PATH}/${TIMESTAMP}" || exit 3;

		else

			printf 'Dry run mode: not creating/accessing the new backup directory\n';

		fi;




		for SRC_HOST_DATA in "${SRC_HOST_DATAS[@]}"; do

			# variables reset
			HOST_INFO=();

			SRC_HOST='';
			BPS=${DEFAULT_BPS};
			COMP_LEVEL=${DEFAULT_COMP_LEVEL};
			BK_PORT=22;
			BK_USER="${USER}";
			EX_PATHS_FLD=();
			EX_PATHS_LST=();
			COMPARE_LIST=();
			MULTIPLE_COMPARES_SUPPORTED=1;


			TMP_1="${IFS}"; IFS=':';
			read -r -a HOST_INFO <<<"${SRC_HOST_DATA}";
			IFS="${TMP_1}";

			SRC_HOST="${HOST_INFO[0]}";


			if [ ${#HOST_INFO[@]} -ge 2 ] && [[ ${HOST_INFO[1]} =~ ^[0-9]{1,12}$ ]]; then
				BK_PORT=${HOST_INFO[1]};
			fi;

			if [ ${#HOST_INFO[@]} -ge 3 ] && [[ "${HOST_INFO[2]}" =~ ^[0-9A-Za-z_\.-]{1,64}$ ]]; then
				BK_USER=${HOST_INFO[2]};
			fi;

			if [ ${#HOST_INFO[@]} -ge 4 ] && [[ ${HOST_INFO[3]} =~ ^[0-9]{1,12}$ ]]; then
				BPS=${HOST_INFO[3]};
			fi;

			if [ ${#HOST_INFO[@]} -ge 5 ] && ([[ ${HOST_INFO[4]} =~ ^[0-9]$ ]] || [ "${HOST_INFO[4]}" == '-1' ]); then
				COMP_LEVEL=${HOST_INFO[4]};
			fi;

			printf '\n';
			printf '\n';
			printf '\n';
			printf 'Processing server: %s\n' "${SRC_HOST}";
			#printf '\tName:% 48s\n' "${SRC_HOST}";
			printf '\tPort:% 48d\n' "${BK_PORT}";
			printf '\tUser:% 48s\n' "${BK_USER}";
			printf '\tBPS: % 48d\n' "${BPS}";

			# the following is a rather involved way of cleaning up and importing
			# path exclusion lists
			if [ ${#HOST_INFO[@]} -ge 6 ]; then

				# rudimentary form of trimming
				EX_PATHS_FLD="$(trim_str 0<<<"${HOST_INFO[5]}")";

				if [ "${EX_PATHS_FLD}" != '' ]; then
					TMP_1="${IFS}"; IFS='|';
					read -r -a TMP_LIST <<<"${EX_PATHS_FLD}";

					if [ ${#TMP_LIST[@]} -gt 0 ]; then

						for TMP_2 in "${TMP_LIST[@]}"; do

							# here I rewrite the same variable i derived the array from.
							# spurious, probably better than defining 52890183 variables...
							EX_PATHS_FLD="$(trim_str 0<<<"${TMP_2}")";
							
							if [ "${EX_PATHS_FLD}" != '' ]; then
								# the field is populated
								EX_PATHS_LST[${#EX_PATHS_LST[@]}]="${EX_PATHS_FLD}";
							fi;

						done;
						
					fi;

					IFS="${TMP_1}";
				fi;

			fi;



			EXCLUDE_MPS=();

			# adding basic entries to exclusion list
			EXCLUDE_MPS[${#EXCLUDE_MPS[@]}]='/proc/*';
			EXCLUDE_MPS[${#EXCLUDE_MPS[@]}]='/dev/*';
			EXCLUDE_MPS[${#EXCLUDE_MPS[@]}]='/sys/*';
			EXCLUDE_MPS[${#EXCLUDE_MPS[@]}]='/config/*';
			EXCLUDE_MPS[${#EXCLUDE_MPS[@]}]='*/lost+found';
			EXCLUDE_MPS[${#EXCLUDE_MPS[@]}]='/var/run/*';
			EXCLUDE_MPS[${#EXCLUDE_MPS[@]}]='/var/lock/*';
			EXCLUDE_MPS[${#EXCLUDE_MPS[@]}]='/tmp/*';
			EXCLUDE_MPS[${#EXCLUDE_MPS[@]}]='/var/tmp/*';
			EXCLUDE_MPS[${#EXCLUDE_MPS[@]}]='/mnt/tmp_sync/*';
			EXCLUDE_MPS[${#EXCLUDE_MPS[@]}]='/mnt/import/*';
			EXCLUDE_MPS[${#EXCLUDE_MPS[@]}]='/mnt/export/*';
			EXCLUDE_MPS[${#EXCLUDE_MPS[@]}]='/var/spool/squid/*';
			EXCLUDE_MPS[${#EXCLUDE_MPS[@]}]='*/app/oracle/product/*/*/log/*/ocssd.l*';


			# exclude all filesystems different from ext2, ext3, ext4 and reiserfs, reiser4. this is
			# a quick and dirty way to exclude network file system mounts (which are VERY dangerous in this context:
			# they may lead to an endless recursion if this volume is mounted on the remote machine)
			# in short: we want to backup only LOCAL filesystems

			MOUNTS_BUF="$(set +e; ssh -o 'BatchMode=yes' -p ${BK_PORT} -l "${BK_USER}" "${SRC_HOST}" 'cat /proc/mounts'; true)";
			# the rootfs entry must be excluded because it may lead to ambiguities
			for TMP_1 in $(cut -d '#' -f 1 <<<"${MOUNTS_BUF}" | grep -P -v '^\s*rootfs\s+/\s+rootfs\s+' | grep -P -v '\s+((ext[234]?)|(reiser((fs)|4)))\s+' | awk '{printf("%s ", $2);}';); do
				# let's avoid redundant entries in the list
				if (! [[ "${TMP_1}" =~ ^((/proc)|(/dev)|(/sys)|(/config))(/|$) ]]); then
					EXCLUDE_MPS+=("${TMP_1}");
				fi;
			done;


			# assembling the exclude list based on the fs-type based array +
			# the configuration-provided one
			EXCLUDE_LIST=();

			printf '\tPath exclusion list is:\n';
			for TMP_1 in "${EXCLUDE_MPS[@]}"; do
				EXCLUDE_LIST+=("--exclude=${TMP_1}");
				printf '\t\t%s\n' "${TMP_1}";
			done;
			if [ ${#EX_PATHS_LST[@]} -gt 0 ]; then
				for TMP_1 in "${EX_PATHS_LST[@]}"; do
					EXCLUDE_LIST+=("--exclude=${TMP_1}");
					printf '\t\t%s\n' "${TMP_1}";
				done;
			fi;


			# if the server supports multi comparison we do it
			if [ ${#HOST_INFO[@]} -ge 7 ] && [[ ${HOST_INFO[6]} =~ ^[0-9]{1,12}$ ]] && [ ${HOST_INFO[6]} -eq 0 ]; then
				MULTIPLE_COMPARES_SUPPORTED=0;
			fi;


			printf '\n';
			# assembling the compare list based on what previous backup directories actually contain this
			# host's backup
			printf 'The source rsync daemon does%s support multiple comparison directories.\n' "$([ ${MULTIPLE_COMPARES_SUPPORTED} -ne 0 ] || printf ' NOT')";
			printf '\n';
			if [ ${#PREV_BKS_TSS[@]} -gt 0 ]; then
				for TMP_1 in "${PREV_BKS_TSS[@]}"; do
					if [ -d "${BACKUPS_PATH}/${TMP_1}/${SRC_HOST}" ]; then
						if [ ${MULTIPLE_COMPARES_SUPPORTED} -ne 0 ]; then
							# we append the item to the array
							COMPARE_LIST+=("--link-dest=${BACKUPS_PATH}/${TMP_1}/${SRC_HOST}");
						else
							# we report that the previous item, if any, is not usable and replace
							# the only one in the array
							[ ${#COMPARE_LIST[@]} -gt 0 ] && printf '\t\tprevious backup directory "%s" cannot be used for comparison. Disregarding\n' "${COMPARE_LIST[0]#*=}";
							COMPARE_LIST=("--link-dest=${BACKUPS_PATH}/${TMP_1}/${SRC_HOST}");
						fi;
					fi;
				done;
				if [ ${#COMPARE_LIST[@]} -gt 0 ]; then
					printf '\tDestination comparison directories list is:\n';
					for TMP_1 in "${COMPARE_LIST[@]}"; do
						printf '\t\t%s %s\n' "${TMP_1#*=}";
					done;
				fi;
			else
				printf '\tNo previous backup directories to compare the data to to\n';
			fi;

			printf '\n';

			set +e; # individual rsync/install_super_nice_rsync invocations may fail

			if [ ${DRY_RUN} -eq 0 ]; then
				# install super_nice_rsync.bash on the source machine, if missing
				printf 'Installing/updating bash script for nice remote rsync...';
				ssh -p ${BK_PORT} "${BK_USER}@${SRC_HOST}" 'cat 1>"/usr/local/bin/super_nice_rsync.bash" && chmod 0700 "/usr/local/bin/super_nice_rsync.bash";' 0<<'SUPER_NICE_RSYNC'
#!/bin/bash -eu

declare -r -x PATH='/usr/local/bin:/usr/bin:/bin';

	if [ ${#} -gt 0 ]; then
		exec nice -n 19 ionice -c 2 -n 7 rsync "${@}";
	else
		exec nice -n 19 ionice -c 2 -n 7 rsync;
	fi;
SUPER_NICE_RSYNC

				if [ ${?} -eq 0 ]; then
					printf 'DONE';
				else
					printf 'FAIL';
				fi;

				printf '\n';
			else
				printf 'Dry run mode: skipping installation of low priority rsync wrapper\n';
			fi;


			(
				if [ ${DRY_RUN} -eq 0 ]; then
					printf 'Launching rsync...\n';
					set +u; # EXCLUDE_LIST and COMPARE_LIST may be empty
					exec rsync \
						$([ ${VERBOSE_MODE} -ne 0 ] && printf -- '--verbose') \
						$([ ${USE_CHECKSUMS} -ne 0 ] && printf -- '--checksum') \
						--recursive \
						--links \
						--relative \
						--hard-links \
						--perms \
						--executability \
						--owner \
						--group \
						--devices \
						--specials \
						--times \
						--rsync-path='/usr/local/bin/super_nice_rsync.bash' \
						--super \
						--rsh="ssh -p ${BK_PORT} -l '${BK_USER}' -o 'BatchMode=yes'" \
						--delete \
						--delete-after \
						--delete-excluded \
						--numeric-ids \
						$([ ${COMP_LEVEL} -ne 0 ] && printf -- '--compress' || printf '') \
						$([ ${COMP_LEVEL} -ge 1 ] && printf -- '--compress-level=%d' ${COMP_LEVEL} || printf '') \
						--stats \
						--bwlimit=$((BPS / 1024)) \
							"${EXCLUDE_LIST[@]}" \
							"${COMPARE_LIST[@]}" \
						"${SRC_HOST}:/" \
						"./${SRC_HOST}/" \
					;
				else
					printf 'Dry run mode: invoking dummy rsync command for server `%s`\n' "${SRC_HOST}";
					exit $((RANDOM / 1024));
				fi;
			) 2>&1 | (while read -r TMP_1; do printf '%s: %s\n' "${SRC_HOST}" "${TMP_1}"; done);

			RSYNC_STATUSES["${SRC_HOST}"]=${PIPESTATUS[0]};

			set -e;

			printf '\n';
			printf 'Done processing server %s\n' "${SRC_HOST}";
			printf '\n';
			printf '\n';
			printf '\n';
			printf '\n';

		done;


		if [ ${DRY_RUN} -eq 0 ]; then

			popd;
			# syncing is complete
			rm -f -v "${BACKUPS_PATH}/syncing"

			# create/update the link to the "freshest" backup directory
			rm -f -v "${BACKUPS_PATH}/latest";
			ln -s -v "${TIMESTAMP}" "${BACKUPS_PATH}/latest";

		else

			printf 'Dry run mode: not altering symlinks\n';

		fi;


		for TMP_1 in "${!RSYNC_STATUSES[@]}"; do
			printf '%s\t%d\n' "${TMP_1}" "${RSYNC_STATUSES["${TMP_1}"]}";
		done 1>"${HOSTS_STATUSES_FILE}";
		chmod 0644 "${HOSTS_STATUSES_FILE}";


		# do we want this subshell to ALWAYS succeed? Then uncomment the following...
		#true;

	) 2>&1 | awk '{printf("%s> %s\n", strftime("%Y-%m-%d %H:%M:%S", systime()), $0); fflush();}' 1>"${LOG_TARGET}";


	clean_exit;
