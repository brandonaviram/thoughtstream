#!/bin/bash
# Install thoughtstream as a macOS Folder Action on Voice Memos recordings folder
# This fires automatically every time you save a voice memo
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECORDINGS_DIR="$HOME/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"
WORKFLOW_DIR="$HOME/Library/Workflows/Applications/Folder Actions"
WORKFLOW_NAME="thoughtstream.workflow"
PLIST_DIR="$HOME/Library/Preferences/com.apple.FolderActionsDispatcher"

# Verify .env exists
if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo "Error: .env not found. Copy .env.example to .env and fill in your credentials."
    exit 1
fi

# Verify recordings folder exists
if [ ! -d "$RECORDINGS_DIR" ]; then
    echo "Error: Voice Memos recordings folder not found."
    echo "Open Voice Memos at least once to create it."
    exit 1
fi

# Create workflow using Automator's built-in AppleScript approach
mkdir -p "$WORKFLOW_DIR"

cat > "/tmp/build-workflow.applescript" << APPLESCRIPT
tell application "Automator"
    set newWorkflow to make new workflow
    set workflowFolder to the folder of newWorkflow as string

    tell newWorkflow
        make new action at end of actions with properties {class:shell script action, script text:"#!/bin/bash
export THOUGHTSTREAM_ENV_FILE='$SCRIPT_DIR/.env'
for f in \"\$@\"; do
    bash '$SCRIPT_DIR/thoughtstream.sh' \"\$f\" &
done", shell:"/bin/bash"}
    end tell

    save newWorkflow in "$WORKFLOW_DIR/$WORKFLOW_NAME" as workflow
    close newWorkflow
end tell
APPLESCRIPT

# Simpler: install via Folder Actions Setup directly
echo "Installing Folder Action..."

# Enable Folder Actions globally
defaults write com.apple.dock dockFixup-Folder-Actions -bool true 2>/dev/null || true

# Create the AppleScript wrapper
APPLESCRIPT_DIR="$HOME/Library/Scripts/Folder Action Scripts"
mkdir -p "$APPLESCRIPT_DIR"

cat > "$APPLESCRIPT_DIR/thoughtstream-trigger.applescript" << ASEOF
on adding folder items to thisFolder after receiving theFiles
    set scriptPath to "$SCRIPT_DIR/thoughtstream.sh"
    set envFile to "$SCRIPT_DIR/.env"

    repeat with theFile in theFiles
        set filePath to POSIX path of theFile
        if filePath ends with ".m4a" or filePath ends with ".qta" then
            do shell script "THOUGHTSTREAM_ENV_FILE=" & quoted form of envFile & " bash " & quoted form of scriptPath & " " & quoted form of filePath & " >> $HOME/thoughtstream-data/logs/folder-action.log 2>&1 &"
        end if
    end repeat
end adding folder items to thisFolder
ASEOF

# Compile to .scpt
osacompile -o "$APPLESCRIPT_DIR/thoughtstream-trigger.scpt" "$APPLESCRIPT_DIR/thoughtstream-trigger.applescript" 2>/dev/null

echo ""
echo "Script installed at: $APPLESCRIPT_DIR/thoughtstream-trigger.scpt"
echo ""
echo "Next: attach it to your Recordings folder."
echo ""
echo "Option A (GUI):"
echo "  1. Right-click your Recordings folder in Finder"
echo "     ($RECORDINGS_DIR)"
echo "  2. Services → Folder Actions Setup"
echo "  3. Attach 'thoughtstream-trigger' script"
echo ""
echo "Option B (command line):"

# Attempt to attach via osascript
osascript << ATTACH
tell application "Finder"
    set targetFolder to POSIX file "$RECORDINGS_DIR" as alias
    try
        attach action to targetFolder using "$APPLESCRIPT_DIR/thoughtstream-trigger.scpt"
    end try
end tell
ATTACH

echo "  Folder Action attached automatically."
echo ""
echo "Done. New voice memos will now post to Slack automatically."
