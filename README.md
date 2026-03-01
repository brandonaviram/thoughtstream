# Thoughtstream

Record a voice memo. It shows up in Slack, summarized and ready to act on.

No app to open. No buttons to press. Talk, put your phone down, done.

---

## How It Works

1. You save a voice memo on your iPhone or Mac
2. A macOS Folder Action fires instantly
3. Groq Whisper transcribes it
4. Claude classifies and summarizes it (task, idea, content seed, or personal)
5. A formatted message lands in your Slack channel

---

## Quickstart

### 1. Clone and configure

```bash
git clone https://github.com/brandonaviram/thoughtstream.git
cd thoughtstream

cp .env.example .env
# Edit .env with your credentials (see below)
```

### 2. Get your credentials

**Groq API key** (free — for transcription)
- Sign up at [console.groq.com](https://console.groq.com)
- Create an API key, add to `.env` as `GROQ_API_KEY`

**Slack Bot Token**
- Go to [api.slack.com/apps](https://api.slack.com/apps) → Create New App → From scratch
- Under "OAuth & Permissions", add scopes: `chat:write`, `files:write`
- Install the app to your workspace
- Copy the **Bot User OAuth Token** (`xoxb-...`) → add to `.env` as `SLACK_BOT_TOKEN`
- Invite the bot to your channel: `/invite @yourbot`
- Get the channel ID: right-click the channel → "Copy link" → ID is the last segment (e.g. `C0XXXXXXXXX`)
- Add to `.env` as `SLACK_CHANNEL_ID`

**Claude CLI** (optional — for AI summarization)
- Install [Claude Code](https://claude.ai/code) — uses your existing Max subscription
- The pipeline falls back to raw transcript if Claude isn't available

### 3. Test manually

```bash
chmod +x thoughtstream.sh
./thoughtstream.sh /path/to/a/voice-memo.m4a
```

Check Slack. You should see a message in ~10 seconds.

### 4. Install the Folder Action (fire automatically on new memos)

```bash
chmod +x setup-folder-action.sh
./setup-folder-action.sh
```

This attaches a Folder Action to your Voice Memos recordings folder. Every new memo triggers the pipeline automatically, including ones recorded on your iPhone (they sync via iCloud).

---

## Configuration

All config lives in `.env`:

| Variable | Required | Description |
|---|---|---|
| `GROQ_API_KEY` | Yes | Groq API key for Whisper transcription |
| `SLACK_BOT_TOKEN` | Yes | Slack bot token (`xoxb-...`) |
| `SLACK_CHANNEL_ID` | Yes | Slack channel ID to post to |
| `THOUGHTSTREAM_DATA_DIR` | No | Where to save transcripts + logs (default: `~/thoughtstream-data`) |
| `CLAUDE_BIN` | No | Path to claude CLI (default: `~/.local/bin/claude`) |

---

## Memo Types

Claude classifies each memo automatically:

| Emoji | Type | When |
|---|---|---|
| :white_check_mark: | `task` | Has clear action items |
| :brain: | `brain_capture` | Insight or idea |
| :seedling: | `content_seed` | Worth sharing publicly |
| :memo: | `personal` | Journal / life stuff |

---

## File Structure

```
thoughtstream/
├── thoughtstream.sh          # Main pipeline script
├── setup-folder-action.sh    # macOS Folder Action installer
├── .env.example              # Credential template
├── .env                      # Your credentials (gitignored)
└── .gitignore
```

Local data (created on first run, path controlled by `THOUGHTSTREAM_DATA_DIR`):

```
~/thoughtstream-data/
├── inbox/                    # Markdown copies of every memo
└── logs/
    ├── YYYY-MM.log           # Pipeline run log
    └── processed.txt         # Dedup tracker
```

---

## Manual batch processing

```bash
RECORDINGS="$HOME/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"
for f in "$RECORDINGS"/*.m4a; do
    ./thoughtstream.sh "$f"
done
```

---

## Requirements

- macOS (Folder Actions)
- ffmpeg (`brew install ffmpeg`) — for `.qta` format conversion
- Python 3 + `requests` (`pip3 install requests`)
- Groq account (free)
- Slack workspace with a bot
- Claude Code (optional, for AI summaries)

---

Built by [Brandon Aviram](https://aviram.io)
