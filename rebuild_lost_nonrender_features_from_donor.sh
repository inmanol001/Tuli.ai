#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
MAIN="$PROJECT/Sources/VroidOverlay/main.m"
DONOR="$PROJECT/backups_before_manual_main_restore_20260621_080035/main.m.before_manual_restore"
BACKUP="$PROJECT/backups_rebuild_lost_nonrender_features_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$BACKUP"
cp "$MAIN" "$BACKUP/main.m.before_rebuild"

echo "== Rebuild lost non-render features from donor =="
echo "MAIN=$MAIN"
echo "DONOR=$DONOR"
echo "BACKUP=$BACKUP"
echo ""
echo "Este patch NO debe tocar:"
echo "- SceneKit render pipeline"
echo "- AI.usdc"
echo "- camera / pointOfView"
echo "- loadModelAtURL"
echo "- centerAndFitNode"
echo "- speech bubble visual"
echo ""

if [ ! -f "$DONOR" ]; then
  echo "ERROR: donor no existe: $DONOR"
  exit 1
fi

python3 - <<'PY'
from pathlib import Path
import re

project = Path("/Users/inma/Documents/Vroid")
main_path = project / "Sources/VroidOverlay/main.m"
donor_path = project / "backups_before_manual_main_restore_20260621_080035/main.m.before_manual_restore"

s = main_path.read_text()
d = donor_path.read_text()

def insert_after_once(src, needle, insert):
    if insert.strip() in src:
        return src, False
    idx = src.find(needle)
    if idx == -1:
        return src, False
    pos = idx + len(needle)
    return src[:pos] + insert + src[pos:], True

def get_static_function(src, name):
    start = src.find(f"static NSString *{name}(void)")
    if start == -1:
        return None
    brace = src.find("{", start)
    if brace == -1:
        return None
    depth = 0
    end = None
    for i in range(brace, len(src)):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    return src[start:end] if end else None

def method_block(src, selector_prefix):
    # selector_prefix example: "- (void)vroidSpeakText:" or "- (NSString *)vroidTTSProvider"
    start = src.find(selector_prefix)
    if start == -1:
        return None
    brace = src.find("{", start)
    if brace == -1:
        return None
    depth = 0
    end = None
    for i in range(brace, len(src)):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    return src[start:end] if end else None

def remove_method(src, selector_prefix):
    start = src.find(selector_prefix)
    if start == -1:
        return src, False
    brace = src.find("{", start)
    if brace == -1:
        return src, False
    depth = 0
    end = None
    for i in range(brace, len(src)):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    if end is None:
        return src, False
    return src[:start] + src[end:], True

def overlay_impl_insert_pos(src):
    impl = src.find("@implementation OverlaySceneView")
    if impl == -1:
        raise SystemExit("No encontré @implementation OverlaySceneView")
    end = src.find("\n@end", impl)
    if end == -1:
        raise SystemExit("No encontré @end de OverlaySceneView")
    return end

def add_or_replace_method(src, donor_src, selector_prefix):
    block = method_block(donor_src, selector_prefix)
    if block is None:
        print("WARN donor missing method:", selector_prefix)
        return src

    src, removed = remove_method(src, selector_prefix)
    pos = overlay_impl_insert_pos(src)
    src = src[:pos] + "\n\n" + block + "\n" + src[pos:]
    print(("replaced" if removed else "added"), selector_prefix)
    return src

# 0. Keep float.h if donor used it.
if "#include <float.h>" not in s:
    s = s.replace("#import <SceneKit/SceneKit.h>\n", "#import <SceneKit/SceneKit.h>\n#include <float.h>\n")
    print("added #include <float.h>")

# 1. Static constants missing from donor.
static_lines = [
    'static NSString * const VroidOverlayDefaultOllamaModelName = @"qwen3:1.7b";',
    'static NSString * const VroidOverlayConversationMemoryFileName = @"conversation_memory.json";',
    'static NSString * const VroidOverlayLocalEventLogFileName = @"local_events.jsonl";',
    'static NSUInteger const VroidOverlayConversationMemoryLimit = 12;',
    'static NSUInteger const VroidOverlayConversationMediumMemoryLimit = 8;',
    'static NSUInteger const VroidOverlayConversationLongMemoryLimit = 12;',
    'static NSUInteger const VroidOverlayLocalEventLimit = 24;',
    'static NSTimeInterval const VroidOverlayConversationShortMemoryMaxAge = 48.0 * 60.0 * 60.0;',
    'static NSTimeInterval const VroidOverlayConversationMediumMemoryMaxAge = 30.0 * 24.0 * 60.0 * 60.0;',
    'static CGFloat const VroidOverlaySpeechBubbleMinWidth = 180.0;',
    'static CGFloat const VroidOverlaySpeechBubbleMaxWidth = 420.0;',
    'static CGFloat const VroidOverlaySpeechBubbleMinHeight = 56.0;',
    'static NSTimeInterval const VroidOverlaySpeechBubbleMinVisibleSeconds = 2.4;',
    'static NSTimeInterval const VroidOverlaySpeechBubbleDismissDelaySeconds = 2.1;',
]
insert_constants = "\n" + "\n".join(line for line in static_lines if line not in s) + "\n"
if insert_constants.strip():
    needle = 'static NSString * const VroidOverlayLogsWindowFrameDefaultsKey = @"VroidOverlayLogsWindowFrame";\n'
    s, ok = insert_after_once(s, needle, insert_constants)
    print("added constants:", ok)

