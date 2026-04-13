#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

GMAIL_LIMIT_MB=25
SPLIT_CHUNK_MB=18
PRE_COMPRESS_THRESHOLD_MB=4


check_dep() {
    local cmd="$1" pkg="$2"
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${RED}[ERROR]${RESET} '$cmd' not found."
        echo -e "        Install it with: ${YELLOW}sudo apt install $pkg${RESET}"
        exit 1
    fi
}

check_dep tar       "tar"
check_dep zstd      "zstd"
check_dep 7z        "p7zip-full"
check_dep msmtp     "msmtp msmtp-mta ca-certificates"
check_dep base64    "coreutils"
check_dep sha256sum "coreutils"
check_dep split     "coreutils"
check_dep bc        "bc"
check_dep ffmpeg    "ffmpeg"
check_dep convert   "imagemagick"

if [[ ! -f "$HOME/.msmtprc" ]]; then
    echo -e "${RED}[ERROR]${RESET} ~/.msmtprc is missing — set up msmtp first."
    exit 1
fi


bytes_to_human() {
    local b="$1"
    if   (( b < 1024 ));        then echo "${b}B"
    elif (( b < 1048576 ));     then printf "%.2fKB" "$(echo "$b/1024"       | bc -l)"
    elif (( b < 1073741824 ));  then printf "%.2fMB" "$(echo "$b/1048576"    | bc -l)"
    else                             printf "%.2fGB" "$(echo "$b/1073741824" | bc -l)"
    fi
}

VIDEO_EXTS="mp4 mkv avi mov wmv flv webm m4v mpg mpeg ts m2ts vob"
IMAGE_EXTS="jpg jpeg png bmp tiff webp"

has_media_files() {
    local path="$1"
    for ext in $VIDEO_EXTS $IMAGE_EXTS; do
        if find "$path" -maxdepth 6 -iname "*.${ext}" -print -quit 2>/dev/null | grep -q .; then
            return 0
        fi
    done
    return 1
}

pre_compress_media_files() {
    local folder_path="$1"
    local temp_dir=$(mktemp -d)
    local compressed_count=0
    local threshold_bytes=$(( PRE_COMPRESS_THRESHOLD_MB * 1024 * 1024 ))

    echo -e "\n${CYAN}Checking for media files to pre-compress (Threshold: ${PRE_COMPRESS_THRESHOLD_MB}MB)...${RESET}"

    # Process Videos
    for ext in $VIDEO_EXTS; do
        while IFS= read -r -d $'' video_file; do
            if [[ -f "$video_file" ]]; then
                local filesize=$(stat -c%s "$video_file")
                if (( filesize < threshold_bytes )); then
                    echo -e "  ${CYAN}Skipping (under ${PRE_COMPRESS_THRESHOLD_MB}MB): $(basename "$video_file")${RESET}"
                    continue
                fi

                local filename=$(basename "$video_file")
                local output_file="$temp_dir/${filename%.*}.mp4"

                echo -e "  ${YELLOW}Pre-compressing Video: ${filename}${RESET}"
                ffmpeg -i "$video_file" -vcodec libx264 -crf 28 "$output_file" &>/dev/null

                if [[ $? -eq 0 ]]; then
                    echo -e "  ${GREEN}Compressed: ${filename} -> $(basename "$output_file") (CRF 28)${RESET}"
                    mv "$output_file" "$video_file"
                    compressed_count=$((compressed_count + 1))
                else
                    echo -e "  ${RED}Failed to pre-compress: ${filename}${RESET}"
                fi
            fi
        done < <(find "$folder_path" -maxdepth 6 -iname "*.${ext}" -print0 2>/dev/null)
    done

    # Process Images
    for ext in $IMAGE_EXTS; do
        while IFS= read -r -d $'' image_file; do
            if [[ -f "$image_file" ]]; then
                local filesize=$(stat -c%s "$image_file")
                if (( filesize < threshold_bytes )); then
                    echo -e "  ${CYAN}Skipping (under ${PRE_COMPRESS_THRESHOLD_MB}MB): $(basename "$image_file")${RESET}"
                    continue
                fi

                local filename=$(basename "$image_file")
                local output_file="$temp_dir/${filename%.*}.jpg"

                echo -e "  ${YELLOW}Pre-compressing Image: ${filename}${RESET}"
                convert "$image_file" -quality 75 "$output_file" &>/dev/null

                if [[ $? -eq 0 ]]; then
                    echo -e "  ${GREEN}Compressed: ${filename} -> $(basename "$output_file") (Quality 75)${RESET}"
                    if [[ "$image_file" == *".jpg" || "$image_file" == *".jpeg" ]]; then
                        mv "$output_file" "$image_file"
                    else
                        mv "$output_file" "${image_file%.*}.jpg"
                        rm "$image_file"
                    fi
                    compressed_count=$((compressed_count + 1))
                else
                    echo -e "  ${RED}Failed to pre-compress: ${filename}${RESET}"
                fi
            fi
        done < <(find "$folder_path" -maxdepth 6 -iname "*.${ext}" -print0 2>/dev/null)
    done

    rm -rf "$temp_dir"
    if (( compressed_count > 0 )); then
        echo -e "${GREEN}Pre-compression complete. Total media files compressed: ${compressed_count}${RESET}"
    else
        echo -e "${YELLOW}No media files required pre-compression.${RESET}"
    fi
}


