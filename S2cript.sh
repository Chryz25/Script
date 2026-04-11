#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# check deps first
if ! command -v 7z &> /dev/null; then
    echo -e "${RED}[!] 7z not found. Run: sudo apt install p7zip-full${RESET}"
    exit 1
fi

if ! command -v msmtp &> /dev/null; then
    echo -e "${RED}[!] msmtp not found. Run: sudo apt install msmtp msmtp-mta ca-certificates${RESET}"
    exit 1
fi

if [[ ! -f "$HOME/.msmtprc" ]]; then
    echo -e "${RED}[!] No msmtp config found at ~/.msmtprc. Set that up first.${RESET}"
    exit 1
fi

# get folder
while true; do
    read -rp "Folder to compress: " FOLDER_PATH
    FOLDER_PATH="${FOLDER_PATH%/}"

    if [[ -z "$FOLDER_PATH" ]]; then
        echo -e "${RED}Can't be empty, try again.${RESET}"
    elif [[ ! -d "$FOLDER_PATH" ]]; then
        echo -e "${RED}Not found: $FOLDER_PATH${RESET}"
    else
        echo -e "${GREEN}OK${RESET}"
        break
    fi
done

# archive name
DEFAULT_NAME="$(basename "$FOLDER_PATH")"

while true; do
    read -rp "Archive name [${DEFAULT_NAME}]: " ARCHIVE_NAME
    ARCHIVE_NAME="${ARCHIVE_NAME:-$DEFAULT_NAME}"
    ARCHIVE_NAME="${ARCHIVE_NAME%.7z}"

    if [[ "$ARCHIVE_NAME" =~ [/\\] ]]; then
        echo -e "${RED}No slashes in the name please.${RESET}"
    else
        echo -e "${GREEN}Will save as: ${ARCHIVE_NAME}.7z${RESET}"
        break
    fi
done

# output dir
read -rp "Where to save it? (blank = current dir): " OUTPUT_DIR
OUTPUT_DIR="${OUTPUT_DIR%/}"
OUTPUT_DIR="${OUTPUT_DIR:-.}"

if [[ ! -d "$OUTPUT_DIR" ]]; then
    echo "Directory doesn't exist, creating..."
    mkdir -p "$OUTPUT_DIR"
fi

FULL_OUTPUT="${OUTPUT_DIR}/${ARCHIVE_NAME}.7z"

# overwrite?
if [[ -f "$FULL_OUTPUT" ]]; then
    read -rp "File already exists. Overwrite? (y/N): " CONFIRM
    [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && echo "Cancelled." && exit 0
    rm -f "$FULL_OUTPUT"
fi

echo ""
echo -e "${CYAN}Compressing... ${FOLDER_PATH} -> ${FULL_OUTPUT}${RESET}"
echo ""

7z a -mx=9 "$FULL_OUTPUT" "$FOLDER_PATH"

if [[ $? -ne 0 ]]; then
    echo -e "${RED}Compression failed.${RESET}"
    exit 1
fi

SIZE=$(du -sh "$FULL_OUTPUT" 2>/dev/null | cut -f1)
echo ""
echo -e "${GREEN}Done! ${FULL_OUTPUT} (${SIZE})${RESET}"
echo ""

# email stuff
SENDER=$(grep -m1 "^from" "$HOME/.msmtprc" | awk '{print $2}')
SENDER="${SENDER:-$(whoami)@$(hostname)}"

send_email() {
    local TO="$1"
    local SUBJECT="Compressed Archive: ${ARCHIVE_NAME}.7z"
    local FNAME
    FNAME=$(basename "$FULL_OUTPUT")
    local BOUNDARY="boundary_$(date +%s)_$$"
    local B64
    B64=$(base64 "$FULL_OUTPUT" | fold -w 76)

    local BODY="Hello,

Attached is the compressed archive: ${FNAME}
Size: ${SIZE}"

    {
        printf "From: %s\r\n"       "$SENDER"
        printf "To: %s\r\n"         "$TO"
        printf "Subject: %s\r\n"    "$SUBJECT"
        printf "MIME-Version: 1.0\r\n"
        printf "Content-Type: multipart/mixed; boundary=\"%s\"\r\n" "$BOUNDARY"
        printf "\r\n"
        printf -- "--%s\r\n"        "$BOUNDARY"
        printf "Content-Type: text/plain; charset=utf-8\r\n"
        printf "Content-Transfer-Encoding: 7bit\r\n"
        printf "\r\n"
        printf "%s\r\n"             "$BODY"
        printf "\r\n"
        printf -- "--%s\r\n"        "$BOUNDARY"
        printf "Content-Type: application/octet-stream; name=\"%s\"\r\n" "$FNAME"
        printf "Content-Transfer-Encoding: base64\r\n"
        printf "Content-Disposition: attachment; filename=\"%s\"\r\n" "$FNAME"
        printf "\r\n"
        printf "%s\r\n"             "$B64"
        printf "\r\n"
        printf -- "--%s--\r\n"      "$BOUNDARY"
    } | msmtp --account=default --read-envelope-from "$TO" 2>&1

    return $?
}

read -rp "Send via email? (y/N): " SEND_CHOICE
if [[ ! "$SEND_CHOICE" =~ ^[Yy]$ ]]; then
    echo "Skipping email."
    exit 0
fi

RECIPIENTS=()
echo ""

while true; do
    if [[ ${#RECIPIENTS[@]} -eq 0 ]]; then
        read -rp "Recipient email: " EMAIL
    else
        read -rp "Add another (blank to stop): " EMAIL
        [[ -z "$EMAIL" ]] && break
    fi

    [[ -z "$EMAIL" ]] && echo "Need at least one." && continue

    if [[ ! "$EMAIL" =~ ^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$ ]]; then
        echo -e "${RED}Bad email: $EMAIL${RESET}"
        continue
    fi

    RECIPIENTS+=("$EMAIL")
    echo -e "${GREEN}Added: $EMAIL${RESET}"
done

echo ""
echo -e "${CYAN}Sending to: ${RECIPIENTS[*]}${RESET}"
echo -e "From: $SENDER | File: $FULL_OUTPUT ($SIZE)"
echo ""

FAILED=()

for ADDR in "${RECIPIENTS[@]}"; do
    echo -ne "  -> $ADDR ... "
    OUT=$(send_email "$ADDR" 2>&1)
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}sent${RESET}"
    else
        echo -e "${RED}FAILED${RESET}"
        echo "     $OUT"
        FAILED+=("$ADDR")
    fi
done

echo ""

if [[ ${#FAILED[@]} -eq 0 ]]; then
    echo -e "${GREEN}All sent.${RESET}"
else
    echo -e "${YELLOW}Failed recipients:${RESET}"
    for F in "${FAILED[@]}"; do
        echo "  - $F"
    done
    echo ""
    echo "Check ~/.msmtp.log for details."
fi

echo ""
