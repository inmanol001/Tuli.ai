#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
MAIN="$PROJECT/Sources/VroidOverlay/main.m"
DONOR="$PROJECT/backups_before_manual_main_restore_20260621_080035/main.m.before_manual_restore"
BACKUP="$PROJECT/backups_rebuild_lost_nonrender_features_SAFE2_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$BACKUP"
cp "$MAIN" "$BACKUP/main.m.before_safe2"

echo "== SAFE2 rebuild lost non-render features =="
echo "MAIN=$MAIN"
echo "DONOR=$DONOR"
echo "BACKUP=$BACKUP"
echo ""
echo "NO toca render/cámara/modelo/burbuja visual."
echo "Solo intenta traer: input, mouse repel, Kokoro, memoria."
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

def bounds_overlay_impl(src):
    start = src.find("@implementation OverlaySceneView")
    if start == -1:
        raise RuntimeError("No encontré @implementation OverlaySceneView")
    end = src.find("\n@end", start)
    if end == -1:
        raise RuntimeError("No encontré @end de OverlaySceneView")
    return start, end

def method_block_in_overlay(src, selector_prefix):
    impl_start, impl_end = bounds_overlay_impl(src)
    start = src.find(selector_prefix, impl_start, impl_end)
    if start == -1:
        return None

    # Evita agarrar declaraciones sin cuerpo
    brace = src.find("{", start, impl_end)
    semicolon = src.find(";", start, impl_end)
    if brace == -1:
        return None
    if semicolon != -1 and semicolon < brace:
        # Esto era una declaración, no método real
        return None

    depth = 0
    end = None
    for i in range(brace, impl_end):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                break

    if end is None:
        return None

    return src[start:end]

def remove_method_in_overlay(src, selector_prefix):
    impl_start, impl_end = bounds_overlay_impl(src)
    start = src.find(selector_prefix, impl_start, impl_end)
    if start == -1:
        return src, False

    brace = src.find("{", start, impl_end)
    semicolon = src.find(";", start, impl_end)
    if brace == -1:
        return src, False
    if semicolon != -1 and semicolon < brace:
        return src, False

    depth = 0
    end = None
    for i in range(brace, impl_end):
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

def insert_method_before_overlay_end(src, block):
    _, end = bounds_overlay_impl(src)
    return src[:end] + "\n\n" + block + "\n" + src[end:]

def add_or_replace(selector_prefix):
    global s
    block = method_block_in_overlay(d, selector_prefix)
    if block is None:
        print("WARN donor missing method:", selector_prefix)
        return

    s, removed = remove_method_in_overlay(s, selector_prefix)
    s = insert_method_before_overlay_end(s, block)
    print(("replaced" if removed else "added"), selector_prefix)

def add_decl(decl):
    global s
    if decl in s:
        return
    marker = "@end\n\n@implementation OverlaySceneView"
    if marker not in s:
        print("WARN no marker for decl:", decl)
        return
    s = s.replace(marker, decl + "\n" + marker)
    print("added decl:", decl)

def add_ivar(line):
    global s
    m = re.search(r'(@implementation OverlaySceneView\s*\{)(.*?)(\n\})', s, re.S)
    if not m:
        raise RuntimeError("No encontré ivar block")
    body = m.group(2)
    if line.strip() in body:
        return
    s = s[:m.end(2)] + "\n" + line + s[m.end(2):]
    print("added ivar:", line.strip())

def static_function(src, name):
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

# 0. Include
if "#include <float.h>" not in s:
    s = s.replace("#import <SceneKit/SceneKit.h>\n", "#import <SceneKit/SceneKit.h>\n#include <float.h>\n")
    print("added float.h")

# 1. Constantes no visuales / memoria / speech
consts = [
    'static NSString * const VroidOverlayDefaultOllamaModelName = @"qwen3:1.7b";',
    'static NSString * const VroidOverlayConversationMemoryFileName = @"conversation_memory.json";',
    'static NSString * const VroidOverlayLocalEventLogFileName = @"local_events.jsonl";',
    'static NSUInteger const VroidOverlayConversationMemoryLimit = 12;',
    'static NSUInteger const VroidOverlayConversationMediumMemoryLimit = 8;',
    'static NSUInteger const VroidOverlayConversationLongMemoryLimit = 12;',
    'static NSUInteger const VroidOverlayLocalEventLimit = 24;',
    'static NSTimeInterval const VroidOverlayConversationShortMemoryMaxAge = 48.0 * 60.0 * 60.0;',
    'static NSTimeInterval const VroidOverlayConversationMediumMemoryMaxAge = 30.0 * 24.0 * 60.0 * 60.0;',
]
missing = [c for c in consts if c not in s]
if missing:
    marker = 'static NSString * const VroidOverlayLogsWindowFrameDefaultsKey = @"VroidOverlayLogsWindowFrame";'
    if marker in s:
        s = s.replace(marker, marker + "\n" + "\n".join(missing))
        print("added constants:", len(missing))
    else:
        print("WARN no constants marker")

