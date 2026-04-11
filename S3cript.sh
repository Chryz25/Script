#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Dependency Check ───────────────────────────────────────────────────────

if ! command -v 7z &> /dev/null; then
    echo -e "${RED}[ERROR]${RESET} 7-Zip is not installed."
    echo -e "        Run: ${YELLOW}sudo apt install p7zip-full${RESET}"
    exit 1
fi

if ! command -v msmtp &> /dev/null; then
    echo -e "${RED}[ERROR]${RESET} msmtp is not installed."
    echo -e "        Run: ${YELLOW}sudo apt install msmtp msmtp-mta ca-certificates${RESET}"
    exit 1
fi

if [[ ! -f "$HOME/.msmtprc" ]]; then
    echo -e "${RED}[ERROR]${RESET} No msmtp config found at ~/.msmtprc"
    echo -e "        Please configure msmtp before running this script."
    exit 1
fi

# ─── Folder to Compress ─────────────────────────────────────────────────────

while true; do
    read -rp "$(echo -e "${BOLD}Folder to compress:${RESET} ")" FOLDER_PATH
    FOLDER_PATH="${FOLDER_PATH%/}"

    if [[ -z "$FOLDER_PATH" ]]; then
        echo -e "${RED}  Folder path cannot be empty.${RESET}\n"
    elif [[ ! -d "$FOLDER_PATH" ]]; then
        echo -e "${RED}  Folder not found: \"$FOLDER_PATH\"${RESET}\n"
    else
        echo -e "${GREEN}  Found.${RESET}\n"
        break
    fi
done

# ─── Archive Name ───────────────────────────────────────────────────────────

DEFAULT_NAME="$(basename "$FOLDER_PATH")"

while true; do
    read -rp "$(echo -e "${BOLD}Archive name${RESET} [${DEFAULT_NAME}]: ")" ARCHIVE_NAME
    ARCHIVE_NAME="${ARCHIVE_NAME:-$DEFAULT_NAME}"
    ARCHIVE_NAME="${ARCHIVE_NAME%.7z}"

    if [[ "$ARCHIVE_NAME" =~ [/\\] ]]; then
        echo -e "${RED}  Name must not contain slashes.${RESET}\n"
    else
        echo -e "${GREEN}  Will save as: ${ARCHIVE_NAME}.7z${RESET}\n"
        break
    fi
done

# ─── Output Directory ───────────────────────────────────────────────────────

read -rp "$(echo -e "${BOLD}Output directory${RESET} (blank = current dir): ")" OUTPUT_DIR
OUTPUT_DIR="${OUTPUT_DIR%/}"
OUTPUT_DIR="${OUTPUT_DIR:-.}"

if [[ ! -d "$OUTPUT_DIR" ]]; then
    echo -e "${YELLOW}  Directory not found. Creating it...${RESET}"
    mkdir -p "$OUTPUT_DIR"
fi

FULL_OUTPUT="${OUTPUT_DIR}/${ARCHIVE_NAME}.7z"

# ─── Overwrite Check ────────────────────────────────────────────────────────

if [[ -f "$FULL_OUTPUT" ]]; then
    echo -e "\n${YELLOW}Warning: $FULL_OUTPUT already exists.${RESET}"
    read -rp "  Overwrite? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "${RED}  Cancelled.${RESET}"
        exit 0
    fi
    rm -f "$FULL_OUTPUT"
fi

# ─── Compress ───────────────────────────────────────────────────────────────

echo -e "\n${CYAN}Compressing...${RESET}"
echo -e "  $FOLDER_PATH  →  $FULL_OUTPUT\n"

7z a -mx=9 "$FULL_OUTPUT" "$FOLDER_PATH"

if [[ $? -ne 0 ]]; then
    echo -e "\n${RED}Compression failed.${RESET}"
    exit 1
fi

SIZE=$(du -sh "$FULL_OUTPUT" 2>/dev/null | cut -f1)
echo -e "\n${GREEN}${BOLD}Archive created successfully.${RESET}"
echo -e "  File : $FULL_OUTPUT"
echo -e "  Size : $SIZE\n"

# ─── Email Setup ────────────────────────────────────────────────────────────

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
    local BODY
    BODY="Hello,

Please find the attached compressed archive: ${FNAME}
Archive size: ${SIZE}"

    {
        printf "From: %s\r\n"       "$SENDER"
        printf "To: %s\r\n"         "$TO"
        printf "Subject: %s\r\n"    "$SUBJECT"
        printf "MIME-Version: 1.0\r\n"
        printf "Content-Type: multipart/mixed; boundary=\"%s\"\r\n" "$BOUNDARY"
        printf "\r\n"

        # Plain text body
        printf -- "--%s\r\n"        "$BOUNDARY"
        printf "Content-Type: text/plain; charset=utf-8\r\n"
        printf "Content-Transfer-Encoding: 7bit\r\n"
        printf "\r\n"
        printf "%s\r\n"             "$BODY"
        printf "\r\n"

        # Attachment
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

# ─── Ask to Send Email ──────────────────────────────────────────────────────

read -rp "$(echo -e "${BOLD}Send archive via email?${RESET} (y/N): ")" SEND_CHOICE
if [[ ! "$SEND_CHOICE" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}  Email skipped.${RESET}\n"
    exit 0
fi

# ─── Collect Recipients ─────────────────────────────────────────────────────

RECIPIENTS=()
echo ""

while true; do
    if [[ ${#RECIPIENTS[@]} -eq 0 ]]; then
        read -rp "  Recipient email: " EMAIL
    else
        read -rp "  Add another recipient (blank to continue): " EMAIL
        [[ -z "$EMAIL" ]] && break
    fi

    if [[ -z "$EMAIL" ]]; then
        echo -e "${RED}  At least one recipient is required.${RESET}"
        continue
    fi

    if [[ ! "$EMAIL" =~ ^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$ ]]; then
        echo -e "${RED}  Invalid email: \"$EMAIL\"${RESET}"
        continue
    fi

    RECIPIENTS+=("$EMAIL")
    echo -e "${GREEN}  Added: $EMAIL${RESET}"
done

# ─── Send ───────────────────────────────────────────────────────────────────

echo ""
echo -e "${CYAN}Sending...${RESET}"
echo -e "  From : $SENDER"
echo -e "  File : $FULL_OUTPUT ($SIZE)"
echo -e "  To   : ${RECIPIENTS[*]}\n"

FAILED=()

for ADDR in "${RECIPIENTS[@]}"; do
    echo -ne "  -> $ADDR ... "
    ERR=$(send_email "$ADDR" 2>&1)
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}Sent${RESET}"
    else
        echo -e "${RED}Failed${RESET}"
        echo -e "    ${RED}$ERR${RESET}"
        FAILED+=("$ADDR")
    fi
done

# ─── Summary ────────────────────────────────────────────────────────────────

echo ""

if [[ ${#FAILED[@]} -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}All emails sent successfully.${RESET}"
    echo -e "  Recipients : ${RECIPIENTS[*]}"
    echo -e "  Attachment : ${ARCHIVE_NAME}.7z ($SIZE)"
else
    echo -e "${YELLOW}${BOLD}Some emails failed to send:${RESET}"
    for ADDR in "${FAILED[@]}"; do
        echo -e "  ${RED}x $ADDR${RESET}"
    done
    echo -e "\n  Check ${CYAN}~/.msmtp.log${RESET} for details."
fi

echo ""
