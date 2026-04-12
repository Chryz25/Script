#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

GMAIL_LIMIT_MB=25
SPLIT_CHUNK_MB=18


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
check_dep msmtp     "msmtp msmtp-mta ca-certificates"
check_dep base64    "coreutils"
check_dep sha256sum "coreutils"
check_dep split     "coreutils"
check_dep bc        "bc"

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

has_media_files() {
    local path="$1"
    local exts="jpg jpeg png gif bmp tiff webp heic raw cr2 nef arw dng
                mp4 mkv avi mov wmv flv webm m4v mpg mpeg ts m2ts vob
                mp3 aac flac ogg wav wma m4a opus aiff
                zip 7z rar gz bz2 xz zst lz4"
    for ext in $exts; do
        if find "$path" -maxdepth 6 -iname "*.${ext}" -print -quit 2>/dev/null | grep -q .; then
            return 0
        fi
    done
    return 1
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
    ZSTD_LEVEL="-1"
    COMP_LABEL="zstd level 1  (fast store — media or pre-compressed files detected)"
else
    ZSTD_LEVEL="-19"
    COMP_LABEL="zstd level 19 (ultra — docs/code compress really well here)"
fi

echo -e "  Source size  : ${RAW_SIZE_HUMAN}"
echo -e "  Compressor   : ${COMP_LABEL}"
echo ""


DEFAULT_NAME="$(basename "$FOLDER_PATH")"

while true; do
    read -rp "$(echo -e "${BOLD}Archive name${RESET} [${DEFAULT_NAME}]: ")" ARCHIVE_NAME
    ARCHIVE_NAME="${ARCHIVE_NAME:-$DEFAULT_NAME}"
    ARCHIVE_NAME="${ARCHIVE_NAME%.tar.gz}"
    ARCHIVE_NAME="${ARCHIVE_NAME%.tar.zst}"
    ARCHIVE_NAME="${ARCHIVE_NAME%.tar}"

    if [[ "$ARCHIVE_NAME" =~ [/\\] ]]; then
        echo -e "${RED}  No slashes in the name, please.${RESET}\n"
    else
        echo -e "  Output file: ${ARCHIVE_NAME}.tar.gz\n"
        break
    fi
done


read -rp "$(echo -e "${BOLD}Output directory${RESET} (blank = current dir): ")" OUTPUT_DIR
OUTPUT_DIR="${OUTPUT_DIR%/}"
OUTPUT_DIR="${OUTPUT_DIR:-.}"
[[ ! -d "$OUTPUT_DIR" ]] && { echo -e "${YELLOW}  Creating output directory...${RESET}"; mkdir -p "$OUTPUT_DIR"; }

ARCHIVE_FILE="${OUTPUT_DIR}/${ARCHIVE_NAME}.tar.gz"


if [[ -f "$ARCHIVE_FILE" ]]; then
    echo -e "\n${YELLOW}Warning: '${ARCHIVE_FILE}' already exists.${RESET}"
    read -rp "  Overwrite? (y/N): " CONFIRM
    [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && { echo -e "${RED}  Cancelled.${RESET}"; exit 0; }
    rm -f "$ARCHIVE_FILE"
fi


echo -e "${CYAN}Compressing...${RESET}"
echo -e "  Source → ${ARCHIVE_FILE}\n"

tar -C "$(dirname "$FOLDER_PATH")" \
    -cf - \
    "$(basename "$FOLDER_PATH")" \
  | zstd $ZSTD_LEVEL -T0 -o "$ARCHIVE_FILE"

if [[ $? -ne 0 ]]; then
    echo -e "\n${RED}Compression failed.${RESET}"
    rm -f "$ARCHIVE_FILE"
    exit 1
fi


echo -e "\n${CYAN}Verifying archive...${RESET}"

if ! zstd -t "$ARCHIVE_FILE" &>/dev/null; then
    echo -e "  ${RED}zstd check FAILED.${RESET}"
    exit 1
fi

if ! tar --use-compress-program="zstd -d" -tf "$ARCHIVE_FILE" &>/dev/null; then
    echo -e "  ${RED}tar structure check FAILED.${RESET}"
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
    echo -e "\n${YELLOW}  Archive is ${ARCHIVE_SIZE_HUMAN} — over the ${GMAIL_LIMIT_MB} MB Gmail limit.${RESET}"
    echo -e "  ${CYAN}Splitting into ≤${SPLIT_CHUNK_MB} MB chunks...${RESET}"

    SPLIT_PREFIX="${ARCHIVE_FILE}.part"
    rm -f "${SPLIT_PREFIX}"* 2>/dev/null

    split -b "${SPLIT_CHUNK_MB}m" -d --suffix-length=3 "$ARCHIVE_FILE" "$SPLIT_PREFIX"

    if [[ $? -ne 0 ]]; then
        echo -e "${RED}  Split failed.${RESET}"
        exit 1
    fi

    mapfile -t SEND_PARTS < <(ls "${SPLIT_PREFIX}"* 2>/dev/null | sort)
    PART_COUNT=${#SEND_PARTS[@]}

    echo -e "  ${GREEN}Split into ${PART_COUNT} part(s):${RESET}"
    for i in "${!SEND_PARTS[@]}"; do
        PSIZE=$(bytes_to_human "$(stat -c%s "${SEND_PARTS[$i]}")")
        echo -e "    Part $((i+1))/${PART_COUNT}: $(basename "${SEND_PARTS[$i]}")  (${PSIZE})"
    done
else
    SEND_PARTS=("$ARCHIVE_FILE")
    PART_COUNT=1
fi


SENDER=$(grep -m1 "^from" "$HOME/.msmtprc" | awk '{print $2}')
SENDER_NAME=$(grep -m1 "^from" "$HOME/.msmtprc" | awk '{print $2}' | cut -d'@' -f1)
SENDER="${SENDER:-$(whoami)@$(hostname)}"
SENDER_DOMAIN="${SENDER#*@}"


# ---------------------------------------------------------------------------
# build_receiver_script
#   Generates a self-contained bash script that the receiver runs once.
#   It will:
#     1. Create a dedicated folder named after the archive
#     2. Move all downloaded .bin parts (or the single .bin) into that folder
#     3. Reassemble the parts (if split)
#     4. Verify the SHA-256 checksum
#     5. Extract the archive
#     6. Clean up the intermediate files
# ---------------------------------------------------------------------------
build_receiver_script() {
    local archive_name="$1"
    local part_count="$2"
    local checksum="$3"
    local archive_size_human="$4"

    cat <<RECV_SCRIPT
#!/bin/bash
# ============================================================
#  Auto-setup script for: ${archive_name}
#  Generated by S5cript — run this once after downloading
#  all attachment(s) into the same folder as this script.
# ============================================================

RED='\\033[0;31m'
GREEN='\\033[0;32m'
YELLOW='\\033[1;33m'
CYAN='\\033[0;36m'
BOLD='\\033[1m'
RESET='\\033[0m'

ARCHIVE_NAME="${archive_name}"
PART_COUNT=${part_count}
EXPECTED_SHA="${checksum}"
ARCHIVE_SIZE="${archive_size_human}"

# ---------- locate the folder that contains this script ----------
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
cd "\$SCRIPT_DIR"

echo ""
echo -e "\${CYAN}\${BOLD}=== \${ARCHIVE_NAME} — Auto-Setup ===\${RESET}"
echo ""

# ---------- 1. create destination folder ----------
DEST_FOLDER="\${SCRIPT_DIR}/\${ARCHIVE_NAME}"
if [[ -d "\$DEST_FOLDER" ]]; then
    echo -e "\${YELLOW}  Folder already exists: \${DEST_FOLDER}\${RESET}"
else
    mkdir -p "\$DEST_FOLDER"
    echo -e "\${GREEN}  Created folder: \${DEST_FOLDER}\${RESET}"
fi

# ---------- 2. find and move all downloaded .bin files here ----------
echo -e "\n\${CYAN}  Moving downloaded .bin file(s) into folder...\${RESET}"
MOVED=0

if (( PART_COUNT > 1 )); then
    # expect numbered parts: archivename.part001.bin … partNNN.bin
    for f in "\${SCRIPT_DIR}/\${ARCHIVE_NAME}".part*.bin; do
        [[ -f "\$f" ]] || continue
        DEST="\${DEST_FOLDER}/\$(basename "\$f")"
        if [[ "\$f" != "\$DEST" ]]; then
            mv "\$f" "\$DEST"
            echo -e "    Moved: \$(basename "\$f")"
        else
            echo -e "    Already in place: \$(basename "\$f")"
        fi
        (( MOVED++ ))
    done
else
    # single file
    SINGLE="\${SCRIPT_DIR}/\${ARCHIVE_NAME}.bin"
    if [[ -f "\$SINGLE" ]]; then
        DEST="\${DEST_FOLDER}/\${ARCHIVE_NAME}.bin"
        if [[ "\$SINGLE" != "\$DEST" ]]; then
            mv "\$SINGLE" "\$DEST"
            echo -e "    Moved: \${ARCHIVE_NAME}.bin"
        else
            echo -e "    Already in place: \${ARCHIVE_NAME}.bin"
        fi
        MOVED=1
    fi
fi

if (( MOVED == 0 )); then
    echo -e "\${RED}  [ERROR] No .bin file(s) found in \${SCRIPT_DIR}\${RESET}"
    echo -e "  Make sure all downloaded attachments are in the same folder as this script."
    exit 1
fi

cd "\$DEST_FOLDER"

# ---------- 3. reassemble parts (if split) ----------
FINAL_ARCHIVE="\${DEST_FOLDER}/\${ARCHIVE_NAME}.tar.gz"

if (( PART_COUNT > 1 )); then
    echo -e "\n\${CYAN}  Reassembling \${PART_COUNT} parts...\${RESET}"

    FOUND_PARTS=( \$(ls "\${ARCHIVE_NAME}".part*.bin 2>/dev/null | sort) )
    if (( \${#FOUND_PARTS[@]} != PART_COUNT )); then
        echo -e "\${RED}  [ERROR] Expected \${PART_COUNT} parts, found \${#FOUND_PARTS[@]}.\${RESET}"
        echo -e "  Save all \${PART_COUNT} email attachments here before running this script."
        exit 1
    fi

    cat "\${ARCHIVE_NAME}".part*.bin > "\$FINAL_ARCHIVE"
    if [[ \$? -ne 0 ]]; then
        echo -e "\${RED}  Reassembly failed.\${RESET}"
        exit 1
    fi
    echo -e "  \${GREEN}Reassembled → \${FINAL_ARCHIVE}\${RESET}"
else
    # rename single .bin → .tar.gz
    mv "\${ARCHIVE_NAME}.bin" "\$FINAL_ARCHIVE"
    echo -e "\n\${GREEN}  Renamed attachment → \${ARCHIVE_NAME}.tar.gz\${RESET}"
fi

# ---------- 4. verify checksum ----------
echo -e "\n\${CYAN}  Verifying SHA-256 checksum...\${RESET}"
ACTUAL_SHA=\$(sha256sum "\$FINAL_ARCHIVE" | awk '{print \$1}')

if [[ "\$ACTUAL_SHA" == "\$EXPECTED_SHA" ]]; then
    echo -e "  \${GREEN}✓ Checksum OK\${RESET}"
else
    echo -e "  \${RED}✗ Checksum MISMATCH — file may be corrupt or incomplete.\${RESET}"
    echo -e "  Expected : \${EXPECTED_SHA}"
    echo -e "  Got      : \${ACTUAL_SHA}"
    exit 1
fi

# ---------- 5. extract ----------
echo -e "\n\${CYAN}  Extracting archive...\${RESET}"
tar -xvf "\$FINAL_ARCHIVE" -C "\$DEST_FOLDER"

if [[ \$? -ne 0 ]]; then
    echo -e "  \${RED}Extraction failed.\${RESET}"
    exit 1
fi
echo -e "  \${GREEN}✓ Extracted successfully.\${RESET}"

# ---------- 6. clean up downloaded files (.bin parts + this script) ----------
echo -e "\n\${CYAN}  Cleaning up downloaded files...\${RESET}"

if (( PART_COUNT > 1 )); then
    for part in "\${DEST_FOLDER}/\${ARCHIVE_NAME}".part*.bin; do
        [[ -f "\$part" ]] || continue
        rm -f "\$part"
        echo -e "    Removed: \$(basename "\$part")"
    done
else
    BIN_FILE="\${DEST_FOLDER}/\${ARCHIVE_NAME}.bin"
    if [[ -f "\$BIN_FILE" ]]; then
        rm -f "\$BIN_FILE"
        echo -e "    Removed: \${ARCHIVE_NAME}.bin"
    fi
fi

# Remove this setup script itself — job done
SELF="\${SCRIPT_DIR}/\$(basename "\${BASH_SOURCE[0]}")"
rm -f "\$SELF"
echo -e "    Removed: \$(basename "\$SELF")  (setup script)"

echo -e "  \${GREEN}✓ Cleanup done.\${RESET}"

# ---------- summary ----------
echo ""
echo -e "\${GREEN}\${BOLD}All done!\${RESET}"
echo -e "  Extracted files : \${BOLD}\${DEST_FOLDER}\${RESET}"
echo -e "  Archive kept at : \${BOLD}\${DEST_FOLDER}/\${ARCHIVE_NAME}.tar.gz\${RESET}"
echo -e "  The .tar.gz is ready whenever you need it again."
echo ""
RECV_SCRIPT
}


send_email() {
    local TO="$1"
    local ATTACH_FILE="$2"
    local PART_NUM="${3:-0}"
    local PART_TOTAL="${4:-0}"
    local INCLUDE_SETUP_SCRIPT="${5:-0}"   # 1 = attach the receiver setup script

    local ATTACH_FNAME
    ATTACH_FNAME=$(basename "$ATTACH_FILE")

    local SEND_FNAME
    if (( PART_NUM > 0 )); then
        local PADDED
        PADDED=$(printf "%03d" "$PART_NUM")
        SEND_FNAME="${ARCHIVE_NAME}.part${PADDED}.bin"
    else
        SEND_FNAME="${ARCHIVE_NAME}.bin"
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
    local BOUNDARY2="==s3cript_setup_$(date +%s%N)_${$}=="
    local MSG_ID="<$(date +%s%N).${$}@${SENDER_DOMAIN}>"
    local DATE_HDR
    DATE_HDR=$(date -R)

    # ── Build the receiver setup script content ──────────────────────────
    local SETUP_SCRIPT_NAME="${ARCHIVE_NAME}_setup.sh"
    local SETUP_SCRIPT_CONTENT
    SETUP_SCRIPT_CONTENT=$(build_receiver_script \
        "$ARCHIVE_NAME" "$PART_COUNT" "$CHECKSUM" "$ARCHIVE_SIZE_HUMAN")

    # ── Email body ────────────────────────────────────────────────────────
    local BODY
    if (( PART_NUM > 0 )); then
        BODY="Hi,

This is part ${PART_NUM} of ${PART_TOTAL} of '${ARCHIVE_NAME}'.
You need all ${PART_TOTAL} parts before you can open the files.

  Part file  : ${SEND_FNAME}
  Part size  : ${PART_SIZE_HUMAN}
  Total size : ${ARCHIVE_SIZE_HUMAN} (full archive)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  QUICK START — automatic setup (Linux / Mac)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  1. Download all ${PART_TOTAL} part attachments from your inbox.
  2. Also save the '${SETUP_SCRIPT_NAME}' attachment
     (included in Part 1 of this email series).
  3. Put every file in the same folder (e.g. ~/Downloads).
  4. Open a terminal in that folder and run:

       chmod +x ${SETUP_SCRIPT_NAME}
       ./${SETUP_SCRIPT_NAME}

  The script will automatically:
    • Create a new folder called '${ARCHIVE_NAME}/'
    • Move all .bin parts into it
    • Reassemble and verify the archive
    • Extract everything for you
    • Clean up the temporary files"

    else
        BODY="Hi,

Compressed archive attached — see details below.

  File     : ${SEND_FNAME}
  Size     : ${ARCHIVE_SIZE_HUMAN}
  Ratio    : ${RATIO_LABEL# }

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  QUICK START — automatic setup (Linux / Mac)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  1. Download both attachments into the same folder
     (e.g. ~/Downloads).
  2. Open a terminal in that folder and run:

       chmod +x ${SETUP_SCRIPT_NAME}
       ./${SETUP_SCRIPT_NAME}

  The script will automatically:
    • Create a new folder called '${ARCHIVE_NAME}/'
    • Move the .bin attachment into it
    • Verify the SHA-256 checksum
    • Extract everything for you
    • Clean up the temporary files"

    fi

    {
        printf "From: %s <%s>\r\n"      "$SENDER_NAME" "$SENDER"
        printf "To: %s\r\n"             "$TO"
        printf "Reply-To: %s\r\n"       "$SENDER"
        printf "Subject: %s\r\n"        "$SUBJECT"
        printf "Date: %s\r\n"           "$DATE_HDR"
        printf "Message-ID: %s\r\n"     "$MSG_ID"
        printf "X-Mailer: S3cript/5.0\r\n"
        printf "X-Priority: 3\r\n"
        printf "Importance: Normal\r\n"
        printf "Content-Language: en-US\r\n"
        printf "MIME-Version: 1.0\r\n"
        printf "Content-Type: multipart/mixed; boundary=\"%s\"\r\n" "$BOUNDARY"
        printf "\r\n"

        # ── Part 1: plain text body ──────────────────────────────────────
        printf -- "--%s\r\n"   "$BOUNDARY"
        printf "Content-Type: text/plain; charset=utf-8\r\n"
        printf "Content-Transfer-Encoding: 7bit\r\n"
        printf "\r\n"
        printf "%s\r\n\r\n" "$BODY"

        # ── Part 2: setup script (only on first/only email) ──────────────
        if (( INCLUDE_SETUP_SCRIPT == 1 )); then
            printf -- "--%s\r\n"   "$BOUNDARY"
            printf "Content-Type: text/x-shellscript; name=\"%s\"\r\n" "$SETUP_SCRIPT_NAME"
            printf "Content-Transfer-Encoding: base64\r\n"
            printf "Content-Disposition: attachment; filename=\"%s\"\r\n" "$SETUP_SCRIPT_NAME"
            printf "\r\n"
            printf "%s" "$SETUP_SCRIPT_CONTENT" | base64 | fold -w 76
            printf "\r\n"
        fi

        # ── Part 3: the archive / part attachment ────────────────────────
        printf -- "--%s\r\n"   "$BOUNDARY"
        printf "Content-Type: application/octet-stream; name=\"%s\"\r\n" "$SEND_FNAME"
        printf "Content-Transfer-Encoding: base64\r\n"
        printf "Content-Disposition: attachment; filename=\"%s\"\r\n" "$SEND_FNAME"
        printf "\r\n"
        base64 "$ATTACH_FILE" | fold -w 76
        printf "\r\n"

        printf -- "--%s--\r\n" "$BOUNDARY"

    } | msmtp --account=default --read-envelope-from "$TO" 2>&1

    return $?
}


echo ""
read -rp "$(echo -e "${BOLD}Send archive via email?${RESET} (y/N): ")" SEND_CHOICE
if [[ ! "$SEND_CHOICE" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}  Skipping email. File is at: ${ARCHIVE_FILE}${RESET}\n"
    exit 0
fi


RECIPIENTS=()
echo ""

while true; do
    if [[ ${#RECIPIENTS[@]} -eq 0 ]]; then PROMPT="  Recipient email: "
    else PROMPT="  Add another (blank to finish): "
    fi
    read -rp "$PROMPT" EMAIL

    if [[ -z "$EMAIL" ]]; then
        [[ ${#RECIPIENTS[@]} -eq 0 ]] && { echo -e "${RED}  Need at least one recipient.${RESET}"; continue; }
        break
    fi

    if [[ ! "$EMAIL" =~ ^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$ ]]; then
        echo -e "${RED}  Doesn't look like a valid email: \"$EMAIL\"${RESET}"; continue
    fi

    RECIPIENTS+=("$EMAIL")
    echo -e "${GREEN}  Added: $EMAIL${RESET}"
done


IS_SPLIT=$(( PART_COUNT > 1 ? 1 : 0 ))

echo ""
echo -e "${CYAN}Sending...${RESET}"
echo -e "  From       : ${SENDER_NAME} <${SENDER}>"
if (( IS_SPLIT )); then
    echo -e "  Parts      : ${PART_COUNT} (each ≤${SPLIT_CHUNK_MB} MB raw, ≤25 MB encoded)"
    echo -e "  Setup script included in Part 1"
else
    echo -e "  Attachment : $(basename "$ARCHIVE_FILE")  (${ARCHIVE_SIZE_HUMAN})"
    echo -e "  Setup script included alongside archive"
fi
echo -e "  Recipients : ${#RECIPIENTS[@]}"
echo ""

FAILED=()

for ADDR in "${RECIPIENTS[@]}"; do
    echo -e "  → ${ADDR}"

    ADDR_FAILED=0

    for i in "${!SEND_PARTS[@]}"; do
        # Include the setup script only in the very first email (part 1 or single)
        INCL_SETUP=$(( i == 0 ? 1 : 0 ))

        if (( IS_SPLIT )); then
            PNUM=$(( i + 1 ))
            PTOTAL=$PART_COUNT
            printf "      Part %d/%d ... " "$PNUM" "$PTOTAL"
        else
            PNUM=0
            PTOTAL=0
            printf "      Sending ... "
        fi

        ERR=$(send_email "$ADDR" "${SEND_PARTS[$i]}" "$PNUM" "$PTOTAL" "$INCL_SETUP" 2>&1)
        STATUS=$?

        if [[ $STATUS -eq 0 ]]; then
            if (( INCL_SETUP )); then
                echo -e "${GREEN}✓ Sent  (+ setup script attached)${RESET}"
            else
                echo -e "${GREEN}✓ Sent${RESET}"
            fi
        else
            echo -e "${RED}✗ Failed${RESET}"
            echo -e "        ${RED}${ERR}${RESET}"
            ADDR_FAILED=1
        fi

        if (( IS_SPLIT && i < PART_COUNT - 1 )); then
            sleep 2
        fi
    done

    [[ $ADDR_FAILED -eq 1 ]] && FAILED+=("$ADDR")
    sleep 1
done


echo ""

if [[ ${#FAILED[@]} -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}Sent to all ${#RECIPIENTS[@]} recipient(s).${RESET}"
    echo ""
    echo -e "${CYAN}  Tell your recipients to:${RESET}"
    if (( IS_SPLIT )); then
        echo -e "  1. Save all ${PART_COUNT} .bin parts + the '${ARCHIVE_NAME}_setup.sh' file"
        echo -e "     (from Part 1) into one folder."
    else
        echo -e "  1. Save the .bin attachment + '${ARCHIVE_NAME}_setup.sh' into one folder."
    fi
    echo -e "  2. Run:"
    echo -e "       ${BOLD}chmod +x ${ARCHIVE_NAME}_setup.sh${RESET}"
    echo -e "       ${BOLD}./${ARCHIVE_NAME}_setup.sh${RESET}"
    echo -e "  3. Done — the script creates '${ARCHIVE_NAME}/', moves files in,"
    echo -e "     verifies the checksum, and extracts everything automatically."
else
    echo -e "${YELLOW}${BOLD}Couldn't reach ${#FAILED[@]} recipient(s):${RESET}"
    for ADDR in "${FAILED[@]}"; do
        echo -e "  ${RED}✗ $ADDR${RESET}"
    done
    echo -e "\n  Archive is still at: ${ARCHIVE_FILE}"
    echo -e "  Check ${CYAN}~/.msmtp.log${RESET} for the SMTP error details."
fi

echo ""
