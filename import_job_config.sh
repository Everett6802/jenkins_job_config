#!/bin/sh
# Restore Jenkins Job/Folder config.xml files from an exported jobs tree.
# Run against a stopped Jenkins controller. Dry-run is the default.
set -eu

usage() {
    echo "Usage: $0 --src SOURCE_JOBS_DIR --dst JENKINS_JOBS_DIR [--apply] [--overwrite] [--backup-dir BACKUP_DIR] [--allow-empty]" >&2
}

SOURCE=
TARGET=
BACKUP_DIR=
APPLY=0
OVERWRITE=0
ALLOW_EMPTY=0
MODE=import

while [ "$#" -gt 0 ]; do
    case "$1" in
        --src|--dst|--backup-dir)
            if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                echo "ERROR: $1 requires a path" >&2
                usage
                exit 1
            fi
            case "$1" in
                --src) SOURCE=$2 ;;
                --dst) TARGET=$2 ;;
                --backup-dir) BACKUP_DIR=$2 ;;
            esac
            shift 2
            ;;
        --allow-empty) ALLOW_EMPTY=1; shift ;;
        --dry-run) APPLY=0; shift ;;
        --apply) APPLY=1; shift ;;
        --overwrite) OVERWRITE=1; shift ;;
        *) echo "ERROR: Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

if [ -z "$SOURCE" ] || [ -z "$TARGET" ]; then usage; exit 1; fi
if [ ! -d "$SOURCE" ] || [ -L "$SOURCE" ]; then
    echo "ERROR: Invalid source directory: $SOURCE" >&2
    exit 1
fi
if [ -L "$TARGET" ]; then
    echo "ERROR: Destination is a symbolic link: $TARGET" >&2
    exit 1
fi
if [ -e "$TARGET" ] && [ ! -d "$TARGET" ]; then
    echo "ERROR: Destination is not a directory: $TARGET" >&2
    exit 1
fi
if [ "$MODE" = import ] && [ "$APPLY" -eq 1 ] && [ -z "$BACKUP_DIR" ]; then
    echo "ERROR: Import --apply requires --backup-dir (also backs up deleted Jobs)" >&2
    exit 1
fi
if [ -n "$BACKUP_DIR" ]; then
    if [ -z "$BACKUP_DIR" ]; then
        echo "ERROR: --overwrite requires --backup-dir" >&2
        exit 1
    fi
    if [ -L "$BACKUP_DIR" ] || { [ -e "$BACKUP_DIR" ] && [ ! -d "$BACKUP_DIR" ]; }; then
        echo "ERROR: Invalid backup directory: $BACKUP_DIR" >&2
        exit 1
    fi
fi

# Require a physically distinct source, destination and backup root.
# Canonicalize existing source; destination parent must exist (normal for Jenkins data volume).
SOURCE=$(cd "$SOURCE" && pwd -P)
if [ ! -d "$TARGET" ]; then
    echo "ERROR: Target directory does not exist: $TARGET" >&2
    exit 1
fi
TARGET=$(cd "$TARGET" && pwd -P)
case "$TARGET/" in
    "$SOURCE/"|"$SOURCE/"*) echo "ERROR: Target cannot be inside source" >&2; exit 1 ;;
esac
case "$SOURCE/" in
    "$TARGET/"*) echo "ERROR: Source cannot be inside target" >&2; exit 1 ;;
esac
if [ -n "$BACKUP_DIR" ]; then
    # Backup directory must already exist, to enable realpath resolution without side effects.
    if [ ! -d "$BACKUP_DIR" ]; then
        echo "ERROR: Create a separate backup directory before using --overwrite: $BACKUP_DIR" >&2
        exit 1
    fi
    BACKUP_DIR=$(cd "$BACKUP_DIR" && pwd -P)
    case "$BACKUP_DIR/" in
        "$TARGET/"|"$TARGET/"*|"$SOURCE/"|"$SOURCE/"*)
            echo "ERROR: Backup directory must be outside source and target" >&2
            exit 1 
			;;
    esac
    case "$TARGET/" in 
		"$BACKUP_DIR/"*) 
			echo "ERROR: Target cannot be within backup directory" >&2; 
			exit 1 
			;; 
	esac
    case "$SOURCE/" in 
		"$BACKUP_DIR/"*) 
			echo "ERROR: Source cannot be within backup directory" >&2; 
			exit 1 
			;; 
	esac
