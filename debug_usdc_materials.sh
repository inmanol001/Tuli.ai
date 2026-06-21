#!/usr/bin/env bash
set -euo pipefail

MODEL="${1:-AI.usdc}"
OUT="usdc_material_debug_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"

echo "== USDC Material Debug ==" | tee "$OUT/README.txt"
echo "Project: $(pwd)" | tee -a "$OUT/README.txt"
echo "Model: $MODEL" | tee -a "$OUT/README.txt"
echo "Date: $(date)" | tee -a "$OUT/README.txt"
echo "" | tee -a "$OUT/README.txt"

if [ ! -f "$MODEL" ]; then
  echo "ERROR: No existe el modelo: $MODEL" | tee -a "$OUT/README.txt"
  exit 1
fi

echo "== System ==" | tee "$OUT/system.txt"
uname -a >> "$OUT/system.txt" 2>&1 || true
sw_vers >> "$OUT/system.txt" 2>&1 || true
xcode-select -p >> "$OUT/system.txt" 2>&1 || true
xcrun --find usdcat >> "$OUT/system.txt" 2>&1 || true
xcrun --find usdzconvert >> "$OUT/system.txt" 2>&1 || true
xcrun --find usdchecker >> "$OUT/system.txt" 2>&1 || true
xcrun --find usdview >> "$OUT/system.txt" 2>&1 || true
python3 --version >> "$OUT/system.txt" 2>&1 || true

echo "== Project tree relevant ==" | tee "$OUT/project_tree.txt"
find . \
  -path "./node_modules" -prune -o \
  -path "./.git" -prune -o \
  -path "./build" -prune -o \
  -maxdepth 5 \
  \( -type f -o -type d \) \
  | sed 's#^\./##' \
  | sort >> "$OUT/project_tree.txt" 2>/dev/null || true

echo "== Model file info ==" | tee "$OUT/model_file_info.txt"
ls -lah "$MODEL" >> "$OUT/model_file_info.txt" 2>&1 || true
file "$MODEL" >> "$OUT/model_file_info.txt" 2>&1 || true
shasum -a 256 "$MODEL" >> "$OUT/model_file_info.txt" 2>&1 || true

echo "== Texture files ==" | tee "$OUT/textures_found.txt"
find . \
  -path "./build" -prune -o \
  -path "./.git" -prune -o \
  -type f \( \
    -iname "*.png" -o \
    -iname "*.jpg" -o \
    -iname "*.jpeg" -o \
    -iname "*.webp" -o \
    -iname "*.tga" -o \
    -iname "*.exr" -o \
    -iname "*.hdr" \
  \) \
  | sort > "$OUT/textures_found.txt" 2>/dev/null || true

echo "== Texture file sizes ==" | tee "$OUT/texture_sizes.txt"
while IFS= read -r f; do
  [ -f "$f" ] || continue
  stat -f "%z bytes  %N" "$f" 2>/dev/null || stat -c "%s bytes  %n" "$f" 2>/dev/null || true
done < "$OUT/textures_found.txt" >> "$OUT/texture_sizes.txt"

echo "== Texture dimensions via sips ==" | tee "$OUT/texture_dimensions.txt"
while IFS= read -r f; do
  [ -f "$f" ] || continue
  echo "---- $f ----" >> "$OUT/texture_dimensions.txt"
  sips -g pixelWidth -g pixelHeight -g format "$f" >> "$OUT/texture_dimensions.txt" 2>&1 || true
done < "$OUT/textures_found.txt"