validate_source() {
    local path="$1" bad=0
    while IFS= read -r -d '' f; do
        if   [[ -L "$f" && ! -e "$f" ]]; then echo -e "  ${RED}Broken symlink :${RESET} $f"; bad=1
        elif [[ ! -r "$f"             ]]; then echo -e "  ${RED}Unreadable     :${RESET} $f"; bad=1
        fi
    done < <(find "$path" -print0 2>/dev/null)
    return $bad
}


echo ""
while true; do
    read -rp "$(echo -e "${BOLD}Folder to compress:${RESET} ")" FOLDER_PATH
    FOLDER_PATH="${FOLDER_PATH%/}"
    if   [[ -z "$FOLDER_PATH"   ]]; then echo -e "${RED}  Path can't be empty.${RESET}\n"
    elif [[ ! -d "$FOLDER_PATH" ]]; then echo -e "${RED}  Can't find \"$FOLDER_PATH\"${RESET}\n"
    else echo -e "${GREEN}  Found.${RESET}"; break
    fi
done


echo -e "\n${CYAN}Checking source for problems...${RESET}"
if ! validate_source "$FOLDER_PATH"; then
    read -rp "$(echo -e "\n${YELLOW}  Issues listed above. Continue anyway? (y/N): ${RESET}")" CONT
    [[ ! "$CONT" =~ ^[Yy]$ ]] && { echo -e "${RED}  Cancelled.${RESET}"; exit 0; }
fi

RAW_SIZE_BYTES=$(du -sb "$FOLDER_PATH" 2>/dev/null | awk '{print $1}')
RAW_SIZE_HUMAN=$(bytes_to_human "$RAW_SIZE_BYTES")


if has_media_files "$FOLDER_PATH"; then
    pre_compress_media_files "$FOLDER_PATH"

    ZSTD_LEVEL="-1"
    COMP_LABEL="7z (lzma2 — media or pre-compressed files detected)"
else
    ZSTD_LEVEL="-19"
    COMP_LABEL="7z (lzma2 — ultra compression)"
fi

echo -e "  Source size  : ${RAW_SIZE_HUMAN}"
echo -e "  Compressor   : ${COMP_LABEL}"
echo ""


DEFAULT_NAME="$(basename "$FOLDER_PATH")"

while true; do
    read -rp "$(echo -e "${BOLD}Archive name${RESET} [${DEFAULT_NAME}]: ")" ARCHIVE_NAME
    ARCHIVE_NAME="${ARCHIVE_NAME:-$DEFAULT_NAME}"
    ARCHIVE_NAME="${ARCHIVE_NAME%.7z}"

    if [[ "$ARCHIVE_NAME" =~ [/\\] ]]; then
        echo -e "${RED}  No slashes in the name, please.${RESET}\n"
    else
        echo -e "  Output file: ${ARCHIVE_NAME}.7z\n"
        break
    fi
done


read -rp "$(echo -e "${BOLD}Output directory${RESET} (blank = current dir): ")" OUTPUT_DIR
OUTPUT_DIR="${OUTPUT_DIR%/}"
OUTPUT_DIR="${OUTPUT_DIR:-.}"
[[ ! -d "$OUTPUT_DIR" ]] && { echo -e "${YELLOW}  Creating output directory...${RESET}"; mkdir -p "$OUTPUT_DIR"; }