# 2. Speech trace path helper.
if "VroidOverlaySpeechTraceLogPath" not in s:
    fn = get_static_function(d, "VroidOverlaySpeechTraceLogPath")
    if fn:
        marker = get_static_function(s, "VroidOverlayOverlayDebugLogPath")
        if marker and marker in s:
            s = s.replace(marker, marker + "\n\n" + fn)
            print("added VroidOverlaySpeechTraceLogPath")

# 3. Interface declarations.
decls = [
    "- (void)vroidStopSpeaking;",
    "- (void)vroidShowPromptPanel;",
    "- (void)vroidRefreshLocalContextSnapshot;",
    "- (void)vroidRecordLocalEventWithType:(NSString *)type detail:(NSString *)detail source:(NSString *)source;",
    "- (void)vroidSendPromptToOllama:(NSString *)prompt;",
    "- (NSString *)vroidSpeechPayloadFromCommand:(NSDictionary *)command;",
    "- (void)vroidStartMouseRepelLoop;",
    "- (void)vroidStopMouseRepelLoop;",
    "- (void)vroidCompactConversationMemory;",
    "- (NSPoint)vroidScreenPointForEvent:(NSEvent *)event;",
]
for decl in decls:
    if decl not in s:
        s = s.replace("@property (nonatomic, weak) id<RotationControlUpdating> rotationControlWindowController;", decl + "\n@property (nonatomic, weak) id<RotationControlUpdating> rotationControlWindowController;")
        print("added decl:", decl)

# 4. Missing ivars.
missing_ivars = [
    "    NSTask *_speechTask;",
    "    NSString *_speechVoiceName;",
    "    NSTimer *_mouseRepelTimer;",
    "    NSPoint _mouseRepelVelocity;",
    "    CGFloat _mouseRepelPressure;",
    "    NSTimeInterval _mouseLastTeleportTime;",
    "    NSTextField *_speechBubbleModelLabel;",
    "    NSTimeInterval _speechBubbleLastShownAt;",
    "    NSUInteger _speechBubbleToken;",
    "    NSURLSessionDataTask *_ttsRequestTask;",
    "    NSPanel *_promptWindow;",
    "    NSTextField *_promptField;",
    "    NSTextField *_promptStatusField;",
    "    NSURLSessionDataTask *_promptTask;",
    "    NSArray<NSDictionary *> *_conversationMemory;",
    "    NSArray<NSDictionary *> *_conversationMediumMemory;",
    "    NSArray<NSDictionary *> *_conversationLongMemory;",
    "    NSArray<NSDictionary *> *_localEvents;",
    "    BOOL _workspaceObserversInstalled;",
]
m = re.search(r'(@implementation OverlaySceneView\s*\{)(.*?)(\n\})', s, re.S)
if not m:
    raise SystemExit("No encontré ivar block de OverlaySceneView")

ivar_body = m.group(2)
to_add = [line for line in missing_ivars if line.strip() not in ivar_body]
if to_add:
    new_body = ivar_body + "\n" + "\n".join(to_add)
    s = s[:m.start(2)] + new_body + s[m.end(2):]
    print("added ivars:", len(to_add))

# 5. Add init calls for memory only; do not alter render setup.
if "[self vroidLoadConversationMemory];" not in s:
    s = s.replace("[self installAxisGuides];", "[self installAxisGuides];\n        [self vroidLoadConversationMemory];\n        [self vroidRefreshLocalContextSnapshot];")
    print("added memory init calls")

# 6. Add viewDidMoveToWindow from donor if missing; starts repel loop and positions prompt.
if "- (void)viewDidMoveToWindow" not in s:
    block = method_block(d, "- (void)viewDidMoveToWindow")
    pos = overlay_impl_insert_pos(s)
    s = s[:pos] + "\n\n" + block + "\n" + s[pos:]
    print("added viewDidMoveToWindow")

# 7. Add dealloc workspace cleanup if missing.
if "- (void)dealloc" not in s:
    block = method_block(d, "- (void)dealloc")
    if block:
        pos = overlay_impl_insert_pos(s)
        s = s[:pos] + "\n\n" + block + "\n" + s[pos:]
        print("added dealloc")

# 8. Replace mouseUp to open prompt on click, but do not touch bubble drawing.
s = add_or_replace_method(s, d, "- (void)mouseUp:")

