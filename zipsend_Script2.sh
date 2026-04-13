#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

GMAIL_LIMIT_MB=25
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
check_dep bc        "bc"
check_dep ffmpeg    "ffmpeg"
check_dep convert   "imagemagick"
check_dep gzip      "gzip"

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
                
                # OPTIMIZATION: Use 'copy' for audio and 'ultrafast' preset for video to speed up MKV/MP4 processing
                ffmpeg -i "$video_file" -vcodec libx264 -crf 28 -preset ultrafast -acodec copy "$output_file" &>/dev/null

                if [[ $? -eq 0 ]]; then
                    echo -e "  ${GREEN}Compressed: ${filename} -> $(basename "$output_file") (CRF 28, Ultrafast)${RESET}"
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
    COMP_LABEL="7z (lzma2 — media or pre-compressed files detected)"
else
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
    ARCHIVE_NAME="${ARCHIVE_NAME%.gz}"

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

echo -e "${CYAN}Compressing to 7z...${RESET}"
7z a -t7z -mx=9 -m0=lzma2 -mfb=64 -md=32m "$ARCHIVE_FILE" "$FOLDER_PATH"

if [[ $? -ne 0 ]]; then
    echo -e "\n${RED}7z compression failed.${RESET}"
    rm -f "$ARCHIVE_FILE"
    exit 1
fi

# WRAP 7z IN GZIP
GZIP_FILE="${ARCHIVE_FILE}.gz"
echo -e "${CYAN}Wrapping 7z in GZIP for email delivery...${RESET}"
gzip -c "$ARCHIVE_FILE" > "$GZIP_FILE"

if [[ $? -ne 0 ]]; then
    echo -e "\n${RED}GZIP wrapping failed.${RESET}"
    exit 1
fi

ARCHIVE_SIZE_BYTES=$(stat -c%s "$ARCHIVE_FILE")
ARCHIVE_SIZE_HUMAN=$(bytes_to_human "$ARCHIVE_SIZE_BYTES")
GZIP_SIZE_BYTES=$(stat -c%s "$GZIP_FILE")
GZIP_SIZE_HUMAN=$(bytes_to_human "$GZIP_SIZE_BYTES")
CHECKSUM=$(sha256sum "$ARCHIVE_FILE" | awk '{print $1}')

if (( RAW_SIZE_BYTES > 0 )); then
    RATIO=$(echo "scale=1; (1 - $ARCHIVE_SIZE_BYTES / $RAW_SIZE_BYTES) * 100" | bc -l)
    RATIO_LABEL="  Saved ${RATIO}% (${RAW_SIZE_HUMAN} → ${ARCHIVE_SIZE_HUMAN})"
else
    RATIO_LABEL="  Size: ${ARCHIVE_SIZE_HUMAN}"
fi

echo -e "  SHA256 (7z): ${CHECKSUM}"
echo -e "\n${GREEN}${BOLD}Done.${RESET}"
echo -e "  7z File   : ${ARCHIVE_FILE} (${ARCHIVE_SIZE_HUMAN})"
echo -e "  GZIP File : ${GZIP_FILE} (${GZIP_SIZE_HUMAN})"
echo -e "${RATIO_LABEL}"

GMAIL_LIMIT_BYTES=$(( GMAIL_LIMIT_MB * 1024 * 1024 ))
if (( GZIP_SIZE_BYTES > GMAIL_LIMIT_BYTES )); then
    echo -e "\n${YELLOW}  GZIP file is ${GZIP_SIZE_HUMAN} — over the ${GMAIL_LIMIT_MB} MB Gmail limit. Email will not be sent.${RESET}"
    SEND_EMAIL="no"
else
    SEND_EMAIL="yes"
fi

SENDER=$(grep -m1 "^from" "$HOME/.msmtprc" | awk '{print $2}')
SENDER_NAME=$(grep -m1 "^from" "$HOME/.msmtprc" | awk '{print $2}' | cut -d'@' -f1)
SENDER="${SENDER:-$(whoami)@$(hostname)}"
SENDER_DOMAIN="${SENDER#*@}"

send_email() {
    local TO="$1"
    local ATTACH_FILE="$2"
    local ATTACH_FNAME=$(basename "$ATTACH_FILE")
    local SUBJECT="${ARCHIVE_NAME} — From Group of (Rapis, Abogado, Cambel, Tomenio, Calago)"
    local BOUNDARY="==s3cript_$(date +%s%N)_${$}=="
    local MSG_ID="<$(date +%s%N).${$}@${SENDER_DOMAIN}>"
    local DATE_HDR=$(date -R)

    local BODY="Hi Sir Arma!,

  Original 7z  : ${ARCHIVE_NAME}.7z
  Email Attachment: ${ATTACH_FNAME}
  GZIP Size    : ${GZIP_SIZE_HUMAN}

How to extract
------------------------------------------------------------
1. Save the attachment: ${ATTACH_FNAME}
2. Un-gzip the file:
   gunzip ${ATTACH_FNAME}
3. Extract the resulting 7z file:
   7z x ${ARCHIVE_NAME}.7z
------------------------------------------------------------"

    {
        printf "From: %s <%s>\r\n"      "$SENDER_NAME" "$SENDER"
        printf "To: %s\r\n"             "$TO"
        printf "Reply-To: %s\r\n"       "$SENDER"
        printf "Subject: %s\r\n"        "$SUBJECT"
        printf "Date: %s\r\n"           "$DATE_HDR"
        printf "Message-ID: %s\r\n"     "$MSG_ID"
        printf "X-Mailer: S3cript/5.0\r\n"
        printf "MIME-Version: 1.0\r\n"
        printf "Content-Type: multipart/mixed; boundary=\"%s\"\r\n" "$BOUNDARY"
        printf "\r\n"

        printf -- "--%s\r\n"   "$BOUNDARY"
        printf "Content-Type: text/plain; charset=utf-8\r\n"
        printf "Content-Transfer-Encoding: 7bit\r\n"
        printf "\r\n"
        printf "%s\r\n\r\n" "$BODY"

        printf -- "--%s\r\n"   "$BOUNDARY"
        printf "Content-Type: application/gzip; name=\"%s\"\r\n" "$ATTACH_FNAME"
        printf "Content-Transfer-Encoding: base64\r\n"
        printf "Content-Disposition: attachment; filename=\"%s\"\r\n" "$ATTACH_FNAME"
        printf "\r\n"
        base64 "$ATTACH_FILE"
        printf "\r\n"
        printf -- "--%s--\r\n" "$BOUNDARY"
    } | msmtp -t --account=default
}

if [[ "$SEND_EMAIL" == "yes" ]]; then
    echo -e "\n${CYAN}Emailing GZIP archive...${RESET}"
    read -rp "$(echo -e "${BOLD}Recipient email:${RESET} ")" RECIPIENT
    if [[ -n "$RECIPIENT" ]]; then
        send_email "$RECIPIENT" "$GZIP_FILE"
        echo -e "${GREEN}  Sent.${RESET}"
    else
        echo -e "${YELLOW}  No recipient provided. Skipping email.${RESET}"
    fi
fi