fi

# Reject unsafe/incomplete trees instead of treating unreadable Jobs as absent.
fail() { echo "ERROR: $*" >&2; exit 1; }
validate_tree() (
    tree=$1
    [ ! -L "$tree" ] && [ -r "$tree" ] && [ -x "$tree" ] || fail "Invalid jobs directory: $tree"
    for item in "$tree"/* "$tree"/.[!.]* "$tree"/..?*; do
        [ -e "$item" ] || [ -L "$item" ] || continue
        [ ! -L "$item" ] || fail "Symlink in jobs tree: $item"
        [ -d "$item" ] || fail "Unexpected entry in jobs directory: $item"
        [ -f "$item/config.xml" ] && [ ! -L "$item/config.xml" ] && [ -r "$item/config.xml" ] && [ -s "$item/config.xml" ] || fail "Missing/invalid config.xml: $item"
        case "${item##*/}" in .*) fail "Hidden Job names are unsupported: $item" ;; esac
        if [ -e "$item/jobs" ] || [ -L "$item/jobs" ]; then
            [ -d "$item/jobs" ] || fail "Invalid nested jobs directory: $item/jobs"
            validate_tree "$item/jobs"
        fi
    done
)
validate_tree "$SOURCE"
validate_tree "$TARGET"
[ "$SOURCE" != / ] && [ "$TARGET" != / ] || fail "Filesystem root cannot be a jobs directory"
found=0
for item in "$SOURCE"/*; do
    if [ -f "$item/config.xml" ]; then found=1; break; fi
done
[ "$found" -eq 1 ] || [ "$ALLOW_EMPTY" -eq 1 ] || fail "Empty source; use --allow-empty only to intentionally delete all destination Jobs"
# Refuse partial mirrors: differing existing configs require overwrite.
check_updates() (
    src=$1; dst=$2
    for item in "$src"/*; do
        [ -d "$item" ] || continue
        name=${item##*/}
        if [ -f "$dst/$name/config.xml" ]; then
            if cmp -s "$item/config.xml" "$dst/$name/config.xml"; then :
            else
                rc=$?
                [ "$rc" -eq 1 ] || fail "Comparison failed: $item"
                [ "$APPLY" -eq 0 ] || [ "$OVERWRITE" -eq 1 ] || fail "Changed config requires --overwrite: $name"
            fi
        fi
        if [ -d "$item/jobs" ]; then check_updates "$item/jobs" "$dst/$name/jobs"; fi
    done
)
check_updates "$SOURCE" "$TARGET"
# Backups use a fresh root to avoid overwriting previous backup files or following links.
if [ -n "$BACKUP_DIR" ]; then
    for item in "$BACKUP_DIR"/* "$BACKUP_DIR"/.[!.]* "$BACKUP_DIR"/..?*; do
        [ ! -e "$item" ] && [ ! -L "$item" ] || fail "Backup directory must be empty: $BACKUP_DIR"
    done
fi
# Neither source nor destination may change concurrently during the operation.
prune_jobs() (
    src=$1; dst=$2; relative=$3
    [ -d "$dst" ] || exit 0
    for item in "$dst"/*; do
        [ -d "$item" ] || continue
        name=${item##*/}
        rel_job=$relative$name
        if [ ! -f "$src/$name/config.xml" ]; then
            printf '[DELETE] %s\n' "$rel_job"
            if [ "$APPLY" -eq 1 ]; then
                if [ -n "$BACKUP_DIR" ]; then
                    backup_job=$BACKUP_DIR/deleted/$rel_job
                    mkdir -p "${backup_job%/*}"
                    cp -Rp "$item" "$backup_job"
                fi
                rm -rf -- "$item"
            fi
        elif [ -d "$item/jobs" ]; then
            prune_jobs "$src/$name/jobs" "$item/jobs" "$rel_job/jobs/"
            if [ "$APPLY" -eq 1 ] && [ ! -d "$src/$name/jobs" ]; then
                rmdir "$item/jobs"
            fi
        fi
    done
)