echo "== Main SceneKit code search ==" | tee "$OUT/main_code_search.txt"
grep -RIn \
  --exclude-dir=.git \
  --exclude-dir=build \
  -E "SCNScene|SCNView|SCNNode|SCNMaterial|SCNMaterialProperty|diffuse|normal|emission|transparent|transparency|alpha|opacity|doubleSided|cullMode|writesToDepthBuffer|readsFromDepthBuffer|lightingModel|blendMode|fillMode|renderingOrder|categoryBitMask|geometry|childNodes|rootNode|sceneNamed|URLWithString|fileURLWithPath|AI.usdc|AI.fbx|textures|Resource|bundle" \
  Sources ./*.m ./*.mm ./*.swift ./*.h 2>/dev/null > "$OUT/main_code_search.txt" || true

echo "== Suspicious SceneKit material/camera/node code ==" | tee "$OUT/suspicious_scenekit_code.txt"
grep -RIn \
  --exclude-dir=.git \
  --exclude-dir=build \
  -E "hidden\s*=|opacity\s*=|transparency\s*=|doubleSided\s*=|cullMode\s*=|writesToDepthBuffer\s*=|readsFromDepthBuffer\s*=|lightingModelName\s*=|blendMode\s*=|renderingOrder\s*=|categoryBitMask\s*=|scale\s*=|position\s*=|eulerAngles\s*=|pivot\s*=|camera\.zNear|camera\.zFar|orthographicScale|pointOfView|allowsCameraControl|autoenablesDefaultLighting" \
  . > "$OUT/suspicious_scenekit_code.txt" 2>/dev/null || true

echo "== Try usdcat full dump ==" | tee "$OUT/usdcat_status.txt"
if xcrun --find usdcat >/dev/null 2>&1; then
  if xcrun usdcat "$MODEL" > "$OUT/usdcat_full.usda" 2> "$OUT/usdcat_error.txt"; then
    echo "usdcat OK" >> "$OUT/usdcat_status.txt"
  else
    echo "usdcat FAILED" >> "$OUT/usdcat_status.txt"
    cat "$OUT/usdcat_error.txt" >> "$OUT/usdcat_status.txt" || true
  fi
else
  echo "usdcat not found" >> "$OUT/usdcat_status.txt"
fi

echo "== USD/USDC strings scan ==" | tee "$OUT/usdc_strings_scan.txt"
strings "$MODEL" | grep -iE "def Mesh|def Material|Material|Shader|PreviewSurface|UsdPreviewSurface|diffuse|normal|emissive|opacity|roughness|metallic|texture|file|inputs:|outputs:|Body|Face|Head|Hair|Skin|Arm|Leg|Hips|Spine|Chest|Torso|Mouth|Eye|Eyelash|Teeth|BlendShape|Skeleton|Skel|Joint|Primvar|st" \
  > "$OUT/usdc_strings_scan.txt" 2>/dev/null || true

echo "== USD material summary from usdcat/strings ==" | tee "$OUT/usd_material_summary.txt"
python3 <<'PY' "$OUT" "$MODEL" > "$OUT/usd_material_summary.txt" 2>&1
import sys, re, os, json
out, model = sys.argv[1], sys.argv[2]
usd_path = os.path.join(out, "usdcat_full.usda")

text = ""
source = None
if os.path.exists(usd_path) and os.path.getsize(usd_path) > 0:
    text = open(usd_path, "r", encoding="utf-8", errors="replace").read()
    source = "usdcat_full.usda"
else:
    import subprocess
    try:
        text = subprocess.check_output(["strings", model], text=True, errors="replace")
        source = "strings"
    except Exception as e:
        print("Could not read usdcat or strings:", repr(e))
        sys.exit(0)

print("SOURCE:", source)
print("TEXT_LENGTH:", len(text))

def print_matches(title, pattern, limit=200):
    print("\n==", title, "==")
    count = 0
    for m in re.finditer(pattern, text, re.I | re.M):
        s = m.group(0)
        print(s[:500].replace("\n", "\\n"))
        count += 1
        if count >= limit:
            print(f"... truncated after {limit}")
            break
    print("COUNT_SHOWN:", count)

# Materials and shaders
print_matches("Material definitions", r'def\s+Material\s+"[^"]+"[\s\S]{0,1500}', 80)
print_matches("Shader definitions", r'def\s+Shader\s+"[^"]+"[\s\S]{0,1200}', 80)
print_matches("UsdPreviewSurface lines", r'.{0,120}(UsdPreviewSurface|PreviewSurface).{0,180}', 120)
print_matches("Texture/file references", r'.{0,120}(inputs:file|asset inputs:file|@[^@\n]+\.(png|jpg|jpeg|webp|tga|exr|hdr)@).{0,180}', 200)
print_matches("Opacity/transparency/cutout", r'.{0,120}(opacity|transparent|transparency|alpha|alphaThreshold|opacityThreshold).{0,180}', 200)
print_matches("Diffuse/base color", r'.{0,120}(diffuseColor|baseColor|displayColor|emissiveColor|normal|roughness|metallic).{0,180}', 200)
print_matches("Mesh definitions", r'def\s+Mesh\s+"[^"]+"', 300)
print_matches("Skin/body names", r'.{0,80}(Body|Skin|Face|Head|Hair|Arm|Leg|Hips|Spine|Chest|Torso|Eye|Mouth|Teeth|Eyelash).{0,120}', 300)
print_matches("Material bindings", r'.{0,120}(material:binding|rel material:binding|bind:material).{0,220}', 300)
PY

echo "== Check referenced texture paths exist ==" | tee "$OUT/texture_reference_check.txt"
python3 <<'PY' "$OUT" > "$OUT/texture_reference_check.txt" 2>&1
import sys, os, re, glob
out = sys.argv[1]
usd = os.path.join(out, "usdcat_full.usda")
text = ""
if os.path.exists(usd):
    text = open(usd, "r", encoding="utf-8", errors="replace").read()
else:
    scan = os.path.join(out, "usdc_strings_scan.txt")
    if os.path.exists(scan):
        text = open(scan, "r", encoding="utf-8", errors="replace").read()

refs = set()
for pat in [
    r'@([^@\n]+\.(?:png|jpg|jpeg|webp|tga|exr|hdr))@',
    r'asset inputs:file\s*=\s*@([^@\n]+)@',
    r'inputs:file\s*=\s*@([^@\n]+)@',
    r'([A-Za-z0-9_\-./ ]+\.(?:png|jpg|jpeg|webp|tga|exr|hdr))',
]:
    for m in re.finditer(pat, text, re.I):
        refs.add(m.group(1).strip())

print("REFERENCED_TEXTURES:", len(refs))
all_files = []
for root, dirs, files in os.walk("."):
    if "/.git" in root or "/build" in root:
        continue
    for f in files:
        all_files.append(os.path.join(root, f))

for ref in sorted(refs):
    candidates = []
    normalized_ref = ref.replace("\\", "/")
    base = os.path.basename(normalized_ref)
    for f in all_files:
        if os.path.basename(f) == base or f.replace("\\","/").endswith(normalized_ref):
            candidates.append(f)
    print("\nREF:", ref)
    if candidates:
        print("FOUND:")
        for c in candidates[:20]:
            print("  ", c)
    else:
        print("MISSING")
PY

echo "== SceneKit bundle/resource check ==" | tee "$OUT/bundle_resource_check.txt"
for app in build/*.app build/*/*.app *.app; do
  [ -d "$app" ] || continue
  echo "---- APP: $app ----" >> "$OUT/bundle_resource_check.txt"
  find "$app/Contents/Resources" -maxdepth 4 -type f | sort >> "$OUT/bundle_resource_check.txt" 2>/dev/null || true
