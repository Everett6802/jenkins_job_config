#!/bin/sh
set -eu

SOURCE=
TARGET=

# 解析命令列參數 每次成功處理一組參數，就透過 shift 2 減少兩個參數，直到全部處理完畢。
while [ "$#" -gt 0 ]; do
    if [ "$#" -lt 2 ] || [ -z "$2" ]; then
# "$#" -lt 2 => 如果沒有提供來源路徑，所以判定錯誤
# -z 用來判斷字串長度是否為 0
        echo "ERROR: $1 requires a path" >&2
# 等同於 echo "ERROR: $1 requires a path" 1>&2 => 把原本要送到 stdout（FD 1）的內容，改送到 stderr（FD 2）。
# 例如：./script.sh > output.log => 如果程式使用 >&2 輸出錯誤，錯誤訊息不會進入 output.log，而是繼續顯示在終端機
        exit 1
    fi
    case "$1" in
        --src) SOURCE=$2 ;;
        --dst) TARGET=$2 ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            exit 1
            ;;
	esac
	shift 2
# shift 是 Shell 的內建命令，用來移除已處理的命令列位置參數。 shift 2 會移除前兩個參數，並讓後面的參數依序往前移動
done

# ./script.sh > output.log 2>&1
# 意思是：1. > output.log：將 stdout（FD 1）導向 output.log。 2. 2>&1：將 stderr（FD 2）導向目前 stdout 指向的位置。
# 結果就是：正常輸出和錯誤訊息都會寫入 output.log。

# -z 是檢查字串是否為空，剛好與 -n 相反。
if [ -z "$SOURCE" ] && [ -z "$TARGET" ]; then
    echo "Usage: $0 --src SOURCE_JOBS_DIR --dst TARGET_JOBS_DIR" >&2
    exit 1
fi
# 會檢查 SOURCE 指向的路徑是否存在，而且是目錄
if [ ! -d "$SOURCE" ]; then
    echo "ERROR: Source directory does not exist: $SOURCE" >&2
    exit 1
fi

# 移除尾端斜線，統一路徑格式
SOURCE=${SOURCE%/}
TARGET=${TARGET%/}
#echo "SOURCE: ${SOURCE}"
#echo "TARGET: ${TARGET}"
mkdir -p "$TARGET"

# 每次只處理該層的 Job；有巢狀 jobs 目錄才繼續往下
export_jobs() (
    source_dir=$1
    target_dir=$2
# /*	匹配該目錄下一層的所有非隱藏項目
    for job_dir in "$source_dir"/*; 
	do
		echo "job_dir: ${job_dir}"
        if [ ! -d "$job_dir" ]; then
			continue
		fi
        if [ ! -f "$job_dir/config.xml" ]; then
			continue
		fi
        job_name=${job_dir##*/}
#  ##	從字串開頭移除符合模式的最長部分
#  */	匹配任意字元，直到某個 /
#  是否可以改用 basename？可以，而且效果很接近。=> job_name=$(basename "$job_dir")
        destination="$target_dir/$job_name"
        mkdir -p "$destination"
        cp "$job_dir/config.xml" "$destination/config.xml"
        printf 'Exported: %s\n' "$destination/config.xml"
        if [ -d "$job_dir/jobs" ]; then
            export_jobs "$job_dir/jobs" "$destination/jobs"
        fi
    done
)

export_jobs "$SOURCE" "$TARGET"

# 例:
# path="/home/user/project/test.txt"
# ${path#*/}	home/user/project/test.txt	移除最短匹配
# ${path##*/}	test.txt	移除最長匹配
# #：從開頭移除。
# %：從結尾移除。
# 雙符號 ##、%%：移除最長匹配。
# 單符號 #、%：移除最短匹配。