printf 'Mode: %s\nSource: %s\nTarget: %s\n' "$(if [ "$APPLY" -eq 1 ]; then echo APPLY; else echo DRY-RUN; fi)" "$SOURCE" "$TARGET"

# $1 = source jobs dir, $2 = target jobs dir, $3 = relative path within jobs tree
import_jobs() (
    source_dir=$1
    target_dir=$2
    relative=$3
    if [ -L "$target_dir" ] || { [ -e "$target_dir" ] && [ ! -d "$target_dir" ]; }; then
        echo "ERROR: Invalid target jobs directory: $target_dir" >&2
        exit 1
    fi

    for job_dir in "$source_dir"/*; do
        if [ ! -d "$job_dir" ] || [ -L "$job_dir" ]; then
			continue
		fi
        if [ ! -f "$job_dir/config.xml" ] || [ -L "$job_dir/config.xml" ]; then
			continue
		fi
        job_name=${job_dir##*/}
#  ##	從字串開頭移除符合模式的最長部分
#  */	匹配任意字元，直到某個 /
#  是否可以改用 basename？可以，而且效果很接近。=> job_name=$(basename "$job_dir")
        rel_job=${relative}${job_name}
        destination=$target_dir/$job_name
        config_target=$destination/config.xml

        if [ -L "$destination" ] || [ -L "$config_target" ]; then
            echo "ERROR: Refusing symlink target: $destination" >&2
            exit 1
        fi
# -e 檢查該路徑是否存在
        if [ -e "$destination" ] && [ ! -d "$destination" ]; then
            echo "ERROR: Not a directory: $destination" >&2
            exit 1
        fi
        if [ -e "$config_target" ] && [ ! -f "$config_target" ]; then
            echo "ERROR: Not a regular config file: $config_target" >&2
            exit 1
        fi
# cmp 是比較兩個檔案的內容，逐位元組（byte）檢查是否相同。-s 表示安靜模式，不印出比較結果
        if [ -f "$config_target" ] && cmp -s "$job_dir/config.xml" "$config_target"; then
            printf '[UNCHANGED] %s\n' "$rel_job"
        elif [ -e "$config_target" ] && [ "$OVERWRITE" -eq 0 ] && [ "$APPLY" -eq 1 ]; then
            printf '[SKIP existing] %s (use --overwrite with backup)\n' "$rel_job"
        else
            if [ -e "$config_target" ]; then
                printf '[UPDATE] %s\n' "$rel_job"
                if [ "$APPLY" -eq 1 ]; then
                    if [ -n "$BACKUP_DIR" ]; then
                    backup_file=$BACKUP_DIR/updated/$rel_job/config.xml
                    if [ -e "$backup_file" ] || [ -L "$backup_file" ]; then
                        echo "ERROR: Backup already exists: $backup_file" >&2
                        exit 1
                    fi
                    mkdir -p "${backup_file%/*}"
                    cp -p "$config_target" "$backup_file"
                    fi
                    cp "$job_dir/config.xml" "$config_target"
                fi
            else
                printf '[CREATE] %s\n' "$rel_job"
                if [ "$APPLY" -eq 1 ]; then
                    mkdir -p "$destination"
                    cp "$job_dir/config.xml" "$config_target"
                fi
            fi
        fi

        if [ -d "$job_dir/jobs" ] && [ ! -L "$job_dir/jobs" ]; then
            import_jobs "$job_dir/jobs" "$destination/jobs" "$rel_job/jobs/"
        fi
    done
)

import_jobs "$SOURCE" "$TARGET" ""
prune_jobs "$SOURCE" "$TARGET" ""
if [ "$APPLY" -eq 0 ]; then
    echo "Dry run completed. No files were changed."
else
    echo "Mirror completed. For import: start Jenkins and verify the Jobs in its UI."
fi
