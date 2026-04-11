#!/bin/bash

# ════════════════════════════════════════════════════
# Colors
# ════════════════════════════════════════════════════
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ════════════════════════════════════════════════════
# ── Check dependencies ──
# ════════════════════════════════════════════════════
if ! command -v 7z &> /dev/null; then
    echo -e "${RED}[ERROR]${RESET} 7-Zip is not installed."
    echo -e "        Install it with: ${YELLOW}sudo apt install p7zip-full${RESET}"
    exit 1
fi

if ! command -v msmtp &> /dev/null; then
    echo -e "${RED}[ERROR]${RESET} msmtp is not installed."
    echo -e "        Install it with: ${YELLOW}sudo apt install msmtp msmtp-mta ca-certificates${RESET}"
    exit 1
fi

if [[ ! -f "$HOME/.msmtprc" ]]; then
    echo -e "${RED}[ERROR]${RESET} msmtp config not found at ~/.msmtprc"
    echo -e "        Please configure msmtp first before running this script."
    exit 1
fi

# ════════════════════════════════════════════════════
# ── Ask for the folder to compress ──
# ════════════════════════════════════════════════════
while true; do
    echo -e "${BOLD}What folder do you want to compress?${RESET}"
    read -rp "   Folder path: " FOLDER_PATH

    FOLDER_PATH="${FOLDER_PATH%/}"

    if [[ -z "$FOLDER_PATH" ]]; then
        echo -e "${RED}   [!] Folder path cannot be empty. Try again.${RESET}\n"
    elif [[ ! -d "$FOLDER_PATH" ]]; then
        echo -e "${RED}   [!] Folder not found: \"$FOLDER_PATH\". Try again.${RESET}\n"
    else
        echo -e "${GREEN}   ✔ Folder found.${RESET}\n"
        break
    fi
done

# ════════════════════════════════════════════════════
# ── Ask for the output archive name ──
# ════════════════════════════════════════════════════
DEFAULT_NAME="$(basename "$FOLDER_PATH")"

while true; do
    echo -e "${BOLD}What name for the compressed file?${RESET}"
    read -rp "   Archive name (default: ${DEFAULT_NAME}): " ARCHIVE_NAME

    if [[ -z "$ARCHIVE_NAME" ]]; then
        ARCHIVE_NAME="$DEFAULT_NAME"
    fi

    ARCHIVE_NAME="${ARCHIVE_NAME%.7z}"

    if [[ "$ARCHIVE_NAME" =~ [/\\] ]]; then
        echo -e "${RED}   [!] Archive name must not contain slashes. Try again.${RESET}\n"
    else
        echo -e "${GREEN}   ✔ Archive name set to: ${ARCHIVE_NAME}.7z${RESET}\n"
        break
    fi
done

# ════════════════════════════════════════════════════
# ── Ask where to save the archive ──
# ════════════════════════════════════════════════════
echo -e "${BOLD}Where to save the archive?${RESET}"
read -rp "   Output directory (leave blank = current directory): " OUTPUT_DIR

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="."
fi

OUTPUT_DIR="${OUTPUT_DIR%/}"

if [[ ! -d "$OUTPUT_DIR" ]]; then
    echo -e "${YELLOW}   [!] Output directory does not exist. Creating it...${RESET}"
    mkdir -p "$OUTPUT_DIR"
fi

FULL_OUTPUT="${OUTPUT_DIR}/${ARCHIVE_NAME}.7z"

# ════════════════════════════════════════════════════
# ── Overwrite check ──
# ════════════════════════════════════════════════════
if [[ -f "$FULL_OUTPUT" ]]; then
    echo ""
    echo -e "${YELLOW}⚠  File already exists: ${FULL_OUTPUT}${RESET}"
    read -rp "   Overwrite? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "${RED}   Cancelled.${RESET}"
        exit 0
    fi
    rm -f "$FULL_OUTPUT"
fi

# ════════════════════════════════════════════════════
# ── Compress ──
# ════════════════════════════════════════════════════
echo ""
echo -e "${CYAN}⚙  Compressing...${RESET}"
echo -e "   ${FOLDER_PATH}  →  ${FULL_OUTPUT}"
echo ""

7z a -mx=9 "$FULL_OUTPUT" "$FOLDER_PATH"

if [[ $? -eq 0 ]]; then
    SIZE=$(du -sh "$FULL_OUTPUT" 2>/dev/null | cut -f1)
    echo ""
    echo -e "${GREEN}${BOLD}✅ Done! Archive created successfully.${RESET}"
    echo -e "   📦 File : ${FULL_OUTPUT}"
    echo -e "   📏 Size : ${SIZE}"
else
    echo ""
    echo -e "${RED}${BOLD}❌ Compression failed. See errors above.${RESET}"
    exit 1
fi

echo ""

# ════════════════════════════════════════════════════
# ── EMAIL SECTION (msmtp) ──
# ════════════════════════════════════════════════════

# ── Read sender address from ~/.msmtprc ──
SENDER=$(grep -m1 "^from" "$HOME/.msmtprc" | awk '{print $2}')
if [[ -z "$SENDER" ]]; then
    SENDER="$(whoami)@$(hostname)"
fi

