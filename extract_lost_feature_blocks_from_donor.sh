#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
DONOR="/Users/inma/Documents/Vroid/backups_before_manual_main_restore_20260621_080035/main.m.before_manual_restore"
CURRENT="$PROJECT/Sources/VroidOverlay/main.m"
OUT="$PROJECT/lost_feature_blocks_from_donor_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$OUT"

echo "== Extract lost feature blocks from donor =="
echo "DONOR=$DONOR"
echo "CURRENT=$CURRENT"
echo "OUT=$OUT"

if [ ! -f "$DONOR" ]; then
  echo "ERROR: donor no existe: $DONOR"
  exit 1
fi

cp "$DONOR" "$OUT/donor_main.m"
cp "$CURRENT" "$OUT/current_main.m"

extract_context() {
  local file="$1"
  local pattern="$2"
  local out="$3"

  {
    echo "FILE=$file"
    echo "PATTERN=$pattern"
    echo ""

    grep -nE "$pattern" "$file" | while IFS=: read -r line rest; do
      start=$((line-35))
      end=$((line+80))
      [ "$start" -lt 1 ] && start=1
      echo ""
      echo "============================================================"
      echo "around line $line: $rest"
      echo "============================================================"
      nl -ba "$file" | sed -n "${start},${end}p"
    done
  } > "$out" 2>&1
}

echo ""
echo "== 1. Extract Kokoro/TTS blocks =="
extract_context "$DONOR" \
  "VROID_TTS_PROVIDER|VROID_KOKORO|kokoro|v1/audio/speech|afplay|vroidSpeakText|vroidStopSpeaking|vroidSpeechPayloadFromCommand|vroidSpeechProviderName|vroidKokoroVoiceName" \
  "$OUT/donor_kokoro_tts_blocks.txt"

echo ""
echo "== 2. Extract user input / prompt blocks =="
extract_context "$DONOR" \
  "promptWindow|_promptWindow|_promptField|_promptStatusField|vroidSubmitPromptFromField|vroidPrompt|Ollama|api/chat|userPrompt|NSTextField|Send|controlTextDid|keyDown|Command" \
  "$OUT/donor_user_input_blocks.txt"

echo ""
echo "== 3. Extract mouse repel blocks =="
extract_context "$DONOR" \
  "repel|repulsion|avoid|evade|mouse|cursor|NSEvent|NSTrackingArea|tracking|acceptsMouseMovedEvents|proximity|influenceRadius|setFrameOrigin|targetOrigin|nextOrigin|locationInWindow" \
  "$OUT/donor_mouse_repel_blocks.txt"

echo ""
echo "== 4. Extract memory blocks =="
extract_context "$DONOR" \
  "conversation_memory|pinned_facts|short_term|medium_term|long_term|vroidLoadConversation|vroidSaveConversation|vroidAppendConversation|vroidChatMessagesForUserPrompt|local_events|memory" \
  "$OUT/donor_memory_blocks.txt"

echo ""
echo "== 5. Current comparison refs =="
extract_context "$CURRENT" \
  "VROID_TTS_PROVIDER|VROID_KOKORO|kokoro|v1/audio/speech|afplay|vroidSpeakText|promptWindow|_promptField|vroidSubmitPromptFromField|repel|repulsion|avoid|evade|proximity|conversation_memory|pinned_facts" \
  "$OUT/current_matching_blocks.txt"

echo ""
echo "== 6. Diff donor/current filtered =="
diff -u "$DONOR" "$CURRENT" > "$OUT/full_donor_vs_current.diff" || true

grep -nE "^[+-].*(VROID_TTS_PROVIDER|VROID_KOKORO|kokoro|v1/audio/speech|afplay|vroidSpeakText|promptWindow|_promptField|vroidSubmitPromptFromField|api/chat|repel|repulsion|avoid|evade|proximity|influenceRadius|setFrameOrigin|conversation_memory|pinned_facts|short_term|medium_term|long_term)" \
  "$OUT/full_donor_vs_current.diff" > "$OUT/filtered_lost_features.diff" || true

echo ""
echo "== 7. Build status current =="
{
  cd "$PROJECT"
  bash build.sh
} > "$OUT/current_build_test.txt" 2>&1 || true

echo ""
echo "== 8. Verdict =="
{
  echo "Lost Feature Blocks Extraction Verdict"
  echo ""
  echo "Donor:"
  stat -f "%Sm | %z bytes | %N" -t "%Y-%m-%d %H:%M:%S" "$DONOR"
  echo ""
  echo "Current:"
  stat -f "%Sm | %z bytes | %N" -t "%Y-%m-%d %H:%M:%S" "$CURRENT"
  echo ""
  echo "Current build:"
  if grep -qi "error:" "$OUT/current_build_test.txt"; then
    echo "FAIL"
    tail -60 "$OUT/current_build_test.txt"
  else
    echo "OK"
    tail -20 "$OUT/current_build_test.txt"
  fi
  echo ""
  echo "Extracted files:"
  echo "$OUT/donor_kokoro_tts_blocks.txt"
  echo "$OUT/donor_user_input_blocks.txt"
  echo "$OUT/donor_mouse_repel_blocks.txt"
  echo "$OUT/donor_memory_blocks.txt"
  echo "$OUT/current_matching_blocks.txt"
  echo "$OUT/filtered_lost_features.diff"
} > "$OUT/verdict.txt"

zip -qr "$OUT.zip" "$OUT"

echo ""
echo "== DONE =="
echo "Folder: $OUT"
echo "ZIP: $OUT.zip"
echo ""
cat "$OUT/verdict.txt"
echo "$OUT.zip" | pbcopy