done

echo "== Generate Objective-C debug patch suggestion ==" | tee "$OUT/SCENEKIT_DEBUG_PATCH.txt"
cat > "$OUT/SCENEKIT_DEBUG_PATCH.txt" <<'TXT'
Add this kind of debug code after loading AI.usdc.

static void DumpNode(SCNNode *node, NSInteger depth) {
    NSMutableString *indent = [NSMutableString string];
    for (NSInteger i = 0; i < depth; i++) [indent appendString:@"  "];

    SCNVector3 min, max;
    [node getBoundingBoxMin:&min max:&max];

    NSLog(@"%@NODE name=%@ hidden=%d opacity=%f children=%lu hasGeometry=%d bboxMin=(%f,%f,%f) bboxMax=(%f,%f,%f)",
          indent,
          node.name ?: @"<nil>",
          node.hidden,
          node.opacity,
          (unsigned long)node.childNodes.count,
          node.geometry != nil,
          min.x, min.y, min.z,
          max.x, max.y, max.z);

    if (node.geometry) {
        NSLog(@"%@  GEOMETRY materials=%lu", indent, (unsigned long)node.geometry.materials.count);
        NSInteger idx = 0;
        for (SCNMaterial *m in node.geometry.materials) {
            NSLog(@"%@  MAT[%ld] name=%@ diffuse=%@ transparency=%f doubleSided=%d writesDepth=%d readsDepth=%d cullMode=%ld lighting=%@",
                  indent,
                  (long)idx,
                  m.name ?: @"<nil>",
                  m.diffuse.contents,
                  m.transparency,
                  m.doubleSided,
                  m.writesToDepthBuffer,
                  m.readsFromDepthBuffer,
                  (long)m.cullMode,
                  m.lightingModelName);
            idx++;
        }
    }

    for (SCNNode *child in node.childNodes) {
        DumpNode(child, depth + 1);
    }
}