# ── Build raw MIME email with attachment and send ──
build_and_send_email() {
    local RECIPIENT="$1"
    local SUBJECT="Compressed Archive: ${ARCHIVE_NAME}.7z"
    local FILENAME
    FILENAME=$(basename "$FULL_OUTPUT")
    local BOUNDARY="==BOUNDARY_$(date +%s%N)=="
    local ENCODED_FILE
    ENCODED_FILE=$(base64 "$FULL_OUTPUT" | fold -w 76)
    local BODY_TEXT
    BODY_TEXT="Hello,

Please find the attached compressed archive: ${FILENAME}
Archive size  : ${SIZE}"

    # ── Build full MIME message and pipe into msmtp ──
    {
        printf "From: %s\r\n"        "$SENDER"
        printf "To: %s\r\n"          "$RECIPIENT"
        printf "Subject: %s\r\n"     "$SUBJECT"
        printf "MIME-Version: 1.0\r\n"
        printf "Content-Type: multipart/mixed; boundary=\"%s\"\r\n" "$BOUNDARY"
        printf "\r\n"

        # Plain text body part
        printf -- "--%s\r\n"         "$BOUNDARY"
        printf "Content-Type: text/plain; charset=utf-8\r\n"
        printf "Content-Transfer-Encoding: 7bit\r\n"
        printf "\r\n"
        printf "%s\r\n"              "$BODY_TEXT"
        printf "\r\n"

        # Attachment part
        printf -- "--%s\r\n"         "$BOUNDARY"
        printf "Content-Type: application/octet-stream; name=\"%s\"\r\n" "$FILENAME"
        printf "Content-Transfer-Encoding: base64\r\n"
        printf "Content-Disposition: attachment; filename=\"%s\"\r\n" "$FILENAME"
        printf "\r\n"
        printf "%s\r\n"              "$ENCODED_FILE"
        printf "\r\n"

        # Closing boundary
        printf -- "--%s--\r\n"       "$BOUNDARY"

    } | msmtp --account=default --read-envelope-from "$RECIPIENT" 2>&1

    return $?
}

# ════════════════════════════════════════════════════
# ── Ask if user wants to send via email ──
# ════════════════════════════════════════════════════
echo -e "${BOLD}Do you want to send the archive via email?${RESET}"
read -rp "   Send email? (y/N): " SEND_EMAIL_CHOICE

if [[ ! "$SEND_EMAIL_CHOICE" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}   Email skipped.${RESET}"
    echo ""
    exit 0
fi

# ════════════════════════════════════════════════════
# ── Collect recipients ──
# ════════════════════════════════════════════════════
ALL_RECIPIENTS=()

echo ""

while true; do
    if [[ ${#ALL_RECIPIENTS[@]} -eq 0 ]]; then
        echo -e "${BOLD}Enter the recipient email address:${RESET}"
        read -rp "   To: " INPUT_EMAIL
    else
        read -rp "   Add another recipient (leave blank to continue): " INPUT_EMAIL
        [[ -z "$INPUT_EMAIL" ]] && break
    fi

    if [[ -z "$INPUT_EMAIL" ]]; then
        echo -e "${RED}   [!] At least one recipient is required.${RESET}"
        continue
    fi

    if [[ ! "$INPUT_EMAIL" =~ ^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$ ]]; then
        echo -e "${RED}   [!] Invalid email format: \"${INPUT_EMAIL}\". Try again.${RESET}"
        continue
    fi

    ALL_RECIPIENTS+=("$INPUT_EMAIL")
    echo -e "${GREEN}   ✔ Added: ${INPUT_EMAIL}${RESET}"
done

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${CYAN}📧 Sending archive...${RESET}"
echo -e "   From    : ${SENDER}"
echo -e "   File    : ${FULL_OUTPUT} (${SIZE})"
echo -e "   To      : ${ALL_RECIPIENTS[*]}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""

# ════════════════════════════════════════════════════
# ── Send to each recipient ──
# ════════════════════════════════════════════════════
SEND_SUCCESS=true
FAILED_LIST=()

for ADDR in "${ALL_RECIPIENTS[@]}"; do
    echo -ne "   → Sending to ${ADDR}... "
    SEND_OUTPUT=$(build_and_send_email "$ADDR" 2>&1)
    SEND_EXIT=$?

    if [[ $SEND_EXIT -eq 0 ]]; then
        echo -e "${GREEN}✔ Sent${RESET}"
    else
        echo -e "${RED}✘ Failed${RESET}"
        echo -e "     ${RED}↳ Error: ${SEND_OUTPUT}${RESET}"
        SEND_SUCCESS=false
        FAILED_LIST+=("$ADDR")
    fi
done

echo ""

# ════════════════════════════════════════════════════
# ── Final Summary ──
# ════════════════════════════════════════════════════
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

if [[ "$SEND_SUCCESS" == true ]]; then
    echo -e "${GREEN}${BOLD}📬 All emails sent successfully!${RESET}"
    echo -e "   Recipients : ${ALL_RECIPIENTS[*]}"
    echo -e "   Attachment : ${ARCHIVE_NAME}.7z (${SIZE})"
else
    echo -e "${YELLOW}${BOLD}⚠  Some emails failed to send:${RESET}"
    for FAIL in "${FAILED_LIST[@]}"; do
        echo -e "   ${RED}✘ ${FAIL}${RESET}"
    done
    echo ""
    echo -e "   Check the msmtp log for details:"
    echo -e "   ${CYAN}cat ~/.msmtp.log${RESET}"
fi

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