# 2. Static helper speech trace
if "VroidOverlaySpeechTraceLogPath" not in s:
    fn = static_function(d, "VroidOverlaySpeechTraceLogPath")
    marker = static_function(s, "VroidOverlayOverlayDebugLogPath")
    if fn and marker:
        s = s.replace(marker, marker + "\n\n" + fn)
        print("added speech trace path")

# 3. Declarations en interface
for decl in [
    "- (void)vroidStopSpeaking;",
    "- (void)vroidShowPromptPanel;",
    "- (void)vroidRefreshLocalContextSnapshot;",
    "- (void)vroidRecordLocalEventWithType:(NSString *)type detail:(NSString *)detail source:(NSString *)source;",
    "- (void)vroidSendPromptToOllama:(NSString *)prompt;",
    "- (void)vroidStartMouseRepelLoop;",
    "- (void)vroidStopMouseRepelLoop;",
    "- (void)vroidCompactConversationMemory;",
]:
    add_decl(decl)

# 4. Ivars
for ivar in [
    "    NSTask *_speechTask;",
    "    NSString *_speechVoiceName;",
    "    NSTimer *_mouseRepelTimer;",
    "    NSPoint _mouseRepelVelocity;",
    "    CGFloat _mouseRepelPressure;",
    "    NSTimeInterval _mouseLastTeleportTime;",
    "    NSPanel *_promptWindow;",
    "    NSTextField *_promptField;",
    "    NSTextField *_promptStatusField;",
    "    NSURLSessionDataTask *_ttsRequestTask;",
    "    NSURLSessionDataTask *_promptTask;",
    "    NSArray<NSDictionary *> *_conversationMemory;",
    "    NSArray<NSDictionary *> *_conversationMediumMemory;",
    "    NSArray<NSDictionary *> *_conversationLongMemory;",
    "    NSArray<NSDictionary *> *_localEvents;",
    "    BOOL _workspaceObserversInstalled;",
]:
    add_ivar(ivar)

# 5. Init calls, no render
if "[self vroidLoadConversationMemory];" not in s:
    marker = "[self installAxisGuides];"
    if marker in s:
        s = s.replace(marker, marker + "\n        [self vroidLoadConversationMemory];\n        [self vroidRefreshLocalContextSnapshot];")
        print("added memory init calls")

# 6. Methods. Orden: helpers primero.
for prefix in [
    "- (void)viewDidMoveToWindow",
    "- (void)dealloc",
    "- (void)mouseUp:",

    "- (void)vroidStopSpeaking",
    "- (NSString *)vroidSpeechVoiceName",
    "- (NSString *)vroidTTSProvider",
    "- (NSURL *)vroidKokoroSpeechURL",
    "- (NSString *)vroidKokoroVoiceName",
    "- (void)vroidSpeakWithSayText:",
    "- (void)vroidPlayAudioAtURL:",
    "- (void)vroidSpeakOutLoudTextWithFallback:",
    "- (void)vroidSpeakOutLoudText:",
    "- (NSString *)vroidJSONStringFromObject:",
    "- (void)vroidAppendSpeechTraceLine:",
    "- (void)vroidSpeakText:",

    "- (BOOL)vroidMouseRepelEnabled",
    "- (void)vroidStartMouseRepelLoop",
    "- (void)vroidStopMouseRepelLoop",
    "- (NSScreen *)vroidTeleportTargetScreenForMousePoint:",
    "- (NSPoint)vroidTeleportOriginForMousePoint:",
    "- (void)vroidTeleportWindowAwayFromMouse",
    "- (void)vroidTickMouseRepel:",
    "- (void)vroidMoveWindowAwayFromScreenPoint:",

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
    "- (void)vroidHandlePlainTextResponse:",
    "- (void)vroidHandleAICommandDictionary:",
]:
    add_or_replace(prefix)

main_path.write_text(s)
print("WROTE", main_path)
PY

echo ""
echo "== Sanity scan =="
grep -nE "vroidShowPromptPanel|vroidSubmitPromptFromField|vroidStartMouseRepelLoop|vroidTickMouseRepel|VROID_TTS_PROVIDER|vroidKokoroSpeechURL|conversation_memory|vroidChatMessagesForUserPrompt" "$MAIN" | head -180 || true

echo ""
echo "== Build =="
if bash "$PROJECT/build.sh"; then
  echo ""
  echo "== BUILD OK =="
  echo "Backup antes del patch:"
  echo "$BACKUP/main.m.before_safe2"
else
  echo ""
  echo "== BUILD FAILED: rollback =="
  cp "$BACKUP/main.m.before_safe2" "$MAIN"
  bash "$PROJECT/build.sh" || true
  echo "Rollback listo:"
  echo "$BACKUP/main.m.before_safe2"
  exit 1
fi
