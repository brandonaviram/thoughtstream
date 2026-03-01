#!/bin/bash
# thoughtstream — Voice memo → AI summary → Slack
# https://github.com/btaelor/thoughtstream
#
# Usage: ./thoughtstream.sh /path/to/memo.m4a
#        ./thoughtstream.sh /path/to/memo.qta
#
# Requires: .env file with GROQ_API_KEY, SLACK_BOT_TOKEN, SLACK_CHANNEL_ID
set -euo pipefail

# ============================================================
# Load environment
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${THOUGHTSTREAM_ENV_FILE:-$SCRIPT_DIR/.env}"

if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    set -a; source "$ENV_FILE"; set +a
fi

# Required
GROQ_API_KEY="${GROQ_API_KEY:?GROQ_API_KEY is required (see .env.example)}"
SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:?SLACK_BOT_TOKEN is required (see .env.example)}"
SLACK_CHANNEL_ID="${SLACK_CHANNEL_ID:?SLACK_CHANNEL_ID is required (see .env.example)}"

# Optional — paths default to ~/thoughtstream-data if not set
DATA_DIR="${THOUGHTSTREAM_DATA_DIR:-$HOME/thoughtstream-data}"
LOG_DIR="$DATA_DIR/logs"
INBOX_DIR="$DATA_DIR/inbox"

# ============================================================
# Setup
# ============================================================
INPUT_FILE="$1"
FILENAME=$(basename "$INPUT_FILE")
TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
DATE=$(date +%Y-%m-%d)
LOG_FILE="$LOG_DIR/$(date +%Y-%m).log"
PROCESSED_FILE="$LOG_DIR/processed.txt"

mkdir -p "$LOG_DIR" "$INBOX_DIR"
touch "$PROCESSED_FILE"

# ============================================================
# Convert .qta → .m4a if needed (macOS Voice Memos internal format)
# ============================================================
TEMP_FILE=""
if [[ "$INPUT_FILE" == *.qta ]]; then
    TEMP_FILE=$(mktemp /tmp/thoughtstream-XXXXXX.m4a)
    /opt/homebrew/bin/ffmpeg -i "$INPUT_FILE" "$TEMP_FILE" -y -loglevel error 2>>"$LOG_FILE" || {
        echo "[$TIMESTAMP] ERROR: ffmpeg conversion failed for $FILENAME" >> "$LOG_FILE"
        rm -f "$TEMP_FILE"
        exit 1
    }
    M4A_FILE="$TEMP_FILE"
    echo "[$TIMESTAMP] Converted QTA→M4A: $FILENAME" >> "$LOG_FILE"
elif [[ "$INPUT_FILE" == *.m4a ]]; then
    M4A_FILE="$INPUT_FILE"
else
    exit 0
fi

trap 'rm -f "$TEMP_FILE"' EXIT

if [ ! -r "$M4A_FILE" ]; then
    echo "[$TIMESTAMP] ERROR: File not readable - $M4A_FILE" >> "$LOG_FILE"
    exit 1
fi

echo "[$TIMESTAMP] Starting: $FILENAME" >> "$LOG_FILE"

# ============================================================
# Wait for file to stabilize (Folder Action fires before write completes)
# ============================================================
MAX_WAIT=60
ATTEMPT=0
SIZE_BEFORE=0
SIZE_STABLE_COUNT=0

while [ $ATTEMPT -lt $MAX_WAIT ]; do
    SIZE_CURRENT=$(stat -f%z "$M4A_FILE" 2>/dev/null || echo "0")
    if [ "$SIZE_CURRENT" = "$SIZE_BEFORE" ]; then
        SIZE_STABLE_COUNT=$((SIZE_STABLE_COUNT + 1))
        [ $SIZE_STABLE_COUNT -ge 2 ] && break
    else
        SIZE_STABLE_COUNT=0
    fi
    SIZE_BEFORE="$SIZE_CURRENT"
    sleep 1
    ATTEMPT=$((ATTEMPT + 1))
done

echo "[$TIMESTAMP] File stable after ${ATTEMPT}s: $FILENAME" >> "$LOG_FILE"

# ============================================================
# Deduplicate
# ============================================================
FINAL_SIZE=$(stat -f%z "$M4A_FILE" 2>/dev/null || echo "0")
FILE_KEY="$FILENAME|$FINAL_SIZE"

if grep -q "^$FILE_KEY$" "$PROCESSED_FILE" 2>/dev/null; then
    echo "[$TIMESTAMP] SKIP: Already processed - $FILENAME" >> "$LOG_FILE"
    exit 0
fi