ARCHIVE_FILE="${OUTPUT_DIR}/${ARCHIVE_NAME}.7z"


if [[ -f "$ARCHIVE_FILE" ]]; then
    echo -e "\n${YELLOW}Warning: '${ARCHIVE_FILE}' already exists.${RESET}"
    read -rp "  Overwrite? (y/N): " CONFIRM
    [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && { echo -e "${RED}  Cancelled.${RESET}"; exit 0; }
    rm -f "$ARCHIVE_FILE"
fi


echo -e "${CYAN}Compressing...${RESET}"
echo -e "  Source → ${ARCHIVE_FILE}\n"

# Using 7z with user-specified high-compression settings
7z a -t7z -mx=9 -m0=lzma2 -mfb=64 -md=32m "$ARCHIVE_FILE" "$FOLDER_PATH"

if [[ $? -ne 0 ]]; then
    echo -e "\n${RED}Compression failed.${RESET}"
    rm -f "$ARCHIVE_FILE"
    exit 1
fi


echo -e "\n${CYAN}Verifying archive...${RESET}"

if [[ ! -f "$ARCHIVE_FILE" ]]; then
    echo -e "  ${RED}7z file not created.${RESET}"
    exit 1
fi

echo -e "  ${GREEN}Looks good.${RESET}"


ARCHIVE_SIZE_BYTES=$(stat -c%s "$ARCHIVE_FILE")
ARCHIVE_SIZE_HUMAN=$(bytes_to_human "$ARCHIVE_SIZE_BYTES")
CHECKSUM=$(sha256sum "$ARCHIVE_FILE" | awk '{print $1}')

if (( RAW_SIZE_BYTES > 0 )); then
    RATIO=$(echo "scale=1; (1 - $ARCHIVE_SIZE_BYTES / $RAW_SIZE_BYTES) * 100" | bc -l)
    RATIO_LABEL="  Saved ${RATIO}% (${RAW_SIZE_HUMAN} → ${ARCHIVE_SIZE_HUMAN})"
else
    RATIO_LABEL="  Size: ${ARCHIVE_SIZE_HUMAN}"
fi

echo -e "  SHA256: ${CHECKSUM}"
echo -e "\n${GREEN}${BOLD}Done.${RESET}"
echo -e "  File   : ${ARCHIVE_FILE}"
echo -e "${RATIO_LABEL}"


GMAIL_LIMIT_BYTES=$(( GMAIL_LIMIT_MB * 1024 * 1024 ))
SEND_PARTS=()

if (( ARCHIVE_SIZE_BYTES > GMAIL_LIMIT_BYTES )); then
    echo -e "\n${YELLOW}  Archive is ${ARCHIVE_SIZE_HUMAN} — over the ${GMAIL_LIMIT_MB} MB Gmail limit. Email will not be sent.${RESET}"
    SEND_EMAIL="no"
else
    SEND_EMAIL="yes"
    SEND_PARTS=("$ARCHIVE_FILE")
    PART_COUNT=1
fi


SENDER=$(grep -m1 "^from" "$HOME/.msmtprc" | awk '{print $2}')
SENDER_NAME=$(grep -m1 "^from" "$HOME/.msmtprc" | awk '{print $2}' | cut -d'@' -f1)
SENDER="${SENDER:-$(whoami)@$(hostname)}"
SENDER_DOMAIN="${SENDER#*@}"


send_email() {
    local TO="$1"
    local ATTACH_FILE="$2"
    local PART_NUM="${3:-0}"
    local PART_TOTAL="${4:-0}"

    local ATTACH_FNAME
    ATTACH_FNAME=$(basename "$ATTACH_FILE")

    local SEND_FNAME
    if (( PART_NUM > 0 )); then
        local PADDED
        PADDED=$(printf "%03d" "$PART_NUM")
        SEND_FNAME="${ARCHIVE_NAME}.part${PADDED}.bin"
    else
        SEND_FNAME="${ARCHIVE_NAME}.7z"
    fi

    local PART_SIZE_BYTES PART_SIZE_HUMAN
    PART_SIZE_BYTES=$(stat -c%s "$ATTACH_FILE")
    PART_SIZE_HUMAN=$(bytes_to_human "$PART_SIZE_BYTES")

    local SUBJECT
    if (( PART_NUM > 0 )); then
        SUBJECT="${ARCHIVE_NAME} — Part ${PART_NUM} of ${PART_TOTAL}"
    else
        SUBJECT="${ARCHIVE_NAME} — Compressed Archive"
    fi

    local BOUNDARY="==s3cript_$(date +%s%N)_${$}=="
    local MSG_ID="<$(date +%s%N).${$}@${SENDER_DOMAIN}>"
    local DATE_HDR
    DATE_HDR=$(date -R)

    local BODY
    if (( PART_NUM > 0 )); then
        BODY="Hi,

This is part ${PART_NUM} of ${PART_TOTAL} of '${ARCHIVE_NAME}'.
You'll need all ${PART_TOTAL} parts in the same folder before you can reassemble it.

  Part file  : ${SEND_FNAME}
  Part size  : ${PART_SIZE_HUMAN}
  Total size : ${ARCHIVE_SIZE_HUMAN} (full archive)

How to reassemble & extract
------------------------------------------------------------

    1. Save all ${PART_TOTAL} parts from their separate emails.
    2. Join them back together:
         cat ${ARCHIVE_NAME}.part*.bin > ${ARCHIVE_NAME}.7z
    3. Extract:
         7z x ${ARCHIVE_NAME}.7z

------------------------------------------------------------"
    else
        BODY="Hi,

Compressed archive attached — see details below.

  File     : ${SEND_FNAME}
  Size     : ${ARCHIVE_SIZE_HUMAN}
  Ratio    : ${RATIO_LABEL# }

How to extract
------------------------------------------------------------

  Linux / Mac:
    1. Rename the attachment:
         mv ${SEND_FNAME} ${ARCHIVE_NAME}.7z
    2. Extract:
         7z x ${ARCHIVE_NAME}.7z

------------------------------------------------------------"
    fi

    {
        printf "From: %s <%s>\r\n"      "$SENDER_NAME" "$SENDER"
        printf "To: %s\r\n"             "$TO"
        printf "Reply-To: %s\r\n"       "$SENDER"
        printf "Subject: %s\r\n"        "$SUBJECT"
        printf "Date: %s\r\n"           "$DATE_HDR"
        printf "Message-ID: %s\r\n"     "$MSG_ID"
        printf "X-Mailer: S3cript/4.0\r\n"
        printf "X-Priority: 3\r\n"
        printf "Importance: Normal\r\n"
        printf "Content-Language: en-US\r\n"
        printf "MIME-Version: 1.0\r\n"
        printf "Content-Type: multipart/mixed; boundary=\"%s\"\r\n" "$BOUNDARY"
        printf "\r\n"

        printf -- "--%s\r\n"   "$BOUNDARY"
        printf "Content-Type: text/plain; charset=utf-8\r\n"
        printf "Content-Transfer-Encoding: 7bit\r\n"
        printf "\r\n"
        printf "%s\r\n\r\n" "$BODY"

        printf -- "--%s\r\n"   "$BOUNDARY"
        printf "Content-Type: application/octet-stream; name=\"%s\"\r\n" "$SEND_FNAME"
        printf "Content-Transfer-Encoding: base64\r\n"
        printf "Content-Disposition: attachment; filename=\"%s\"\r\n" "$SEND_FNAME"
        printf "\r\n"
        base64 "$ATTACH_FILE"
        printf "\r\n"
        printf -- "--%s--\r\n" "$BOUNDARY"
    } | msmtp -t --account=default
}


if [[ "$SEND_EMAIL" == "yes" ]]; then
    echo -e "\n${CYAN}Emailing archive...${RESET}"
    read -rp "$(echo -e "${BOLD}Recipient email:${RESET} ")" RECIPIENT
    if [[ -n "$RECIPIENT" ]]; then
        for (( i=0; i<${#SEND_PARTS[@]}; i++ )); do
            P_NUM=$(( i + 1 ))
            if (( PART_COUNT > 1 )); then
                echo -e "  Sending part ${P_NUM} of ${PART_COUNT}..."
                send_email "$RECIPIENT" "${SEND_PARTS[$i]}" "$P_NUM" "$PART_COUNT"
            else
                echo -e "  Sending archive..."
                send_email "$RECIPIENT" "${SEND_PARTS[$i]}"
            fi
        done
        echo -e "${GREEN}  Sent.${RESET}"
    else
        echo -e "${YELLOW}  No recipient provided. Skipping email.${RESET}"
    fi
fi