static void ForceVisibleNode(SCNNode *node) {
    node.hidden = NO;
    node.opacity = 1.0;
    node.categoryBitMask = 1;

    if (node.geometry) {
        for (SCNMaterial *m in node.geometry.materials) {
            m.diffuse.contents = [NSColor whiteColor];
            m.emission.contents = [NSColor colorWithWhite:0.15 alpha:1.0];
            m.transparency = 1.0;
            m.doubleSided = YES;
            m.writesToDepthBuffer = YES;
            m.readsFromDepthBuffer = YES;
            m.cullMode = SCNCullModeBack;
            m.lightingModelName = SCNLightingModelConstant;
        }
    }

    for (SCNNode *child in node.childNodes) {
        ForceVisibleNode(child);
    }
}

Use:
DumpNode(modelNode, 0);
ForceVisibleNode(modelNode);

Interpretation:
- If body appears white, materials/textures are the issue.
- If body still does not appear, AI.usdc likely lacks body mesh or the app only attaches a head/hair node.
TXT

echo "== Python USD body/material heuristic ==" | tee "$OUT/body_material_heuristic.txt"
python3 <<'PY' "$OUT" > "$OUT/body_material_heuristic.txt" 2>&1
import sys, os, re
out = sys.argv[1]
text = ""
for name in ["usdcat_full.usda", "usdc_strings_scan.txt"]:
    p = os.path.join(out, name)
    if os.path.exists(p):
        text += "\n" + open(p, "r", encoding="utf-8", errors="replace").read()

terms = {
    "body": r"\b(body|skin|torso|chest|spine|hips|leg|arm|hand|foot)\b",
    "head": r"\b(head|face|eye|mouth|teeth|hair|ear|eyelash)\b",
    "mesh": r"\b(def Mesh|Mesh)\b",
    "material": r"\b(def Material|Material|UsdPreviewSurface|Shader)\b",
    "texture": r"\.(png|jpg|jpeg|webp|tga|exr|hdr)\b",
    "opacity": r"\b(opacity|alpha|transparent|transparency)\b"
}
for k, pat in terms.items():
    matches = re.findall(pat, text, re.I)
    print(f"{k}: {len(matches)}")

print("\nHeuristic:")
body_count = len(re.findall(terms["body"], text, re.I))
head_count = len(re.findall(terms["head"], text, re.I))
mesh_count = len(re.findall(terms["mesh"], text, re.I))
print("body_terms=", body_count, "head_terms=", head_count, "mesh_terms=", mesh_count)
if mesh_count == 0:
    print("WARNING: Could not find mesh names in textual extraction. Need SceneKit runtime DumpNode.")
elif body_count == 0 and head_count > 0:
    print("LIKELY: USD contains head/face/hair naming but no obvious body naming.")
elif body_count > 0:
    print("POSSIBLE: Body-related data exists. If not visible, investigate materials, node attachment, camera, or bounding boxes.")
else:
    print("UNKNOWN: Names are not descriptive. Need runtime node dump.")
PY

echo "== Archive ==" 
zip -qr "$OUT.zip" "$OUT"

echo ""
echo "DEBUG COMPLETO."
echo "Carpeta: $OUT"
echo "ZIP: $OUT.zip"
echo ""
echo "Pásame el ZIP o pega estos archivos:"
echo "1) $OUT/usd_material_summary.txt"
echo "2) $OUT/texture_reference_check.txt"
echo "3) $OUT/body_material_heuristic.txt"
echo "4) $OUT/main_code_search.txt"
echo "5) $OUT/suspicious_scenekit_code.txt"