# ============================================================
# Transcribe via Groq Whisper
# ============================================================
TRANSCRIPT=""
RETRY_COUNT=0
MAX_RETRIES=3

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    TRANSCRIPT=$(python3 - "$M4A_FILE" "$GROQ_API_KEY" 2>&1 << 'ENDPYTHON'
import requests
import sys

m4a_file = sys.argv[1]
groq_key = sys.argv[2]

try:
    with open(m4a_file, 'rb') as f:
        r = requests.post(
            'https://api.groq.com/openai/v1/audio/transcriptions',
            headers={'Authorization': f'Bearer {groq_key}'},
            files={'file': f},
            data={'model': 'whisper-large-v3', 'response_format': 'text'},
            timeout=120
        )
    if r.status_code == 200:
        print(r.text.strip())
    elif r.status_code == 429:
        print('ERROR:RATE_LIMITED')
    elif r.status_code >= 500:
        print('ERROR:SERVER_ERROR')
    else:
        print(f'ERROR:CLIENT_ERROR:{r.status_code}')
except requests.exceptions.Timeout:
    print('ERROR:TIMEOUT')
except Exception as e:
    print(f'ERROR:EXCEPTION:{str(e)}')
ENDPYTHON
) || true

    if [[ "$TRANSCRIPT" == "ERROR:"* ]]; then
        ERROR_CODE=$(echo "$TRANSCRIPT" | cut -d: -f2)
        case "$ERROR_CODE" in
            RATE_LIMITED|TIMEOUT|SERVER_ERROR)
                RETRY_COUNT=$((RETRY_COUNT + 1))
                if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
                    echo "[$TIMESTAMP] Retry $RETRY_COUNT/$MAX_RETRIES: $ERROR_CODE" >> "$LOG_FILE"
                    sleep $((2 * RETRY_COUNT))
                    continue
                fi
                ;;
            *)
                echo "[$TIMESTAMP] ERROR: $TRANSCRIPT" >> "$LOG_FILE"
                exit 1
                ;;
        esac
    fi
    break
done

if [ -z "$TRANSCRIPT" ] || [[ "$TRANSCRIPT" == "ERROR:"* ]]; then
    echo "[$TIMESTAMP] ERROR: Could not transcribe" >> "$LOG_FILE"
    exit 1
fi

echo "[$TIMESTAMP] Transcribed: ${#TRANSCRIPT} chars" >> "$LOG_FILE"

# ============================================================
# Process with Claude CLI (uses your Max subscription — no API key needed)
# Falls back to raw transcript if Claude isn't available
# ============================================================
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
MEMO_TYPE="personal"