# 9. Add/replace TTS/Kokoro methods.
for prefix in [
    "- (void)vroidStopSpeaking",
    "- (NSString *)vroidSpeechVoiceName",
    "- (NSString *)vroidTTSProvider",
    "- (NSURL *)vroidKokoroSpeechURL",
    "- (NSString *)vroidKokoroVoiceName",
    "- (NSString *)vroidSpeechIndicatorText",
    "- (void)vroidSpeakWithSayText:",
    "- (void)vroidPlayAudioAtURL:",
    "- (void)vroidSpeakOutLoudTextWithFallback:",
    "- (void)vroidSpeakOutLoudText:",
    "- (NSString *)vroidJSONStringFromObject:",
    "- (void)vroidAppendSpeechTraceLine:",
    "- (void)vroidSpeakText:",
]:
    s = add_or_replace_method(s, d, prefix)

# 10. Add/replace mouse repel methods.
for prefix in [
    "- (BOOL)vroidMouseRepelEnabled",
    "- (void)vroidStartMouseRepelLoop",
    "- (void)vroidStopMouseRepelLoop",
    "- (NSScreen *)vroidTeleportTargetScreenForMousePoint:",
    "- (NSPoint)vroidTeleportOriginForMousePoint:",
    "- (void)vroidTeleportWindowAwayFromMouse",
    "- (void)vroidTickMouseRepel:",
    "- (void)vroidMoveWindowAwayFromScreenPoint:",
]:
    s = add_or_replace_method(s, d, prefix)

# 11. Add input + memory + Ollama methods.
for prefix in [
    "- (void)vroidPositionPromptWindow",
    "- (NSString *)vroidConversationMemoryPath",
    "- (NSString *)vroidLocalEventLogPath",
    "- (NSArray<NSDictionary *> *)vroidCleanMemoryRecords:",
    "- (NSArray<NSDictionary *> *)vroidTrimConversationMemory:",
    "- (NSString *)vroidMemorySummaryTextForItems:",
    "- (NSArray<NSDictionary *> *)vroidFlattenMemorySection:",
    "- (void)vroidLoadConversationMemory",
    "- (NSArray<NSDictionary *> *)vroidTrimLocalEvents:",
    "- (NSArray<NSDictionary *> *)vroidLoadLocalEvents",
    "- (void)vroidPersistLocalEvents",
    "- (void)vroidRecordLocalEventWithType:",
    "- (void)vroidPersistConversationMemory",
    "- (void)vroidAppendConversationMessageRole:",
    "- (NSTimeInterval)vroidMemoryTimestampForItem:",
    "- (NSArray<NSDictionary *> *)vroidSortedMemoryItems:",
    "- (void)vroidCompactConversationMemory",
    "- (void)vroidRefreshLocalContextSnapshot",
    "- (NSArray<NSDictionary *> *)vroidChatMessagesForUserPrompt:",
    "- (NSURL *)vroidOllamaURL",
    "- (NSString *)vroidOllamaModelName",
    "- (void)vroidShowPromptPanel",
    "- (void)vroidSubmitPromptFromField:",
    "- (void)vroidSendPromptToOllama:",
]:
    s = add_or_replace_method(s, d, prefix)

# 12. Replace plain text response so prompts update memory and speak.
for prefix in [
    "- (void)vroidHandlePlainTextResponse:",
    "- (void)vroidHandleAICommandDictionary:",
]:
    s = add_or_replace_method(s, d, prefix)

main_path.write_text(s)
print("WROTE", main_path)
PY

echo ""
echo "== Sanity scan =="
grep -nE "vroidShowPromptPanel|vroidSubmitPromptFromField|vroidStartMouseRepelLoop|vroidTickMouseRepel|VROID_TTS_PROVIDER|vroidKokoroSpeechURL|conversation_memory|vroidChatMessagesForUserPrompt" "$MAIN" | head -160 || true

echo ""
echo "== Build =="
if bash "$PROJECT/build.sh"; then
  echo ""
  echo "== BUILD OK =="
else
  echo ""
  echo "== BUILD FAILED: rolling back =="
  cp "$BACKUP/main.m.before_rebuild" "$MAIN"
  bash "$PROJECT/build.sh" || true
  echo "Restaurado main anterior desde: $BACKUP/main.m.before_rebuild"
  exit 1
fi

echo ""
echo "== Run app with safe env =="
echo "No se toca render ni burbuja."
echo ""
pkill -f VroidOverlay 2>/dev/null || true
sleep 1

VROID_DEBUG=1 \
VROID_TTS_PROVIDER=kokoro \
VROID_KOKORO_URL="http://127.0.0.1:8880/v1/audio/speech" \
VROID_KOKORO_VOICE="af_bella" \
"$PROJECT/build/VroidOverlay.app/Contents/MacOS/VroidOverlay"