# Cap transcript for Slack fallback
if [ ${#TRANSCRIPT} -gt 3900 ]; then
    TRANSCRIPT_TRUNCATED="${TRANSCRIPT:0:3900}... _(truncated — ${#TRANSCRIPT} chars total)_"
else
    TRANSCRIPT_TRUNCATED="$TRANSCRIPT"
fi
PROCESSED="$TRANSCRIPT_TRUNCATED"

if command -v "$CLAUDE_BIN" &>/dev/null; then
    TMPFILE=$(mktemp /tmp/thoughtstream-prompt.XXXXXX)
    cat > "$TMPFILE" << EOF
Process this voice memo transcript. Output ONLY valid JSON, no explanation, no markdown, no code fences:
{"title":"short 5-8 word title","summary":"1-2 sentences, clean prose, no filler words","action_items":["concrete action if any"],"type":"task|brain_capture|content_seed|personal"}

Types: task=has clear todos, brain_capture=insight/idea, content_seed=worth sharing publicly, personal=journal/life
action_items: empty array [] if none

TRANSCRIPT:
$TRANSCRIPT
EOF

    CLAUDE_RESULT=$(CLAUDECODE="" "$CLAUDE_BIN" -p --max-turns 1 < "$TMPFILE" 2>/dev/null) || true
    rm -f "$TMPFILE"

    if [ -n "$CLAUDE_RESULT" ] && [[ "$CLAUDE_RESULT" != *"Error:"* ]]; then
        PROCESSED=$(CLAUDE_RESULT_VAR="$CLAUDE_RESULT" TRANSCRIPT_VAR="$TRANSCRIPT_TRUNCATED" python3 << 'ENDPYTHON'
import os, json, re

raw = os.environ['CLAUDE_RESULT_VAR']
transcript = os.environ['TRANSCRIPT_VAR']

raw = re.sub(r'\x1b\[[0-9;]*m', '', raw).strip()
if raw.startswith('```'):
    raw = '\n'.join(raw.split('\n')[1:]).rsplit('```', 1)[0].strip()

type_emojis = {
    'task': ':white_check_mark:',
    'brain_capture': ':brain:',
    'content_seed': ':seedling:',
    'personal': ':memo:'
}

try:
    d = json.loads(raw)
    title = d.get('title', 'Voice Memo')
    summary = d.get('summary', '')
    actions = d.get('action_items', [])
    memo_type = d.get('type', 'personal')
    emoji = type_emojis.get(memo_type, ':memo:')

    parts = [f'{emoji} *{title}*']
    if summary:
        parts.append(summary)
    if actions:
        parts.append('*Actions:*')
        parts.extend(f'• {a}' for a in actions)
    print('\n'.join(parts))
except Exception:
    print(transcript)
ENDPYTHON
) || PROCESSED="$TRANSCRIPT_TRUNCATED"

        MEMO_TYPE=$(CLAUDE_RESULT_VAR="$CLAUDE_RESULT" python3 -c "
import os, json, re
raw = re.sub(r'\x1b\[[0-9;]*m', '', os.environ['CLAUDE_RESULT_VAR']).strip()
if raw.startswith('\`\`\`'): raw = '\n'.join(raw.split('\n')[1:]).rsplit('\`\`\`',1)[0].strip()
print(json.loads(raw).get('type','personal'))
" 2>/dev/null || echo "personal")

        echo "[$TIMESTAMP] Claude processed ($MEMO_TYPE)" >> "$LOG_FILE"
    else
        echo "[$TIMESTAMP] WARNING: Claude processing failed, posting raw transcript" >> "$LOG_FILE"
    fi
else
    echo "[$TIMESTAMP] WARNING: claude CLI not found at $CLAUDE_BIN, posting raw transcript" >> "$LOG_FILE"
fi

# ============================================================
# Save to local inbox as markdown
# ============================================================
MEMO_SLUG=$(echo "$PROCESSED" | head -1 | sed 's/:[a-z_]*://g; s/[*]//g; s/[^a-zA-Z0-9 ]//g' | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/-\+/-/g; s/^-\|-$//g' | cut -c1-40)
LOCAL_FILE="$INBOX_DIR/${DATE}-${MEMO_SLUG}.md"

cat > "$LOCAL_FILE" << MDEOF
# $(echo "$PROCESSED" | head -1 | sed 's/:[a-z_]*://g; s/[*]//g' | xargs)

**Date:** $DATE
**Type:** $MEMO_TYPE
**Source:** $FILENAME

## Recap

$PROCESSED

## Full Transcript

$TRANSCRIPT
MDEOF

echo "[$TIMESTAMP] Saved: $LOCAL_FILE" >> "$LOG_FILE"

# ============================================================
# Post to Slack — recap message + transcript as threaded attachment
# ============================================================
SLACK_RESULT=$(PROCESSED_VAR="$PROCESSED" TRANSCRIPT_VAR="$TRANSCRIPT" \
MEMO_TYPE_VAR="$MEMO_TYPE" DATE_VAR="$DATE" FILENAME_VAR="$FILENAME" \
BOT_TOKEN_VAR="$SLACK_BOT_TOKEN" CHANNEL_VAR="$SLACK_CHANNEL_ID" python3 << 'ENDPYTHON'
import os, requests, json, re

recap      = os.environ['PROCESSED_VAR']
transcript = os.environ['TRANSCRIPT_VAR']
memo_type  = os.environ['MEMO_TYPE_VAR']
date       = os.environ['DATE_VAR']
filename   = os.environ['FILENAME_VAR']
token      = os.environ['BOT_TOKEN_VAR']
channel    = os.environ['CHANNEL_VAR']
headers    = {'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'}

# 1. Post recap — get ts for threading
r = requests.post('https://slack.com/api/chat.postMessage',
    headers=headers,
    json={'channel': channel, 'text': recap},
    timeout=10)
data = r.json()
if not data.get('ok'):
    print(f'ERROR:chat.postMessage:{data.get("error")}')
    raise SystemExit(1)
ts = data['ts']

# 2. Build markdown attachment
title_line = recap.split('\n')[0]
title = re.sub(r':[a-z_]+:|[*]', '', title_line).strip() or 'Voice Memo'
slug = re.sub(r'[^a-z0-9]+', '-', title.lower()).strip('-')[:40]
filename_md = f'{date}-{slug}.md'
md = f'# {title}\n\n**Date:** {date} | **Type:** {memo_type} | **Source:** {filename}\n\n---\n\n{transcript}\n'
md_bytes = md.encode('utf-8')

# 3a. Get upload URL
r2 = requests.post('https://slack.com/api/files.getUploadURLExternal',
    headers={'Authorization': f'Bearer {token}'},
    data={'filename': filename_md, 'length': len(md_bytes)},
    timeout=10)
data2 = r2.json()
if not data2.get('ok'):
    print(f'WARN:getUploadURL:{data2.get("error")}')
    raise SystemExit(1)

# 3b. PUT content
requests.put(data2['upload_url'], data=md_bytes,
    headers={'Content-Type': 'text/markdown'}, timeout=15)

# 3c. Complete — share in thread
r4 = requests.post('https://slack.com/api/files.completeUploadExternal',
    headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'},
    json={'files': [{'id': data2['file_id']}], 'channel_id': channel, 'thread_ts': ts},
    timeout=10)
data4 = r4.json()
print('ok' if data4.get('ok') else f'WARN:completeUpload:{data4.get("error")}')
ENDPYTHON
) || true

if [ "$SLACK_RESULT" = "ok" ]; then
    echo "[$TIMESTAMP] Posted to Slack with transcript attachment" >> "$LOG_FILE"
    echo "$FILE_KEY" >> "$PROCESSED_FILE"
else
    echo "[$TIMESTAMP] WARNING: Slack issue - $SLACK_RESULT" >> "$LOG_FILE"
    echo "$FILE_KEY" >> "$PROCESSED_FILE"
fi

echo "[$TIMESTAMP] Complete" >> "$LOG_FILE"
