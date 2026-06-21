#import <AppKit/AppKit.h>
#import <SceneKit/SceneKit.h>

static NSURL *ModelURL(void) {
    NSBundle *bundle = [NSBundle mainBundle];
    NSURL *resourceURL = [bundle URLForResource:@"AI" withExtension:@"usdc"];
    if (resourceURL != nil) {
        return resourceURL;
    }

    NSString *cwd = [[NSFileManager defaultManager] currentDirectoryPath];
    return [NSURL fileURLWithPath:[cwd stringByAppendingPathComponent:@"AI.usdc"]];
}

static NSString * const VroidOverlayWindowFrameDefaultsKey = @"VroidOverlayWindowFrame";
static NSString * const VroidOverlayLogsWindowFrameDefaultsKey = @"VroidOverlayLogsWindowFrame";
static NSString * const VroidOverlayAgentStateRelativePath = @"local_agent/agent_state.json";
static NSString * const VroidOverlayMemoryModeKey = @"memory_mode";
static NSString * const VroidOverlayMemoryModeConversational = @"conversational";
static NSString * const VroidOverlayMemoryModeProgrammer = @"programmer";
static CGFloat const VroidOverlaySpeechBubbleMinWidth = 180.0;
static CGFloat const VroidOverlaySpeechBubbleMaxWidth = 420.0;
static CGFloat const VroidOverlaySpeechBubbleMinHeight = 56.0;
static NSTimeInterval const VroidOverlaySpeechBubbleMinVisibleSeconds = 2.4;
static NSTimeInterval const VroidOverlaySpeechBubbleDismissDelaySeconds = 2.1;

static NSString *VroidOverlaySupportDirectoryPath(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *base = paths.firstObject ?: NSTemporaryDirectory();
    return [base stringByAppendingPathComponent:@"VroidOverlay"];
}

static NSString *VroidOverlayBridgeDebugLogPath(void) {
    NSString *override = [[[NSProcessInfo processInfo] environment] objectForKey:@"VROID_DEBUG_LOG_PATH"];
    if (override.length > 0) {
        return [override stringByStandardizingPath];
    }

    NSString *dir = VroidOverlaySupportDirectoryPath();
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"bridge_debug.log"];
}

static NSString *VroidOverlayOverlayDebugLogPath(void) {
    NSString *override = [[[NSProcessInfo processInfo] environment] objectForKey:@"VROID_OVERLAY_DEBUG_LOG_PATH"];
    if (override.length > 0) {
        return [override stringByStandardizingPath];
    }

    NSString *dir = VroidOverlaySupportDirectoryPath();
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"overlay_debug.log"];
}

static NSString *VroidOverlaySpeechTraceLogPath(void) {
    NSString *override = [[[NSProcessInfo processInfo] environment] objectForKey:@"VROID_SPEECH_TRACE_LOG_PATH"];
    if (override.length > 0) {
        return [override stringByStandardizingPath];
    }

    NSString *dir = VroidOverlaySupportDirectoryPath();
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"speech_trace.jsonl"];
}

@protocol RotationControlUpdating <NSObject>
- (void)refreshFromSceneView;
@end

@class RotationControlWindowController;

@interface OverlaySceneView : SCNView
- (void)loadModelAtURL:(NSURL *)url;
- (void)applyRotationX:(CGFloat)x y:(CGFloat)y z:(CGFloat)z;
- (NSString *)rotationString;
- (void)vroidRefreshBackdropForContainer:(SCNNode *)container;
- (void)vroidApplyFloatAnimationToNode:(SCNNode *)node;
- (void)vroidSpeakText:(NSString *)text;
- (void)vroidStopSpeaking;
- (void)vroidHandleAICommandJSON:(NSString *)jsonString;
- (void)vroidHandleAICommandDictionary:(NSDictionary *)command;
- (void)vroidHandlePlainTextResponse:(NSString *)text source:(NSString *)source;
- (void)vroidSetPendingSpeechText:(NSString *)text;
- (void)vroidStartPendingSpeechIfNeeded;
- (void)vroidSaveWindowFrame;
- (void)vroidMoveWindowAwayFromScreenPoint:(NSPoint)screenPoint;
- (void)vroidStartEventStreamMonitoring;
- (void)vroidStopEventStreamMonitoring;
- (void)vroidShowChatInputWindow;
- (void)vroidHideChatInputWindow;
- (void)vroidSubmitChatInput:(id)sender;
- (void)vroidBeginChatPrompt:(NSString *)prompt;
- (NSString *)vroidProjectRootPath;
- (BOOL)tuliMouseRepelEnabled;
- (void)tuliStartMouseRepel;
- (void)tuliStopMouseRepel;
- (void)tuliTickMouseRepel:(NSTimer *)timer;
- (NSPoint)tuliClampedWindowOrigin:(NSPoint)origin frameSize:(NSSize)frameSize;
@property (nonatomic, weak) id<RotationControlUpdating> rotationControlWindowController;
@end

@implementation OverlaySceneView {
    SCNNode *_cameraNode;
    SCNNode *_backdropNode;
    SCNNode *_modelContainer;
    SCNNode *_floatNode;
    SCNNode *_axesNode;
    SCNNode *_rotationNode;
    NSArray<NSDictionary *> *_blinkTargets;
    NSArray<NSDictionary *> *_speechTargets;
    SCNNode *_speechNode;
    NSString *_pendingSpeechText;
    NSString *_pendingSpeechEventID;
    NSDictionary *_pendingAICommand;
    NSTask *_speechTask;
    NSString *_speechVoiceName;
    NSURLSessionDataTask *_ttsRequestTask;
    NSString *_eventStreamPath;
    unsigned long long _eventStreamOffset;
    NSString *_eventStreamRemainder;
    NSTimer *_eventStreamPollTimer;
    BOOL _eventStreamMissingLogged;
    BOOL _eventStreamWaitingLogged;
    BOOL _eventStreamActivityLogged;
    NSPanel *_speechBubbleWindow;
    NSTextField *_speechBubbleLabel;
    NSTimeInterval _speechBubbleLastShownAt;
    NSUInteger _speechBubbleToken;
    NSUInteger _blinkToken;
    NSUInteger _speechToken;
    BOOL _isDragging;
    BOOL _didDrag;
    BOOL _isRepositioning;
    BOOL _animationsPausedForHold;
    NSUInteger _holdToken;
    BOOL _holdScaleCaptured;
    SCNVector3 _holdOriginalScale;
    NSUInteger _rapidTapCount;
    NSTimeInterval _lastRapidTapTime;
    NSPoint _lastDragPoint;
    NSPoint _mouseDownPoint;
    NSPoint _mouseDownScreenPoint;
    NSPoint _windowDragStartOrigin;
    NSTimeInterval _mouseDownTime;
    SCNVector3 _dragStartRotation;
    NSTimer *_mouseRepelTimer;
    CGFloat _mouseRepelVelocityX;
    CGFloat _mouseRepelVelocityY;
    BOOL _mouseRepelEnabled;
    NSPanel *_chatInputWindow;
    NSTextField *_chatInputField;
    NSTextField *_chatInputStatusLabel;
    NSTask *_chatTask;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.clearColor.CGColor;
        self.backgroundColor = NSColor.clearColor;
        self.allowsCameraControl = NO;
        self.autoenablesDefaultLighting = NO;
        self.rendersContinuously = YES;
        self.antialiasingMode = SCNAntialiasingModeMultisampling4X;

        SCNScene *scene = [SCNScene scene];
        scene.background.contents = NSColor.clearColor;

        _cameraNode = [SCNNode node];
        _cameraNode.camera = [SCNCamera camera];
        _cameraNode.camera.zNear = 0.01;
        _cameraNode.camera.zFar = 100.0;
        _cameraNode.position = SCNVector3Make(0.0, 0.0, 8.0);
        [scene.rootNode addChildNode:_cameraNode];

        SCNLight *ambientLight = [SCNLight light];
        ambientLight.type = SCNLightTypeAmbient;
        ambientLight.intensity = 700.0;
        SCNNode *ambientNode = [SCNNode node];
        ambientNode.light = ambientLight;
        [scene.rootNode addChildNode:ambientNode];

        SCNLight *omniLight = [SCNLight light];
        omniLight.type = SCNLightTypeOmni;
        omniLight.intensity = 1200.0;
        SCNNode *omniNode = [SCNNode node];
        omniNode.light = omniLight;
        omniNode.position = SCNVector3Make(2.5, 3.5, 5.0);
        [scene.rootNode addChildNode:omniNode];

        self.scene = scene;
        _floatNode = [SCNNode node];
        _rotationNode = [SCNNode node];
        [_floatNode addChildNode:_rotationNode];
        [self.scene.rootNode addChildNode:_floatNode];
        [self vroidRefreshBackdropForContainer:nil];

        [self installAxisGuides];
    }
    return self;
}

- (void)dealloc {
    [self tuliStopMouseRepel];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];

    if (self.window == nil) {
        [self tuliStopMouseRepel];
    } else {
        [self tuliStartMouseRepel];
    }
}

- (void)loadModelAtURL:(NSURL *)url {
    if (url == nil) {
        [self installFallbackModel];
        return;
    }

    NSError *error = nil;
    SCNScene *loadedScene = nil;

    @try {
        loadedScene = [SCNScene sceneWithURL:url options:@{} error:&error];
    } @catch (NSException *exception) {
        NSLog(@"Exception while loading model at %@: %@", url, exception);
    }

    if (loadedScene == nil) {
        NSLog(@"Failed to load model at %@: %@", url, error);
        [self installFallbackModel];
        return;
    }

    [self logSceneSummary:loadedScene sourceURL:url];

    SCNNode *container = [SCNNode node];
    SCNNode *rootClone = [loadedScene.rootNode clone];
    rootClone.hidden = NO;
    rootClone.opacity = 1.0;
    [container addChildNode:rootClone];

    [self freezeAnimatedHierarchy:rootClone];
    [self logNodeTree:rootClone label:@"cloned-root" indent:0];

    [self vroidRuntimeRepairLoadedContainer:container];
    [self vroidApplyTexturedVisibleFixToContainer:container];
    [self vroidApplyFaceCameraFixForContainer:container];
    [self centerAndFitNode:container];
    [self vroidRefreshBackdropForContainer:container];
    [self vroidApplyFloatAnimationToNode:_floatNode];
    [self logNodeState:container label:@"container-after-center"];
    _modelContainer = container;
    [_rotationNode addChildNode:container];
    _blinkTargets = [self vroidCollectBlinkTargetsInNode:container targetName:@"Fcl_EYE_Joy"];
    _speechTargets = [self vroidCollectSpeechTargetsInNode:container];
    [self vroidStartRandomBlinkLoop];
    NSString *speechText = [[[NSProcessInfo processInfo] environment] objectForKey:@"VROID_SPEECH_TEXT"];
    if (speechText.length > 0) {
        [self vroidSetPendingSpeechText:speechText];
    }

    NSString *aiCommand = [[[NSProcessInfo processInfo] environment] objectForKey:@"VROID_AI_COMMAND"];
    if (aiCommand.length > 0) {
        [self vroidHandleAICommandJSON:aiCommand];
    }

    [self vroidStartEventStreamMonitoring];

    [self applyRotationX:0.0 y:M_PI z:0.0];
    [self notifyRotationChanged];
}



#pragma mark - VROID Runtime Repair Helpers

- (BOOL)vroidEnvEnabled:(NSString *)name {
    NSString *value = [[[NSProcessInfo processInfo] environment] objectForKey:name];
    if (!value) return NO;
    value = [value lowercaseString];
    return [value isEqualToString:@"1"] ||
           [value isEqualToString:@"true"] ||
           [value isEqualToString:@"yes"] ||
           [value isEqualToString:@"on"];
}

- (void)vroidDumpNodeTree:(SCNNode *)node label:(NSString *)label indent:(NSUInteger)indent {
    if (!node) return;

    NSMutableString *pad = [NSMutableString string];
    for (NSUInteger i = 0; i < indent; i++) {
        [pad appendString:@"  "];
    }

    SCNVector3 minVec, maxVec;
    BOOL hasBounds = [node getBoundingBoxMin:&minVec max:&maxVec];

    NSLog(@"%@[%@] node=%@ hidden=%d opacity=%.3f children=%lu hasGeometry=%d bounds=%d min=(%.4f, %.4f, %.4f) max=(%.4f, %.4f, %.4f) pos=(%.4f, %.4f, %.4f) scale=(%.4f, %.4f, %.4f)",
          pad,
          label ?: @"node",
          node.name ?: @"<nil>",
          node.hidden,
          node.opacity,
          (unsigned long)node.childNodes.count,
          node.geometry != nil,
          hasBounds,
          minVec.x, minVec.y, minVec.z,
          maxVec.x, maxVec.y, maxVec.z,
          node.position.x, node.position.y, node.position.z,
          node.scale.x, node.scale.y, node.scale.z);

    if (node.geometry) {
        NSLog(@"%@  geometry=%@ materials=%lu",
              pad,
              node.geometry.name ?: NSStringFromClass(node.geometry.class),
              (unsigned long)node.geometry.materials.count);

        NSInteger idx = 0;
        for (SCNMaterial *mat in node.geometry.materials) {
            NSLog(@"%@  material[%ld] name=%@ diffuse=%@ transparency=%.3f doubleSided=%d writesDepth=%d readsDepth=%d cullMode=%ld lighting=%@",
                  pad,
                  (long)idx,
                  mat.name ?: @"<nil>",
                  mat.diffuse.contents,
                  mat.transparency,
                  mat.doubleSided,
                  mat.writesToDepthBuffer,
                  mat.readsFromDepthBuffer,
                  (long)mat.cullMode,
                  mat.lightingModelName);
            idx++;
        }
    }

    for (SCNNode *child in node.childNodes) {
        [self vroidDumpNodeTree:child label:@"child" indent:indent + 1];
    }
}

- (void)vroidRepairVisibilityForNode:(SCNNode *)node {
    if (!node) return;

    node.hidden = NO;
    node.opacity = 1.0;
    node.categoryBitMask = 1;

    if (node.geometry) {
        for (SCNMaterial *mat in node.geometry.materials) {
            mat.transparency = 1.0;
            mat.doubleSided = YES;
            mat.writesToDepthBuffer = YES;
            mat.readsFromDepthBuffer = YES;
            mat.cullMode = SCNCullModeBack;

            if (!mat.lightingModelName) {
                mat.lightingModelName = SCNLightingModelBlinn;
            }

            if (!mat.diffuse.contents) {
                mat.diffuse.contents = [NSColor whiteColor];
            }
        }
    }

    for (SCNNode *child in node.childNodes) {
        [self vroidRepairVisibilityForNode:child];
    }
}

- (void)vroidForceWhiteMaterialsForNode:(SCNNode *)node {
    if (!node) return;

    node.hidden = NO;
    node.opacity = 1.0;
    node.categoryBitMask = 1;

    if (node.geometry) {
        for (SCNMaterial *mat in node.geometry.materials) {
            mat.diffuse.contents = [NSColor whiteColor];
            mat.emission.contents = [NSColor colorWithWhite:0.18 alpha:1.0];
            mat.transparency = 1.0;
            mat.doubleSided = YES;
            mat.writesToDepthBuffer = YES;
            mat.readsFromDepthBuffer = YES;
            mat.cullMode = SCNCullModeBack;
            mat.lightingModelName = SCNLightingModelConstant;
        }
    }

    for (SCNNode *child in node.childNodes) {
        [self vroidForceWhiteMaterialsForNode:child];
    }
}

- (void)vroidAddDebugBoundsForNode:(SCNNode *)node toRoot:(SCNNode *)root {
    if (!node || !root) return;

    if (node.geometry) {
        SCNVector3 minVec, maxVec;
        BOOL hasBounds = [node getBoundingBoxMin:&minVec max:&maxVec];

        if (hasBounds) {
            CGFloat w = MAX(0.001, maxVec.x - minVec.x);
            CGFloat h = MAX(0.001, maxVec.y - minVec.y);
            CGFloat d = MAX(0.001, maxVec.z - minVec.z);

            SCNBox *box = [SCNBox boxWithWidth:w height:h length:d chamferRadius:0.0];
            box.firstMaterial.diffuse.contents = [NSColor colorWithCalibratedRed:1.0 green:0.1 blue:0.1 alpha:0.18];
            box.firstMaterial.emission.contents = [NSColor colorWithCalibratedRed:1.0 green:0.1 blue:0.1 alpha:0.25];
            box.firstMaterial.transparency = 0.25;
            box.firstMaterial.doubleSided = YES;
            box.firstMaterial.writesToDepthBuffer = NO;
            box.firstMaterial.readsFromDepthBuffer = NO;

            SCNNode *boxNode = [SCNNode nodeWithGeometry:box];
            boxNode.name = [NSString stringWithFormat:@"DEBUG_BOUNDS_%@", node.name ?: @"node"];
            boxNode.position = SCNVector3Make((minVec.x + maxVec.x) * 0.5,
                                              (minVec.y + maxVec.y) * 0.5,
                                              (minVec.z + maxVec.z) * 0.5);
            boxNode.renderingOrder = 999;
            [node addChildNode:boxNode];
        }
    }

    for (SCNNode *child in node.childNodes) {
        [self vroidAddDebugBoundsForNode:child toRoot:root];
    }
}

- (void)vroidRuntimeRepairLoadedContainer:(SCNNode *)container {
    if (!container) return;

    NSLog(@"[VROID_FIX] Runtime repair started. container=%@", container);

    [self vroidRepairVisibilityForNode:container];

    if ([self vroidEnvEnabled:@"VROID_FORCE_WHITE"]) {
        NSLog(@"[VROID_FIX] VROID_FORCE_WHITE=1 active");
        [self vroidForceWhiteMaterialsForNode:container];
    }

    if ([self vroidEnvEnabled:@"VROID_SHOW_BOUNDS"]) {
        NSLog(@"[VROID_FIX] VROID_SHOW_BOUNDS=1 active");
        [self vroidAddDebugBoundsForNode:container toRoot:container];
    }

    if ([self vroidEnvEnabled:@"VROID_DEBUG"]) {
        NSLog(@"[VROID_FIX] VROID_DEBUG=1 active. Dumping node tree...");
        [self vroidDumpNodeTree:container label:@"container-after-repair" indent:0];
    }

    NSLog(@"[VROID_FIX] Runtime repair finished.");
}




#pragma mark - VROID Textured Visibility Fix

- (void)vroidMakeTexturesVisibleForNode:(SCNNode *)node {
    if (!node) return;

    node.hidden = NO;
    node.opacity = 1.0;
    node.categoryBitMask = 1;

    if (node.geometry) {
        for (SCNMaterial *mat in node.geometry.materials) {
            mat.transparency = 1.0;
            mat.doubleSided = YES;
            mat.cullMode = SCNCullModeBack;

            // Mantener texturas originales, pero evitar que PhysicallyBased las oscurezca o las vuelva raras.
            mat.lightingModelName = SCNLightingModelConstant;

            // Para rostro/cabello con alpha/texturas, esto suele ser más estable en SceneKit.
            mat.writesToDepthBuffer = YES;
            mat.readsFromDepthBuffer = YES;

            // Si la textura existe en diffuse, no la reemplazamos.
            // Si no existe, ponemos blanco de fallback.
            if (!mat.diffuse.contents) {
                mat.diffuse.contents = [NSColor whiteColor];
            }

            // Evita que emission vieja o vacía afecte demasiado.
            if (!mat.emission.contents) {
                mat.emission.contents = [NSColor blackColor];
            }

            NSLog(@"[TEXTURE_FIX] material=%@ diffuse=%@ lighting=%@ transparency=%.3f doubleSided=%d",
                  mat.name ?: @"<nil>",
                  mat.diffuse.contents,
                  mat.lightingModelName,
                  mat.transparency,
                  mat.doubleSided);
        }
    }

    for (SCNNode *child in node.childNodes) {
        [self vroidMakeTexturesVisibleForNode:child];
    }
}

- (void)vroidApplyTexturedVisibleFixToContainer:(SCNNode *)container {
    if (!container) return;
    NSLog(@"[TEXTURE_FIX] Applying textured visibility fix");
    [self vroidMakeTexturesVisibleForNode:container];
}




#pragma mark - VROID Face Camera Fix

- (CGFloat)vroidCameraEnvFloat:(NSString *)name defaultValue:(CGFloat)defaultValue {
    NSString *value = [[[NSProcessInfo processInfo] environment] objectForKey:name];
    if (!value || value.length == 0) return defaultValue;
    return (CGFloat)[value doubleValue];
}

- (BOOL)vroidCameraEnvBool:(NSString *)name defaultValue:(BOOL)defaultValue {
    NSString *value = [[[NSProcessInfo processInfo] environment] objectForKey:name];
    if (!value || value.length == 0) return defaultValue;
    value = [value lowercaseString];
    if ([value isEqualToString:@"1"] || [value isEqualToString:@"true"] || [value isEqualToString:@"yes"] || [value isEqualToString:@"on"]) return YES;
    if ([value isEqualToString:@"0"] || [value isEqualToString:@"false"] || [value isEqualToString:@"no"] || [value isEqualToString:@"off"]) return NO;
    return defaultValue;
}

- (void)vroidApplyFaceCameraFixForContainer:(SCNNode *)container {
    if (!_cameraNode || !_cameraNode.camera || !container) return;

    CGFloat cameraZ = [self vroidCameraEnvFloat:@"VROID_CAMERA_Z" defaultValue:8.0];
    CGFloat orthoScale = [self vroidCameraEnvFloat:@"VROID_ORTHO_SCALE" defaultValue:3.6];
    CGFloat perspectiveFOV = [self vroidCameraEnvFloat:@"VROID_CAMERA_FOV" defaultValue:22.0];
    BOOL useOrtho = [self vroidCameraEnvBool:@"VROID_ORTHO" defaultValue:YES];

    _cameraNode.position = SCNVector3Make(0.0, 0.0, cameraZ);
    _cameraNode.eulerAngles = SCNVector3Make(0.0, 0.0, 0.0);

    _cameraNode.camera.zNear = 0.001;
    _cameraNode.camera.zFar = 200.0;

    if (useOrtho) {
        _cameraNode.camera.usesOrthographicProjection = YES;
        _cameraNode.camera.orthographicScale = orthoScale;
        NSLog(@"[FACE_CAMERA] Orthographic camera active. z=%.3f scale=%.3f", cameraZ, orthoScale);
    } else {
        _cameraNode.camera.usesOrthographicProjection = NO;
        _cameraNode.camera.fieldOfView = perspectiveFOV;
        NSLog(@"[FACE_CAMERA] Perspective camera active. z=%.3f fov=%.3f", cameraZ, perspectiveFOV);
    }

    // Mantener el rostro centrado sin empujar demasiado hacia cámara.
    SCNVector3 minVec, maxVec;
    BOOL hasBounds = [container getBoundingBoxMin:&minVec max:&maxVec];

    if (hasBounds) {
        CGFloat centerX = (minVec.x + maxVec.x) * 0.5;
        CGFloat centerY = (minVec.y + maxVec.y) * 0.5;
        CGFloat centerZ = (minVec.z + maxVec.z) * 0.5;

        // Ajuste suave. No escala agresiva aquí para evitar deformación percibida.
        container.position = SCNVector3Make(container.position.x - centerX * container.scale.x,
                                            container.position.y - centerY * container.scale.y,
                                            container.position.z - centerZ * container.scale.z);

        NSLog(@"[FACE_CAMERA] container bounds min=(%.4f %.4f %.4f) max=(%.4f %.4f %.4f) center=(%.4f %.4f %.4f)",
              minVec.x, minVec.y, minVec.z,
              maxVec.x, maxVec.y, maxVec.z,
              centerX, centerY, centerZ);
    }
}




#pragma mark - VROID Fixed Look Rotation

- (BOOL)vroidUnlockRotationEnabled {
    NSString *value = [[[NSProcessInfo processInfo] environment] objectForKey:@"VROID_UNLOCK_ROTATION"];
    if (!value) return NO;

    value = [value lowercaseString];

    return [value isEqualToString:@"1"] ||
           [value isEqualToString:@"true"] ||
           [value isEqualToString:@"yes"] ||
           [value isEqualToString:@"on"];
}

- (SCNVector3)vroidFixedLookRotation {
    return SCNVector3Make(-1.567, 6.298, 0.000);
}

- (void)vroidApplyFixedLookRotation {
    if (!_rotationNode) return;

    if ([self vroidUnlockRotationEnabled]) {
        NSLog(@"[FIXED_ROTATION] unlocked by VROID_UNLOCK_ROTATION=1");
        return;
    }

    _rotationNode.eulerAngles = [self vroidFixedLookRotation];

    NSLog(@"[FIXED_ROTATION] applied x=-1.567 y=6.298 z=0.000");
}




#pragma mark - VROID Hide Rotation UI / Gizmo

- (BOOL)vroidShowControlsEnabled {
    NSString *value = [[[NSProcessInfo processInfo] environment] objectForKey:@"VROID_SHOW_CONTROLS"];
    if (!value) return NO;
    value = [value lowercaseString];

    return [value isEqualToString:@"1"] ||
           [value isEqualToString:@"true"] ||
           [value isEqualToString:@"yes"] ||
           [value isEqualToString:@"on"];
}

- (BOOL)vroidShowGizmoEnabled {
    NSString *value = [[[NSProcessInfo processInfo] environment] objectForKey:@"VROID_SHOW_GIZMO"];
    if (!value) return NO;
    value = [value lowercaseString];

    return [value isEqualToString:@"1"] ||
           [value isEqualToString:@"true"] ||
           [value isEqualToString:@"yes"] ||
           [value isEqualToString:@"on"];
}

- (BOOL)vroidViewContainsSceneView:(NSView *)view {
    if (!view) return NO;

    if ([view isKindOfClass:[SCNView class]]) {
        return YES;
    }

    for (NSView *child in view.subviews) {
        if ([self vroidViewContainsSceneView:child]) {
            return YES;
        }
    }

    return NO;
}

- (void)vroidHideRotationPanelInView:(NSView *)view {
    if (!view) return;

    if ([self vroidShowControlsEnabled]) {
        NSLog(@"[HIDE_UI] VROID_SHOW_CONTROLS=1 active; controls visible");
        return;
    }

    for (NSView *child in [view.subviews copy]) {
        if ([child isKindOfClass:[SCNView class]]) {
            child.hidden = NO;
            continue;
        }

        BOOL childContainsScene = [self vroidViewContainsSceneView:child];

        if (childContainsScene) {
            [self vroidHideRotationPanelInView:child];
        } else {
            child.hidden = YES;
            child.alphaValue = 0.0;
            NSLog(@"[HIDE_UI] hidden overlay/control view: %@", child);
        }
    }
}

- (void)vroidHideAxesGizmo {
    if ([self vroidShowGizmoEnabled]) {
        NSLog(@"[HIDE_GIZMO] VROID_SHOW_GIZMO=1 active; gizmo visible");
        return;
    }

    if (_axesNode) {
        _axesNode.hidden = YES;
        _axesNode.opacity = 0.0;
        [_axesNode removeFromParentNode];
        NSLog(@"[HIDE_GIZMO] axes/gizmo node removed");
    }

    NSArray<SCNNode *> *rootChildren = [self.scene.rootNode.childNodes copy];
    for (SCNNode *node in rootChildren) {
        NSString *name = node.name ?: @"";
        NSString *lower = [name lowercaseString];

        if ([lower containsString:@"axis"] ||
            [lower containsString:@"axes"] ||
            [lower containsString:@"gizmo"] ||
            [lower containsString:@"debug_bounds"]) {
            node.hidden = YES;
            node.opacity = 0.0;
            [node removeFromParentNode];
            NSLog(@"[HIDE_GIZMO] removed node by name: %@", name);
        }
    }
}

- (void)vroidApplyCleanOverlayMode {
    [self vroidHideAxesGizmo];

    NSWindow *window = self.window;
    if (window && window.contentView) {
        [self vroidHideRotationPanelInView:window.contentView];
    }

    NSLog(@"[CLEAN_UI] rotation panel and gizmo hidden");
}


- (void)centerAndFitNode:(SCNNode *)node {
    SCNVector3 minVec = SCNVector3Zero;
    SCNVector3 maxVec = SCNVector3Zero;
    if (![node getBoundingBoxMin:&minVec max:&maxVec]) {
        return;
    }

    CGFloat width = maxVec.x - minVec.x;
    CGFloat height = maxVec.y - minVec.y;
    CGFloat depth = maxVec.z - minVec.z;
    CGFloat largest = MAX(width, MAX(height, depth));
    if (largest <= 0.0) {
        return;
    }

    CGFloat scale = 2.6 / largest;
    node.scale = SCNVector3Make(scale, scale, scale);

    CGFloat centeredX = (minVec.x + maxVec.x) * 0.5f;
    CGFloat centeredY = (minVec.y + maxVec.y) * 0.5f;
    CGFloat centeredZ = (minVec.z + maxVec.z) * 0.5f;
    node.position = SCNVector3Make(-centeredX * scale, -centeredY * scale, -centeredZ * scale);

    CGFloat cameraDistance = MAX(2.5, largest * 3.0);
    /* disabled by face camera fix: _cameraNode.position = SCNVector3Make(0.0, 0.0, cameraDistance); */
}

- (void)installFallbackModel {
    SCNSphere *sphere = [SCNSphere sphereWithRadius:0.8];
    sphere.firstMaterial.diffuse.contents = NSColor.systemPinkColor;
    SCNNode *node = [SCNNode nodeWithGeometry:sphere];
    _modelContainer = node;
    [_rotationNode addChildNode:node];
    [self vroidRefreshBackdropForContainer:node];
}

- (NSColor *)vroidBackdropBaseColorForContainer:(SCNNode *)container {
    CGFloat bestScore = -FLT_MAX;
    NSColor *bestColor = nil;

    NSArray<SCNNode *> *roots = container != nil ? @[container] : @[];
    for (SCNNode *root in roots) {
        NSArray<SCNNode *> *stack = @[root];
        NSMutableArray<SCNNode *> *queue = [stack mutableCopy];

        while (queue.count > 0) {
            SCNNode *node = queue.lastObject;
            [queue removeLastObject];

            if (node.geometry != nil) {
                for (SCNMaterial *material in node.geometry.materials) {
                    NSArray *contentsCandidates = @[
                        material.emission.contents ?: [NSNull null],
                        material.diffuse.contents ?: [NSNull null]
                    ];
                    for (id contents in contentsCandidates) {
                        NSColor *color = nil;
                        if ([contents isKindOfClass:[NSColor class]]) {
                            color = (NSColor *)contents;
                        } else if (contents != [NSNull null] && CFGetTypeID((__bridge CFTypeRef)contents) == CGColorGetTypeID()) {
                            color = [NSColor colorWithCGColor:(__bridge CGColorRef)contents];
                        }

                        if (color == nil) {
                            continue;
                        }

                        NSColor *rgbColor = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: color;
                        CGFloat r = 0.0, g = 0.0, b = 0.0, a = 0.0;
                        [rgbColor getRed:&r green:&g blue:&b alpha:&a];

                        CGFloat redness = r - ((g + b) * 0.5);
                        CGFloat alphaWeight = MAX(0.25, a);
                        CGFloat score = redness * alphaWeight;
                        if (r > 0.15 && score > bestScore) {
                            bestScore = score;
                            bestColor = rgbColor;
                        }
                    }
                }
            }

            [queue addObjectsFromArray:node.childNodes];
        }
    }

    if (bestColor != nil) {
        return bestColor;
    }

    return [NSColor colorWithCalibratedRed:0.89 green:0.12 blue:0.14 alpha:1.0];
}

- (NSImage *)vroidRadialBackdropImageWithColor:(NSColor *)baseColor {
    NSSize size = NSMakeSize(1024.0, 1024.0);
    NSImage *image = [[NSImage alloc] initWithSize:size];
    [image lockFocus];

    NSGraphicsContext *context = NSGraphicsContext.currentContext;
    context.shouldAntialias = YES;

    NSColor *center = [baseColor colorWithAlphaComponent:0.82];
    NSColor *mid = [baseColor colorWithAlphaComponent:0.28];
    NSColor *edge = [baseColor colorWithAlphaComponent:0.0];
    NSGradient *gradient = [[NSGradient alloc] initWithColorsAndLocations:
                            center, @0.0,
                            mid, @0.42,
                            edge, @1.0,
                            nil];
    NSPoint centerPoint = NSMakePoint(size.width * 0.5, size.height * 0.5);
    CGFloat radius = MAX(size.width, size.height) * 0.5;
    [gradient drawFromCenter:centerPoint
                      radius:0.0
                    toCenter:centerPoint
                      radius:radius
                     options:0];

    [image unlockFocus];
    return image;
}

- (void)vroidRefreshBackdropForContainer:(SCNNode *)container {
    NSColor *baseColor = [self vroidBackdropBaseColorForContainer:container ?: _modelContainer];
    NSImage *image = [self vroidRadialBackdropImageWithColor:baseColor];

    if (_backdropNode == nil) {
        SCNPlane *plane = [SCNPlane planeWithWidth:42.0 height:42.0];
        SCNMaterial *material = [SCNMaterial material];
        material.diffuse.contents = image;
        material.emission.contents = image;
        material.lightingModelName = SCNLightingModelConstant;
        material.doubleSided = YES;
        material.writesToDepthBuffer = NO;
        material.readsFromDepthBuffer = NO;
        material.transparency = 1.0;
        material.blendMode = SCNBlendModeAlpha;
        plane.firstMaterial = material;

        _backdropNode = [SCNNode nodeWithGeometry:plane];
        _backdropNode.name = @"AvatarBackdrop";
        _backdropNode.position = SCNVector3Make(0.0, 0.0, -22.0);
        _backdropNode.renderingOrder = -1000;
        [self.scene.rootNode addChildNode:_backdropNode];
        return;
    }

    if (![_backdropNode.geometry isKindOfClass:[SCNPlane class]]) {
        _backdropNode.geometry = [SCNPlane planeWithWidth:42.0 height:42.0];
    }

    SCNMaterial *material = _backdropNode.geometry.firstMaterial;
    if (material == nil) {
        material = [SCNMaterial material];
        _backdropNode.geometry.firstMaterial = material;
    }
    material.diffuse.contents = image;
    material.emission.contents = image;
    material.lightingModelName = SCNLightingModelConstant;
    material.doubleSided = YES;
    material.writesToDepthBuffer = NO;
    material.readsFromDepthBuffer = NO;
    material.transparency = 1.0;
    material.blendMode = SCNBlendModeAlpha;
    _backdropNode.position = SCNVector3Make(0.0, 0.0, -22.0);
    _backdropNode.renderingOrder = -1000;
}

- (void)freezeAnimatedHierarchy:(SCNNode *)node {
    [node removeAllActions];
    [node removeAllAnimations];

    for (SCNNode *child in node.childNodes) {
        [self freezeAnimatedHierarchy:child];
    }
}

- (void)logSceneSummary:(SCNScene *)scene sourceURL:(NSURL *)url {
    NSLog(@"--- Scene summary for %@ ---", url.lastPathComponent);
    NSLog(@"root child count: %lu", (unsigned long)scene.rootNode.childNodes.count);
    NSLog(@"root animation keys: %@", scene.rootNode.animationKeys);
    [self logNodeState:scene.rootNode label:@"scene-root"];
    for (SCNNode *child in scene.rootNode.childNodes) {
        [self logNodeTree:child label:@"source-root-child" indent:1];
    }
    [self logNamedNode:@"Face" inNode:scene.rootNode];
    [self logNamedNode:@"Hair" inNode:scene.rootNode];
    [self logNamedNode:@"head" inNode:scene.rootNode];
    NSLog(@"--- End scene summary ---");
}

- (void)logNodeTree:(SCNNode *)node label:(NSString *)label indent:(NSUInteger)indent {
    NSMutableString *padding = [NSMutableString string];
    for (NSUInteger i = 0; i < indent; i++) {
        [padding appendString:@"  "];
    }

    NSString *nodeName = node.name ?: @"<unnamed>";
    NSString *geometryName = node.geometry.name ?: @"<none>";
    NSString *geomType = node.geometry ? NSStringFromClass(node.geometry.class) : @"<none>";
    NSString *children = [NSString stringWithFormat:@"%lu", (unsigned long)node.childNodes.count];
    NSString *anims = [NSString stringWithFormat:@"%lu", (unsigned long)node.animationKeys.count];
    NSString *morpher = node.morpher ? [NSString stringWithFormat:@"morpher=%lu", (unsigned long)node.morpher.targets.count] : @"morpher=none";
    NSString *skinner = node.skinner ? @"skinner=yes" : @"skinner=none";

    NSLog(@"%@[%@] %@ type=%@ geom=%@ children=%@ anims=%@ hidden=%d opacity=%.3f %@ %@ rot=(%.3f, %.3f, %.3f) pos=(%.3f, %.3f, %.3f) scale=(%.3f, %.3f, %.3f)",
          padding,
          label,
          nodeName,
          NSStringFromClass(node.class),
          geometryName,
          children,
          anims,
          node.hidden,
          node.opacity,
          morpher,
          skinner,
          node.eulerAngles.x,
          node.eulerAngles.y,
          node.eulerAngles.z,
          node.position.x,
          node.position.y,
          node.position.z,
          node.scale.x,
          node.scale.y,
          node.scale.z);

    if (node.geometry != nil) {
        [self logGeometry:node.geometry indent:indent + 1];
    }

    for (SCNNode *child in node.childNodes) {
        [self logNodeTree:child label:label indent:indent + 1];
    }
}

- (void)logGeometry:(SCNGeometry *)geometry indent:(NSUInteger)indent {
    NSMutableString *padding = [NSMutableString string];
    for (NSUInteger i = 0; i < indent; i++) {
        [padding appendString:@"  "];
    }

    SCNVector3 minVec = SCNVector3Zero;
    SCNVector3 maxVec = SCNVector3Zero;
    [geometry getBoundingBoxMin:&minVec max:&maxVec];

    NSMutableArray<NSString *> *materialNames = [NSMutableArray array];
    for (SCNMaterial *material in geometry.materials) {
        NSString *diffuse = material.diffuse.contents ? NSStringFromClass([material.diffuse.contents class]) : @"nil";
        [materialNames addObject:[NSString stringWithFormat:@"diffuse=%@", diffuse]];
    }

    NSLog(@"%@geometry class=%@ materials=%lu doubleSided=%d bboxMin=(%.4f, %.4f, %.4f) bboxMax=(%.4f, %.4f, %.4f) materials=[%@]",
          padding,
          NSStringFromClass(geometry.class),
          (unsigned long)geometry.materials.count,
          geometry.firstMaterial.doubleSided,
          minVec.x, minVec.y, minVec.z,
          maxVec.x, maxVec.y, maxVec.z,
          [materialNames componentsJoinedByString:@", "]);
}

- (void)logNodeState:(SCNNode *)node label:(NSString *)label {
    SCNVector3 minVec = SCNVector3Zero;
    SCNVector3 maxVec = SCNVector3Zero;
    BOOL hasBounds = [node getBoundingBoxMin:&minVec max:&maxVec];
    NSLog(@"%@ state: hidden=%d opacity=%.3f children=%lu bounds=%d min=(%.4f, %.4f, %.4f) max=(%.4f, %.4f, %.4f) anims=%@",
          label,
          node.hidden,
          node.opacity,
          (unsigned long)node.childNodes.count,
          hasBounds,
          minVec.x, minVec.y, minVec.z,
          maxVec.x, maxVec.y, maxVec.z,
          node.animationKeys);
}

- (void)logNamedNode:(NSString *)needle inNode:(SCNNode *)root {
    SCNNode *found = [self findNodeNamed:needle inNode:root];
    if (found == nil) {
        NSLog(@"TRACE node '%@' not found under %@", needle, root.name ?: @"<root>");
        return;
    }

    NSLog(@"TRACE node '%@' found: %@", needle, found.name ?: @"<unnamed>");
    [self logNodeState:found label:[NSString stringWithFormat:@"match-%@", needle]];
    if (found.geometry != nil) {
        [self logGeometry:found.geometry indent:1];
    }
    NSLog(@"TRACE '%@' parent chain: %@", needle, [self parentChainForNode:found]);
}

- (SCNNode *)findNodeNamed:(NSString *)needle inNode:(SCNNode *)node {
    if (needle.length == 0 || node == nil) {
        return nil;
    }

    NSRange range = [node.name rangeOfString:needle options:NSCaseInsensitiveSearch];
    if (node.name != nil && range.location != NSNotFound) {
        return node;
    }

    for (SCNNode *child in node.childNodes) {
        SCNNode *found = [self findNodeNamed:needle inNode:child];
        if (found != nil) {
            return found;
        }
    }

    return nil;
}

- (NSString *)parentChainForNode:(SCNNode *)node {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    SCNNode *cursor = node;
    while (cursor != nil) {
        [parts addObject:cursor.name ?: @"<unnamed>"];
        cursor = cursor.parentNode;
    }
    return [[parts reverseObjectEnumerator].allObjects componentsJoinedByString:@" -> "];
}

- (void)vroidApplyFloatAnimationToNode:(SCNNode *)node {
    if (!node) return;

    CGFloat amplitude = 0.308;
    CGFloat duration = 3.2;

    NSString *amplitudeEnv = [[[NSProcessInfo processInfo] environment] objectForKey:@"VROID_FLOAT_AMPLITUDE"];
    NSString *durationEnv = [[[NSProcessInfo processInfo] environment] objectForKey:@"VROID_FLOAT_DURATION"];

    if (amplitudeEnv.length > 0) {
        amplitude = (CGFloat)[amplitudeEnv doubleValue];
    }

    if (durationEnv.length > 0) {
        duration = MAX(0.2, (CGFloat)[durationEnv doubleValue]);
    }

    [node removeActionForKey:@"vroidFloat"];

    SCNAction *up = [SCNAction moveByX:0.0 y:amplitude z:0.0 duration:duration * 0.5];
    up.timingMode = SCNActionTimingModeEaseInEaseOut;
    SCNAction *down = [SCNAction moveByX:0.0 y:-amplitude z:0.0 duration:duration * 0.5];
    down.timingMode = SCNActionTimingModeEaseInEaseOut;
    SCNAction *loop = [SCNAction repeatActionForever:[SCNAction sequence:@[up, down]]];
    [node runAction:loop forKey:@"vroidFloat"];

    NSLog(@"[FLOAT] applied amplitude=%.4f duration=%.3f node=%@", amplitude, duration, node.name ?: @"<unnamed>");
}

- (NSArray<NSDictionary *> *)vroidCollectBlinkTargetsInNode:(SCNNode *)node targetName:(NSString *)targetName {
    if (!node) return @[];

    NSMutableArray<NSDictionary *> *matches = [NSMutableArray array];
    [self vroidCollectBlinkTargetsInNode:node targetName:targetName results:matches];
    NSLog(@"[BLINK] collected %lu morph targets for %@", (unsigned long)matches.count, targetName);
    for (NSDictionary *match in matches) {
        NSLog(@"[BLINK] candidate node=%@ index=%@ target=%@",
              match[@"nodeName"] ?: @"<unnamed>",
              match[@"index"] ?: @"<nil>",
              match[@"targetName"] ?: @"<nil>");
    }
    return matches;
}

- (NSArray<NSDictionary *> *)vroidCollectSpeechTargetsInNode:(SCNNode *)node {
    if (!node) return @[];

    NSSet<NSString *> *mouthNames = [NSSet setWithArray:@[
        @"Fcl_MTH_A",
        @"Fcl_MTH_I",
        @"Fcl_MTH_U",
        @"Fcl_MTH_E",
        @"Fcl_MTH_O",
        @"Fcl_MTH_Surprised",
        @"Fcl_MTH_Sorrow",
        @"Fcl_MTH_Joy"
    ]];

    NSMutableArray<NSDictionary *> *matches = [NSMutableArray array];
    [self vroidCollectSpeechTargetsInNode:node mouthNames:mouthNames results:matches];
    NSLog(@"[SPEECH] collected %lu mouth target(s)", (unsigned long)matches.count);
    for (NSDictionary *match in matches) {
        NSLog(@"[SPEECH] candidate node=%@ index=%@ target=%@",
              match[@"nodeName"] ?: @"<unnamed>",
              match[@"index"] ?: @"<nil>",
              match[@"targetName"] ?: @"<nil>");
    }
    return matches;
}

- (void)vroidCollectSpeechTargetsInNode:(SCNNode *)node
                              mouthNames:(NSSet<NSString *> *)mouthNames
                                 results:(NSMutableArray<NSDictionary *> *)matches {
    if (!node || !matches || mouthNames.count == 0) return;

    if (node.morpher != nil && node.morpher.targets.count > 0) {
        NSInteger index = 0;
        for (SCNGeometry *targetGeometry in node.morpher.targets) {
            NSString *candidateName = targetGeometry.name ?: @"";
            if ([mouthNames containsObject:candidateName]) {
                if (_speechNode == nil) {
                    _speechNode = node;
                }
                [matches addObject:@{
                    @"node": node,
                    @"nodeName": node.name ?: @"<unnamed>",
                    @"index": @(index),
                    @"targetName": candidateName
                }];
            }
            index++;
        }
    }

    for (SCNNode *child in node.childNodes) {
        [self vroidCollectSpeechTargetsInNode:child mouthNames:mouthNames results:matches];
    }
}

- (void)vroidCollectBlinkTargetsInNode:(SCNNode *)node targetName:(NSString *)targetName results:(NSMutableArray<NSDictionary *> *)matches {
    if (!node || !matches || targetName.length == 0) return;

    if (node.morpher != nil && node.morpher.targets.count > 0) {
        NSInteger index = 0;
        for (SCNGeometry *targetGeometry in node.morpher.targets) {
            NSString *candidateName = targetGeometry.name ?: @"";
            if ([candidateName caseInsensitiveCompare:targetName] == NSOrderedSame) {
                [matches addObject:@{
                    @"node": node,
                    @"nodeName": node.name ?: @"<unnamed>",
                    @"index": @(index),
                    @"targetName": candidateName
                }];
            }
            index++;
        }
    }

    for (SCNNode *child in node.childNodes) {
        [self vroidCollectBlinkTargetsInNode:child targetName:targetName results:matches];
    }
}

- (void)vroidStartRandomBlinkLoop {
    _blinkToken += 1;
    NSUInteger token = _blinkToken;
    [self vroidScheduleNextBlinkWithToken:token];
}

- (void)vroidScheduleNextBlinkWithToken:(NSUInteger)token {
    CGFloat wait = 1.25 + ((CGFloat)arc4random_uniform(376) / 100.0);
    wait = MIN(wait, 5.0);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (token != self->_blinkToken) {
            return;
        }

        [self vroidTriggerBlink];
        [self vroidScheduleNextBlinkWithToken:token];
    });
}

- (void)vroidTriggerBlink {
    if (_blinkTargets.count == 0) {
        NSLog(@"[BLINK] no morph target named Fcl_EYE_Joy found; blink skipped");
        return;
    }

    for (NSDictionary *targetInfo in _blinkTargets) {
        SCNNode *node = targetInfo[@"node"];
        NSNumber *indexNumber = targetInfo[@"index"];
        if (!node || indexNumber == nil || node.morpher == nil) {
            continue;
        }

        NSInteger index = indexNumber.integerValue;
        [node removeActionForKey:@"vroidBlink"];
        [node.morpher setWeight:0.0 forTargetAtIndex:index];

        SCNAction *blink = [SCNAction customActionWithDuration:0.18 actionBlock:^(SCNNode *target, CGFloat elapsedTime) {
            CGFloat progress = MIN(MAX(elapsedTime / 0.18, 0.0), 1.0);
            CGFloat weight;
            if (progress < 0.35) {
                CGFloat local = progress / 0.35;
                weight = local;
            } else {
                CGFloat local = (progress - 0.35) / 0.65;
                weight = 1.0 - local;
            }
            weight = MAX(0.0, MIN(1.0, weight));
            [target.morpher setWeight:weight forTargetAtIndex:index];
        }];

        SCNAction *finish = [SCNAction runBlock:^(SCNNode *target) {
            [target.morpher setWeight:0.0 forTargetAtIndex:index];
        }];

        [node runAction:[SCNAction sequence:@[blink, finish]] forKey:@"vroidBlink"];
    }

    NSLog(@"[BLINK] triggered on %lu morph target(s)", (unsigned long)_blinkTargets.count);
}

- (NSString *)vroidSpeechVisemeForCharacter:(unichar)ch {
    switch (ch) {
        case 'a': return @"Fcl_MTH_A";
        case 'e': return @"Fcl_MTH_E";
        case 'i': return @"Fcl_MTH_I";
        case 'o': return @"Fcl_MTH_O";
        case 'u': return @"Fcl_MTH_U";
        default:
            break;
    }

    if (strchr("mbp", ch) != NULL) {
        return @"Fcl_MTH_Sorrow";
    }

    if (strchr("fvszxjlrntdgkqhcwy", ch) != NULL) {
        return @"Fcl_MTH_I";
    }

    return nil;
}

- (BOOL)vroidSpeechIsVowel:(unichar)ch {
    return strchr("aeiou", ch) != NULL;
}

- (BOOL)vroidSpeechIsSoftConsonant:(unichar)ch {
    return strchr("fvszxjlrntdgkqhcwy", ch) != NULL;
}

- (NSString *)vroidSpeechVisemeForSyllable:(NSString *)syllable {
    if (syllable.length == 0) {
        return nil;
    }

    NSString *lower = [syllable lowercaseString];

    if ([lower rangeOfString:@"surprised"].location != NSNotFound) {
        return @"Fcl_MTH_Surprised";
    }

    if ([lower rangeOfString:@"joy"].location != NSNotFound) {
        return @"Fcl_MTH_Joy";
    }

    if ([lower rangeOfString:@"sorrow"].location != NSNotFound) {
        return @"Fcl_MTH_Sorrow";
    }

    if ([lower rangeOfString:@"qu"].location != NSNotFound ||
        [lower rangeOfString:@"qui"].location != NSNotFound ||
        [lower rangeOfString:@"que"].location != NSNotFound) {
        return @"Fcl_MTH_E";
    }

    if ([lower rangeOfString:@"gu"].location != NSNotFound ||
        [lower rangeOfString:@"gui"].location != NSNotFound ||
        [lower rangeOfString:@"gue"].location != NSNotFound) {
        return @"Fcl_MTH_U";
    }

    if ([lower rangeOfString:@"ch"].location != NSNotFound ||
        [lower rangeOfString:@"ll"].location != NSNotFound ||
        [lower rangeOfString:@"rr"].location != NSNotFound) {
        return @"Fcl_MTH_I";
    }

    for (NSUInteger i = 0; i < lower.length; i++) {
        unichar ch = [lower characterAtIndex:i];
        if ([self vroidSpeechIsVowel:ch]) {
            switch (ch) {
                case 'a': return @"Fcl_MTH_A";
                case 'e': return @"Fcl_MTH_E";
                case 'i': return @"Fcl_MTH_I";
                case 'o': return @"Fcl_MTH_O";
                case 'u': return @"Fcl_MTH_U";
                default: break;
            }
        }
    }

    for (NSUInteger i = 0; i < lower.length; i++) {
        unichar ch = [lower characterAtIndex:i];
        if ([self vroidSpeechIsSoftConsonant:ch]) {
            return @"Fcl_MTH_Sorrow";
        }
    }

    return nil;
}

- (NSTimeInterval)vroidSpeechDurationForCharacter:(unichar)ch {
    if (ch == ' ' || ch == '\n' || ch == '\t') {
        return 0.05;
    }

    if (ch == '.' || ch == ',' || ch == ';' || ch == ':') {
        return 0.16;
    }

    if (ch == '!' || ch == '?') {
        return 0.22;
    }

    if (strchr("aeiouáéíóú", ch) != NULL) {
        return 0.14;
    }

    return 0.08;
}

- (NSArray<NSString *> *)vroidSpeechSyllablesForWord:(NSString *)word {
    if (word.length == 0) {
        return @[];
    }

    NSMutableArray<NSString *> *syllables = [NSMutableArray array];
    NSMutableString *current = [NSMutableString string];
    NSString *lower = [word lowercaseString];

    for (NSUInteger i = 0; i < lower.length; i++) {
        unichar ch = [lower characterAtIndex:i];
        [current appendFormat:@"%C", ch];

        BOOL isVowel = [self vroidSpeechIsVowel:ch];
        BOOL isLast = (i + 1 == lower.length);

        if (isVowel) {
            if (i + 1 < lower.length) {
                unichar next = [lower characterAtIndex:i + 1];
                if (next == 'u' || next == 'i') {
                    [current appendFormat:@"%C", next];
                    i++;
                }
            }

            if (isLast) {
                [syllables addObject:[current copy]];
                [current setString:@""];
                continue;
            }

            if (i + 1 < lower.length) {
                unichar next = [lower characterAtIndex:i + 1];
                BOOL nextIsVowel = [self vroidSpeechIsVowel:next];
                if (!nextIsVowel) {
                    NSInteger lookahead = (NSInteger)i + 2;
                    BOOL nextNextIsVowel = NO;
                    if (lookahead < (NSInteger)lower.length) {
                        nextNextIsVowel = [self vroidSpeechIsVowel:[lower characterAtIndex:(NSUInteger)lookahead]];
                    }
                    if (nextNextIsVowel || lookahead >= (NSInteger)lower.length) {
                        [syllables addObject:[current copy]];
                        [current setString:@""];
                    }
                } else {
                    [syllables addObject:[current copy]];
                    [current setString:@""];
                }
            }
        }
    }

    if (current.length > 0) {
        [syllables addObject:[current copy]];
    }

    if (syllables.count == 0) {
        [syllables addObject:lower];
    }

    return syllables;
}

- (CGFloat)vroidSpeechPeakWeightForViseme:(NSString *)viseme character:(unichar)ch {
    if ([viseme isEqualToString:@"Fcl_MTH_Surprised"]) {
        return 0.45;
    }

    if ([viseme isEqualToString:@"Fcl_MTH_Sorrow"]) {
        return 0.65;
    }

    if (ch == '!' || ch == '?') {
        return 0.6;
    }

    return 1.0;
}

- (void)vroidApplySpeechViseme:(NSString *)viseme weight:(CGFloat)weight {
    if (_speechTargets.count == 0) {
        return;
    }

    NSString *resolvedViseme = viseme ?: @"";
    CGFloat clampedWeight = MAX(0.0, MIN(1.0, weight));

    for (NSDictionary *targetInfo in _speechTargets) {
        SCNNode *node = targetInfo[@"node"];
        NSNumber *indexNumber = targetInfo[@"index"];
        NSString *targetName = targetInfo[@"targetName"];
        if (!node || !indexNumber || node.morpher == nil) {
            continue;
        }

        NSInteger index = indexNumber.integerValue;
        CGFloat targetWeight = 0.0;

        if ([targetName isEqualToString:resolvedViseme]) {
            targetWeight = clampedWeight;
        } else if ([resolvedViseme isEqualToString:@"Fcl_MTH_A"] &&
                   [targetName isEqualToString:@"Fcl_MTH_Surprised"]) {
            targetWeight = clampedWeight * 0.16;
        } else if ([resolvedViseme isEqualToString:@"Fcl_MTH_O"] &&
                   [targetName isEqualToString:@"Fcl_MTH_Surprised"]) {
            targetWeight = clampedWeight * 0.10;
        } else if ([resolvedViseme isEqualToString:@"Fcl_MTH_Sorrow"] &&
                   [targetName isEqualToString:@"Fcl_MTH_I"]) {
            targetWeight = clampedWeight * 0.10;
        } else {
            targetWeight = 0.0;
        }

        [node.morpher setWeight:targetWeight forTargetAtIndex:index];
    }
}

- (NSArray<SCNAction *> *)vroidSpeechActionsForText:(NSString *)text {
    if (text.length == 0) return @[];

    NSMutableArray<SCNAction *> *actions = [NSMutableArray array];
    NSString *normalized = [[text lowercaseString] stringByFoldingWithOptions:NSDiacriticInsensitiveSearch locale:[NSLocale currentLocale]];

    NSArray<NSString *> *words = [normalized componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSCharacterSet *punctuation = [NSCharacterSet characterSetWithCharactersInString:@".,;:!?"];

    for (NSString *word in words) {
        if (word.length == 0) {
            [actions addObject:[SCNAction waitForDuration:0.03]];
            continue;
        }

        NSMutableString *cleanWord = [NSMutableString string];
        NSMutableArray<NSString *> *trailers = [NSMutableArray array];

        for (NSUInteger i = 0; i < word.length; i++) {
            unichar ch = [word characterAtIndex:i];
            if ([punctuation characterIsMember:ch]) {
                [trailers addObject:[NSString stringWithFormat:@"%C", ch]];
            } else {
                [cleanWord appendFormat:@"%C", ch];
            }
        }

        NSArray<NSString *> *syllables = [self vroidSpeechSyllablesForWord:cleanWord];
        for (NSString *syllable in syllables) {
            NSString *viseme = [self vroidSpeechVisemeForSyllable:syllable];
            NSTimeInterval duration = MAX(0.08, 0.08 + (0.03 * syllable.length));
            CGFloat peakWeight = [self vroidSpeechPeakWeightForViseme:viseme character:'a'];
            BOOL hasStrongConsonant = NO;

            for (NSUInteger i = 0; i < syllable.length; i++) {
                unichar ch = [syllable characterAtIndex:i];
                if (![self vroidSpeechIsVowel:ch] && [self vroidSpeechIsSoftConsonant:ch]) {
                    hasStrongConsonant = YES;
                    break;
                }
            }

            if (hasStrongConsonant && [viseme isEqualToString:@"Fcl_MTH_A"]) {
                peakWeight = 0.82;
            }

            if (viseme == nil) {
                viseme = @"Fcl_MTH_Sorrow";
                peakWeight = 0.38;
            }

            __block NSString *capturedViseme = [viseme copy];
            __block CGFloat capturedPeakWeight = peakWeight;
            __block NSTimeInterval capturedDuration = duration;

            SCNAction *frame = [SCNAction customActionWithDuration:capturedDuration actionBlock:^(SCNNode *target, CGFloat elapsedTime) {
                CGFloat t = MIN(MAX(elapsedTime / capturedDuration, 0.0), 1.0);
                CGFloat envelope = (t < 0.5) ? (t / 0.5) : ((1.0 - t) / 0.5);
                envelope = MAX(0.0, MIN(1.0, envelope));
                CGFloat shaped = pow(envelope, 0.9) * capturedPeakWeight;
                [self vroidApplySpeechViseme:capturedViseme weight:shaped];
            }];
            [actions addObject:frame];

            if (syllable.length > 1) {
                [actions addObject:[SCNAction waitForDuration:0.025]];
            }
        }

        for (NSString *trailer in trailers) {
            unichar ch = [trailer characterAtIndex:0];
            NSTimeInterval pause = [self vroidSpeechDurationForCharacter:ch];
            [actions addObject:[SCNAction waitForDuration:pause]];
            if (ch == '!' || ch == '?') {
                [actions addObject:[SCNAction customActionWithDuration:0.16 actionBlock:^(SCNNode *target, CGFloat elapsedTime) {
                    CGFloat t = MIN(MAX(elapsedTime / 0.16, 0.0), 1.0);
                    CGFloat weight = t < 0.5 ? (t / 0.5) : ((1.0 - t) / 0.5);
                    [self vroidApplySpeechViseme:@"Fcl_MTH_Surprised" weight:[self vroidSpeechPeakWeightForViseme:@"Fcl_MTH_Surprised" character:ch] * weight];
                }]];
            }
        }

        [actions addObject:[SCNAction waitForDuration:0.02]];
    }

    return actions;
}

- (void)vroidSpeakText:(NSString *)text {
    if (text.length == 0) {
        return;
    }

    if (_speechNode == nil || _speechTargets.count == 0) {
        NSLog(@"[SPEECH] no mouth morph targets found; cannot speak text");
        return;
    }

    [self vroidStopSpeaking];
    [self vroidShowSpeechBubbleWithText:text];
    _speechToken += 1;
    NSUInteger token = _speechToken;
    NSLog(@"[SPEECH] speak text=%@", text);
    [self vroidAppendSpeechTraceLine:[NSString stringWithFormat:@"{\"ts\":%.0f,\"stage\":\"speak_text\",\"text\":%@}",
                                      [[NSDate date] timeIntervalSince1970],
                                      [self vroidJSONStringFromObject:text]]];
    [self vroidSpeakOutLoudText:text];
    NSArray<SCNAction *> *actions = [self vroidSpeechActionsForText:text];

    if (actions.count == 0) {
        return;
    }

    [_speechNode removeActionForKey:@"vroidSpeech"];

    __weak typeof(self) weakSelf = self;
    SCNAction *sequence = [SCNAction sequence:actions];
    [_speechNode runAction:sequence completionHandler:^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || token != strongSelf->_speechToken) {
            return;
        }
        [strongSelf vroidApplySpeechViseme:nil weight:0.0];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            typeof(self) delayedSelf = weakSelf;
            if (!delayedSelf || token != delayedSelf->_speechToken) {
                return;
            }
            [delayedSelf vroidHideSpeechBubble];
        });
        NSLog(@"[SPEECH] finished text playback");
    }];

    NSLog(@"[SPEECH] started text playback: %@", text);
}

- (void)vroidStopSpeaking {
    if (_ttsRequestTask != nil) {
        [_ttsRequestTask cancel];
        _ttsRequestTask = nil;
    }

    if (_speechTask != nil) {
        @try {
            if (_speechTask.isRunning) {
                [_speechTask terminate];
            }
        } @catch (__unused NSException *exception) {
        }
        _speechTask = nil;
    }
}

- (NSString *)vroidSpeechVoiceName {
    if (_speechVoiceName.length > 0) {
        return _speechVoiceName;
    }

    NSString *override = [[[NSProcessInfo processInfo] environment] objectForKey:@"VROID_SPEECH_VOICE"];
    if (override.length > 0) {
        _speechVoiceName = [override copy];
    } else {
        _speechVoiceName = @"Amy";
    }
    return _speechVoiceName;
}

- (NSString *)vroidTTSProvider {
    NSString *override = [[[NSProcessInfo processInfo] environment] objectForKey:@"VROID_TTS_PROVIDER"];
    if (override.length > 0) {
        return override.lowercaseString;
    }
    return @"kokoro";
}

- (NSURL *)vroidKokoroSpeechURL {
    NSString *override = [[[NSProcessInfo processInfo] environment] objectForKey:@"VROID_KOKORO_URL"];
    if (override.length > 0) {
        return [NSURL URLWithString:override];
    }
    return [NSURL URLWithString:@"http://127.0.0.1:8880/v1/audio/speech"];
}

- (NSString *)vroidKokoroVoiceName {
    NSString *override = [[[NSProcessInfo processInfo] environment] objectForKey:@"VROID_KOKORO_VOICE"];
    if (override.length > 0) {
        return override;
    }
    return @"af_bella";
}

- (NSString *)vroidSpeechIndicatorText {
    NSString *provider = [self vroidTTSProvider];
    if ([provider isEqualToString:@"kokoro"]) {
        return [NSString stringWithFormat:@"speech: Kokoro / %@", [self vroidKokoroVoiceName]];
    }

    return [NSString stringWithFormat:@"speech: macOS say / %@", [self vroidSpeechVoiceName]];
}

- (void)vroidPlayAudioAtURL:(NSURL *)url {
    if (url == nil || url.path.length == 0) {
        return;
    }

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/afplay";
    task.arguments = @[url.path];
    __weak typeof(self) weakSelf = self;
    task.terminationHandler = ^(__unused NSTask *finishedTask) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }

        NSError *removeError = nil;
        [[NSFileManager defaultManager] removeItemAtURL:url error:&removeError];
        if (removeError != nil) {
            NSLog(@"[VOICE] could not remove temp audio file: %@", removeError);
        }
        NSLog(@"[VOICE] finished Kokoro playback");
    };

    @try {
        [task launch];
        _speechTask = task;
    } @catch (NSException *exception) {
        NSLog(@"[VOICE] failed to launch afplay: %@", exception);
    }
}

- (void)vroidSpeakWithSayText:(NSString *)text voice:(NSString *)voiceName {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        return;
    }

    NSString *voice = voiceName.length > 0 ? voiceName : [self vroidSpeechVoiceName];
    NSLog(@"[VOICE] speaking with voice=%@ text=%@", voice, trimmed);
    [self vroidAppendSpeechTraceLine:[NSString stringWithFormat:@"{\"ts\":%.0f,\"stage\":\"say\",\"voice\":%@,\"text\":%@}",
                                      [[NSDate date] timeIntervalSince1970],
                                      [self vroidJSONStringFromObject:voice],
                                      [self vroidJSONStringFromObject:trimmed]]];

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/say";
    task.arguments = @[@"-v", voice, trimmed];
    task.terminationHandler = ^(__unused NSTask *finishedTask) {
        NSLog(@"[VOICE] finished voice=%@", voice);
    };

    @try {
        [task launch];
        _speechTask = task;
    } @catch (NSException *exception) {
        NSLog(@"[VOICE] failed to launch say: %@", exception);
    }
}

- (void)vroidSpeakOutLoudTextWithFallback:(NSString *)text fallbackVoice:(NSString *)fallbackVoice {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        return;
    }

    NSString *provider = [self vroidTTSProvider];
    NSString *selectedVoice = [provider isEqualToString:@"kokoro"] ? [self vroidKokoroVoiceName] : [self vroidSpeechVoiceName];
    NSLog(@"[VOICE] payload provider=%@ voice=%@ text=%@", provider, selectedVoice, trimmed);
    [self vroidAppendSpeechTraceLine:[NSString stringWithFormat:@"{\"ts\":%.0f,\"stage\":\"payload\",\"provider\":%@,\"voice\":%@,\"text\":%@}",
                                      [[NSDate date] timeIntervalSince1970],
                                      [self vroidJSONStringFromObject:provider],
                                      [self vroidJSONStringFromObject:selectedVoice],
                                      [self vroidJSONStringFromObject:trimmed]]];

    if ([provider isEqualToString:@"kokoro"]) {
        NSURL *url = [self vroidKokoroSpeechURL];
        if (url != nil) {
            NSDictionary *payload = @{
                @"model": @"kokoro",
                @"voice": [self vroidKokoroVoiceName],
                @"input": trimmed,
                @"response_format": @"mp3",
                @"speed": @1.0
            };

            NSError *jsonError = nil;
            NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&jsonError];
            if (body.length > 0 && jsonError == nil) {
                NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
                request.HTTPMethod = @"POST";
                request.HTTPBody = body;
                [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

                __weak typeof(self) weakSelf = self;
                NSUInteger token = _speechToken;
                _ttsRequestTask = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        typeof(self) strongSelf = weakSelf;
                        if (!strongSelf) {
                            return;
                        }
                        if (strongSelf->_speechToken != token) {
                            strongSelf->_ttsRequestTask = nil;
                            return;
                        }
                        strongSelf->_ttsRequestTask = nil;
                        if (error != nil || data.length == 0) {
                            NSLog(@"[VOICE] Kokoro request failed, falling back to say: %@", error);
                            [strongSelf vroidSpeakWithSayText:text voice:fallbackVoice];
                            return;
                        }

                        NSString *fileName = [NSString stringWithFormat:@"vroid-kokoro-%@.mp3", [[NSUUID UUID] UUIDString]];
                        NSURL *outputURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:fileName]];
                        NSError *writeError = nil;
                        if (![data writeToURL:outputURL options:NSDataWritingAtomic error:&writeError] || writeError != nil) {
                            NSLog(@"[VOICE] failed to write Kokoro audio: %@", writeError);
                            [strongSelf vroidSpeakWithSayText:text voice:fallbackVoice];
                            return;
                        }

                        [strongSelf vroidPlayAudioAtURL:outputURL];
                    });
                }];
                [_ttsRequestTask resume];
                return;
            }
        }
        NSLog(@"[VOICE] could not prepare Kokoro request, falling back to say");
    }

    [self vroidSpeakWithSayText:text voice:fallbackVoice];
}

- (void)vroidSpeakOutLoudText:(NSString *)text {
    [self vroidSpeakOutLoudTextWithFallback:text fallbackVoice:nil];
}

- (void)vroidSetPendingSpeechText:(NSString *)text {
    _pendingSpeechText = [text copy];
}

- (void)vroidHandleAICommandJSON:(NSString *)jsonString {
    if (jsonString.length == 0) {
        return;
    }

    [self vroidDebugLogEvent:nil rawLine:jsonString action:@"read_raw_line" result:@"received"];

    NSData *data = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
    if (data == nil) {
        NSLog(@"[AI] invalid JSON command encoding");
        [self vroidDebugLogEvent:nil rawLine:jsonString action:@"json_parse" result:@"invalid_utf8"];
        return;
    }

    NSError *error = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![object isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[AI] invalid command JSON: %@", error);
        [self vroidDebugLogEvent:nil rawLine:jsonString action:@"json_parse" result:error.localizedDescription ?: @"invalid_json"];
        if (jsonString.length > 0) {
            [self vroidHandlePlainTextResponse:jsonString source:@"json_fallback"];
        }
        return;
    }

    [self vroidDebugLogEvent:(NSDictionary *)object rawLine:jsonString action:@"json_parse" result:@"ok"];
    [self vroidHandleAICommandDictionary:(NSDictionary *)object];
}

- (void)vroidHandleAICommandDictionary:(NSDictionary *)command {
    if (command.count == 0) {
        return;
    }

    _pendingAICommand = [command copy];
    NSLog(@"[AI] received command: %@", command);
    [self vroidDebugLogEvent:command rawLine:nil action:@"dispatch" result:@"received"];

    NSString *type = [command[@"type"] isKindOfClass:[NSString class]] ? command[@"type"] : nil;
    NSString *say = [command[@"say"] isKindOfClass:[NSString class]] ? command[@"say"] : nil;
    NSString *emotion = [command[@"emotion"] isKindOfClass:[NSString class]] ? command[@"emotion"] : nil;
    NSNumber *bubble = [command[@"bubble"] isKindOfClass:[NSNumber class]] ? command[@"bubble"] : nil;
    NSString *text = [command[@"text"] isKindOfClass:[NSString class]] ? command[@"text"] : nil;
    NSString *eventID = [command[@"id"] isKindOfClass:[NSString class]] ? command[@"id"] : nil;

    if ([type isEqualToString:@"speech_delta"]) {
        type = @"text_delta";
    }

    if ([type isEqualToString:@"emotion_hint"] && emotion.length > 0) {
        [self vroidApplyAIEmotion:emotion];
        [self vroidDebugLogEvent:command rawLine:nil action:@"apply_emotion" result:emotion];
        return;
    }

    if ([type isEqualToString:@"bubble_show"]) {
        [self vroidShowSpeechBubbleWithText:text ?: say ?: @""];
        [self vroidDebugLogEvent:command rawLine:nil action:@"bubble_show" result:text ?: say ?: @""];
        return;
    }

    if ([type isEqualToString:@"bubble_hide"]) {
        [self vroidHideSpeechBubble];
        [self vroidDebugLogEvent:command rawLine:nil action:@"bubble_hide" result:@"ok"];
        return;
    }

    if ([type isEqualToString:@"speech_start"]) {
        _pendingSpeechEventID = [eventID copy];
        _pendingSpeechText = text.length > 0 ? [text copy] : (say.length > 0 ? [say copy] : nil);
        if (bubble == nil || bubble.boolValue) {
            [self vroidShowSpeechBubbleWithText:text ?: say ?: @""];
        }
        [self vroidDebugLogEvent:command rawLine:nil action:@"speech_start" result:text ?: say ?: @""];
        return;
    }

    if ([type isEqualToString:@"speech_end"]) {
        _pendingSpeechEventID = nil;
        if (_pendingSpeechText.length > 0) {
            [self vroidDebugLogEvent:command rawLine:nil action:@"speech_end_start_pending_speech" result:_pendingSpeechText];
            [self vroidStartPendingSpeechIfNeeded];
        } else {
            [self vroidHideSpeechBubble];
        }
        [self vroidDebugLogEvent:command rawLine:nil action:@"speech_end" result:@"ok"];
        return;
    }

    if (emotion.length > 0) {
        [self vroidApplyAIEmotion:emotion];
    }

    if ([type isEqualToString:@"text_delta"] && text.length > 0) {
        BOOL sameEvent = (_pendingSpeechEventID.length > 0 &&
                          eventID.length > 0 &&
                          [_pendingSpeechEventID isEqualToString:eventID]);
        if (sameEvent && _pendingSpeechText.length > 0) {
            if ([text isEqualToString:_pendingSpeechText] || [text hasPrefix:_pendingSpeechText]) {
                _pendingSpeechText = [text copy];
            } else {
                _pendingSpeechText = [_pendingSpeechText stringByAppendingString:text];
            }
        } else {
            _pendingSpeechEventID = [eventID copy];
            _pendingSpeechText = [text copy];
        }
        [self vroidShowSpeechBubbleWithText:_pendingSpeechText];
        [self vroidDebugLogEvent:command rawLine:nil action:@"text_delta" result:_pendingSpeechText];
        return;
    }

    if (say.length > 0) {
        [self vroidSpeakText:say];
        [self vroidDebugLogEvent:command rawLine:nil action:@"speech_fallback" result:say];
    }
}

- (void)vroidHandlePlainTextResponse:(NSString *)text source:(NSString *)source {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        return;
    }

    NSLog(@"[AI] plain text response (%@): %@", source ?: @"unknown", trimmed);
    [self vroidDebugLogMessage:@"plain_text_response" fields:@{@"source": source ?: @"unknown", @"text": trimmed}];
    _pendingSpeechText = [trimmed copy];
    [self vroidShowSpeechBubbleWithText:_pendingSpeechText];
    [self vroidSpeakText:_pendingSpeechText];
}

- (NSString *)vroidDefaultEventStreamPath {
    NSString *override = [[[NSProcessInfo processInfo] environment] objectForKey:@"VROID_EVENT_STREAM_PATH"];
    if (override.length > 0) {
        return [override stringByStandardizingPath];
    }

    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *base = paths.firstObject ?: NSTemporaryDirectory();
    NSString *dir = [base stringByAppendingPathComponent:@"VroidOverlay"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"openclaw_stream.jsonl"];
}

- (void)vroidStartEventStreamMonitoring {
    if (_eventStreamPollTimer != nil) {
        return;
    }

    _eventStreamPath = [self vroidDefaultEventStreamPath];
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:_eventStreamPath error:nil];
    NSNumber *fileSize = attributes[NSFileSize];
    _eventStreamOffset = fileSize != nil ? fileSize.unsignedLongLongValue : 0;
    _eventStreamRemainder = @"";
    _eventStreamMissingLogged = NO;
    _eventStreamWaitingLogged = NO;
    _eventStreamActivityLogged = NO;
    NSLog(@"[AI] event stream path: %@", _eventStreamPath);
    NSLog(@"[AI] waiting for OpenClaw signal at: %@", _eventStreamPath);
    [self vroidDebugLogMessage:@"event_stream_start" fields:@{@"path": _eventStreamPath ?: @"", @"debug": @([self vroidDebugEnabled]), @"offset": @(_eventStreamOffset)}];
    [self vroidDebugLogMessage:@"openclaw_waiting" fields:@{@"path": _eventStreamPath ?: @""}];

    _eventStreamPollTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                             target:self
                                                           selector:@selector(vroidPollEventStream:)
                                                           userInfo:nil
                                                            repeats:YES];
    [self vroidPollEventStream:nil];
}

- (void)vroidStopEventStreamMonitoring {
    [_eventStreamPollTimer invalidate];
    _eventStreamPollTimer = nil;
    [self vroidDebugLogMessage:@"event_stream_stop" fields:@{@"path": _eventStreamPath ?: @""}];
}

- (BOOL)tuliMouseRepelEnabled {
    NSString *value = [[[NSProcessInfo processInfo] environment] objectForKey:@"TULI_MOUSE_REPEL"];
    if (!value) {
        return NO;
    }

    value = [value lowercaseString];
    return [value isEqualToString:@"1"] ||
           [value isEqualToString:@"true"] ||
           [value isEqualToString:@"yes"] ||
           [value isEqualToString:@"on"];
}

- (CGFloat)tuliEnvFloat:(NSString *)name defaultValue:(CGFloat)defaultValue {
    NSString *value = [[[NSProcessInfo processInfo] environment] objectForKey:name];
    if (value.length == 0) {
        return defaultValue;
    }
    return (CGFloat)[value doubleValue];
}

- (void)tuliStartMouseRepel {
    BOOL enabled = [self tuliMouseRepelEnabled];
    _mouseRepelEnabled = enabled;
    if (!enabled || self.window == nil) {
        return;
    }

    if (_mouseRepelTimer != nil) {
        return;
    }

    _mouseRepelVelocityX = 0.0;
    _mouseRepelVelocityY = 0.0;
    _mouseRepelTimer = [NSTimer scheduledTimerWithTimeInterval:(1.0 / 30.0)
                                                        target:self
                                                      selector:@selector(tuliTickMouseRepel:)
                                                      userInfo:nil
                                                       repeats:YES];
    NSLog(@"[TULI_REPEL] started");
    [self tuliTickMouseRepel:nil];
}

- (void)tuliStopMouseRepel {
    if (_mouseRepelTimer != nil) {
        [_mouseRepelTimer invalidate];
        _mouseRepelTimer = nil;
    }

    if (_mouseRepelEnabled) {
        NSLog(@"[TULI_REPEL] stopped");
    }

    _mouseRepelEnabled = NO;
    _mouseRepelVelocityX = 0.0;
    _mouseRepelVelocityY = 0.0;
}

- (NSPoint)tuliClampedWindowOrigin:(NSPoint)origin frameSize:(NSSize)frameSize {
    NSScreen *screen = self.window.screen ?: NSScreen.mainScreen;
    NSRect visible = screen.visibleFrame;
    CGFloat minX = NSMinX(visible);
    CGFloat minY = NSMinY(visible);
    CGFloat maxX = MAX(minX, NSMaxX(visible) - frameSize.width);
    CGFloat maxY = MAX(minY, NSMaxY(visible) - frameSize.height);

    origin.x = MAX(minX, MIN(origin.x, maxX));
    origin.y = MAX(minY, MIN(origin.y, maxY));
    return origin;
}

- (void)tuliTickMouseRepel:(NSTimer *)timer {
    if (self.window == nil) {
        [self tuliStopMouseRepel];
        return;
    }

    if (![self tuliMouseRepelEnabled]) {
        [self tuliStopMouseRepel];
        return;
    }

    if (_isDragging || _isRepositioning) {
        _mouseRepelVelocityX *= 0.5;
        _mouseRepelVelocityY *= 0.5;
        return;
    }

    CGFloat radius = [self tuliEnvFloat:@"TULI_MOUSE_REPEL_RADIUS" defaultValue:220.0];
    CGFloat strength = [self tuliEnvFloat:@"TULI_MOUSE_REPEL_STRENGTH" defaultValue:18.0];
    CGFloat damping = [self tuliEnvFloat:@"TULI_MOUSE_REPEL_DAMPING" defaultValue:0.78];
    CGFloat maxStep = [self tuliEnvFloat:@"TULI_MOUSE_REPEL_MAX_STEP" defaultValue:22.0];

    radius = MAX(8.0, radius);
    strength = MAX(0.0, strength);
    damping = MAX(0.0, MIN(damping, 1.0));
    maxStep = MAX(1.0, maxStep);

    NSPoint mouse = [NSEvent mouseLocation];
    NSRect frame = self.window.frame;
    NSPoint center = NSMakePoint(NSMidX(frame), NSMidY(frame));
    CGFloat dx = center.x - mouse.x;
    CGFloat dy = center.y - mouse.y;
    CGFloat distance = hypot(dx, dy);

    if (distance >= radius) {
        _mouseRepelVelocityX *= damping;
        _mouseRepelVelocityY *= damping;
        if (fabs(_mouseRepelVelocityX) < 0.01) _mouseRepelVelocityX = 0.0;
        if (fabs(_mouseRepelVelocityY) < 0.01) _mouseRepelVelocityY = 0.0;
        return;
    }

    if (distance < 0.001) {
        dx = 1.0;
        dy = 0.0;
        distance = 1.0;
    }

    CGFloat awayX = dx / distance;
    CGFloat awayY = dy / distance;
    CGFloat influence = 1.0 - (distance / radius);

    _mouseRepelVelocityX += awayX * strength * influence;
    _mouseRepelVelocityY += awayY * strength * influence;
    _mouseRepelVelocityX *= damping;
    _mouseRepelVelocityY *= damping;

    CGFloat stepX = MAX(-maxStep, MIN(_mouseRepelVelocityX, maxStep));
    CGFloat stepY = MAX(-maxStep, MIN(_mouseRepelVelocityY, maxStep));
    NSPoint nextOrigin = NSMakePoint(frame.origin.x + stepX, frame.origin.y + stepY);
    nextOrigin = [self tuliClampedWindowOrigin:nextOrigin frameSize:frame.size];

    if (NSEqualPoints(nextOrigin, frame.origin)) {
        _mouseRepelVelocityX *= 0.5;
        _mouseRepelVelocityY *= 0.5;
        return;
    }

    [self.window setFrameOrigin:nextOrigin];
    [self vroidSaveWindowFrame];
    [self vroidPositionSpeechBubble];
    NSLog(@"[TULI_REPEL] mouse=(%.1f, %.1f) center=(%.1f, %.1f) dist=%.1f step=(%.1f, %.1f) origin=(%.1f, %.1f)",
          mouse.x, mouse.y,
          center.x, center.y,
          distance,
          stepX, stepY,
          nextOrigin.x, nextOrigin.y);
}

- (void)vroidPollEventStream:(NSTimer *)timer {
    if (_eventStreamPath.length == 0) {
        return;
    }

    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:_eventStreamPath];
    if (!exists) {
        if (!_eventStreamMissingLogged) {
            _eventStreamMissingLogged = YES;
            [self vroidDebugLogMessage:@"event_stream_missing" fields:@{@"path": _eventStreamPath ?: @""}];
        }
        if (!_eventStreamWaitingLogged) {
            _eventStreamWaitingLogged = YES;
            NSLog(@"[AI] still waiting for OpenClaw to write: %@", _eventStreamPath);
            [self vroidDebugLogMessage:@"openclaw_still_waiting" fields:@{@"path": _eventStreamPath ?: @""}];
        }
        return;
    }

    if (_eventStreamMissingLogged) {
        _eventStreamMissingLogged = NO;
        [self vroidDebugLogMessage:@"event_stream_found" fields:@{@"path": _eventStreamPath ?: @""}];
    }

    NSData *data = [NSData dataWithContentsOfFile:_eventStreamPath options:NSDataReadingMappedIfSafe error:nil];
    if (data.length == 0) {
        [self vroidDebugLogMessage:@"event_stream_empty" fields:@{@"path": _eventStreamPath ?: @""}];
        if (!_eventStreamWaitingLogged) {
            _eventStreamWaitingLogged = YES;
            NSLog(@"[AI] OpenClaw stream exists but is still empty: %@", _eventStreamPath);
            [self vroidDebugLogMessage:@"openclaw_empty_waiting" fields:@{@"path": _eventStreamPath ?: @""}];
        }
        return;
    }

    if (_eventStreamOffset > data.length) {
        [self vroidDebugLogMessage:@"event_stream_truncated" fields:@{@"path": _eventStreamPath ?: @"", @"previous_offset": @(_eventStreamOffset), @"new_length": @(data.length)}];
        _eventStreamOffset = 0;
        _eventStreamRemainder = @"";
    }

    if (_eventStreamOffset == data.length) {
        return;
    }

    NSData *delta = [data subdataWithRange:NSMakeRange((NSUInteger)_eventStreamOffset, (NSUInteger)(data.length - _eventStreamOffset))];
    _eventStreamOffset = data.length;
    if (!_eventStreamActivityLogged) {
        _eventStreamActivityLogged = YES;
        _eventStreamWaitingLogged = NO;
        NSLog(@"[AI] OpenClaw signal received at: %@", _eventStreamPath);
        [self vroidDebugLogMessage:@"openclaw_signal_received" fields:@{@"path": _eventStreamPath ?: @"", @"bytes": @(delta.length)}];
    }

    NSString *chunk = [[NSString alloc] initWithData:delta encoding:NSUTF8StringEncoding];
    if (chunk.length == 0) {
        [self vroidDebugLogMessage:@"event_stream_decode_failed" fields:@{@"path": _eventStreamPath ?: @""}];
        return;
    }

    if (_eventStreamRemainder.length > 0) {
        chunk = [_eventStreamRemainder stringByAppendingString:chunk];
    }

    NSArray<NSString *> *rawLines = [chunk componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    BOOL chunkEndedWithNewline = [[chunk substringFromIndex:MAX((NSInteger)chunk.length - 1, 0)] isEqualToString:@"\n"];
    NSString *tail = @"";
    if (!chunkEndedWithNewline && rawLines.count > 0) {
        tail = rawLines.lastObject ?: @"";
        rawLines = [rawLines subarrayWithRange:NSMakeRange(0, rawLines.count - 1)];
    }

    _eventStreamRemainder = tail;

    for (NSString *line in rawLines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0) {
            continue;
        }

        [self vroidDebugLogEvent:nil rawLine:trimmed action:@"poll_line" result:@"read"];
        if ([trimmed hasPrefix:@"{"] || [trimmed hasPrefix:@"["]) {
            [self vroidHandleAICommandJSON:trimmed];
        } else {
            [self vroidHandlePlainTextResponse:trimmed source:@"raw_line"];
        }
    }
}

- (void)vroidApplyAIEmotion:(NSString *)emotion {
    if (emotion.length == 0) {
        return;
    }

    NSString *lower = [emotion lowercaseString];
    CGFloat joy = 0.0;
    CGFloat sorrow = 0.0;
    CGFloat surprise = 0.0;

    if ([lower isEqualToString:@"happy"] ||
        [lower isEqualToString:@"joy"] ||
        [lower isEqualToString:@"smile"]) {
        joy = 0.65;
    } else if ([lower isEqualToString:@"sad"] ||
               [lower isEqualToString:@"sorrow"] ||
               [lower isEqualToString:@"down"]) {
        sorrow = 0.55;
    } else if ([lower isEqualToString:@"surprised"] ||
               [lower isEqualToString:@"surprise"] ||
               [lower isEqualToString:@"wow"]) {
        surprise = 0.45;
    }

    [self vroidApplyEmotionWeightsWithJoy:joy sorrow:sorrow surprise:surprise];
    NSLog(@"[AI] emotion applied: %@ joy=%.2f sorrow=%.2f surprise=%.2f", emotion, joy, sorrow, surprise);
}

- (void)vroidApplyEmotionWeightsWithJoy:(CGFloat)joy sorrow:(CGFloat)sorrow surprise:(CGFloat)surprise {
    if (_speechTargets.count == 0) {
        return;
    }

    for (NSDictionary *targetInfo in _speechTargets) {
        SCNNode *node = targetInfo[@"node"];
        NSNumber *indexNumber = targetInfo[@"index"];
        NSString *targetName = targetInfo[@"targetName"];
        if (!node || !indexNumber || node.morpher == nil) {
            continue;
        }

        NSInteger index = indexNumber.integerValue;
        CGFloat weight = 0.0;
        if ([targetName isEqualToString:@"Fcl_MTH_Joy"]) {
            weight = joy;
        } else if ([targetName isEqualToString:@"Fcl_MTH_Sorrow"]) {
            weight = sorrow;
        } else if ([targetName isEqualToString:@"Fcl_MTH_Surprised"]) {
            weight = surprise;
        }

        [node.morpher setWeight:weight forTargetAtIndex:index];
    }
}

- (void)vroidStartPendingSpeechIfNeeded {
    if (_pendingSpeechText.length == 0) {
        return;
    }

    NSString *text = [_pendingSpeechText copy];
    _pendingSpeechText = nil;
    [self vroidSpeakText:text];
}

- (void)vroidEnsureSpeechBubbleWindow {
    if (_speechBubbleWindow != nil) {
        return;
    }

    NSRect frame = NSMakeRect(0, 0, 240, 72);
    NSPanel *window = [[NSPanel alloc]
        initWithContentRect:frame
        styleMask:NSWindowStyleMaskBorderless
        backing:NSBackingStoreBuffered
        defer:NO
    ];
    window.opaque = NO;
    window.backgroundColor = NSColor.clearColor;
    window.hasShadow = NO;
    window.level = NSStatusWindowLevel + 2;
    window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorFullScreenAuxiliary |
        NSWindowCollectionBehaviorIgnoresCycle;
    window.ignoresMouseEvents = YES;

    NSView *content = [[NSView alloc] initWithFrame:frame];
    content.wantsLayer = YES;
    content.layer.backgroundColor = [[NSColor colorWithCalibratedWhite:0.10 alpha:0.86] CGColor];
    content.layer.cornerRadius = 14.0;
    content.layer.borderWidth = 1.0;
    content.layer.borderColor = [[NSColor colorWithCalibratedWhite:1.0 alpha:0.14] CGColor];

    _speechBubbleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 16, VroidOverlaySpeechBubbleMinWidth - 32.0, VroidOverlaySpeechBubbleMinHeight - 32.0)];
    _speechBubbleLabel.bezeled = NO;
    _speechBubbleLabel.drawsBackground = NO;
    _speechBubbleLabel.editable = NO;
    _speechBubbleLabel.selectable = NO;
    _speechBubbleLabel.textColor = NSColor.whiteColor;
    _speechBubbleLabel.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    _speechBubbleLabel.alignment = NSTextAlignmentCenter;
    _speechBubbleLabel.lineBreakMode = NSLineBreakByWordWrapping;
    _speechBubbleLabel.maximumNumberOfLines = 0;
    _speechBubbleLabel.usesSingleLineMode = NO;
    _speechBubbleLabel.preferredMaxLayoutWidth = VroidOverlaySpeechBubbleMaxWidth - 32.0;

    [content addSubview:_speechBubbleLabel];
    window.contentView = content;
    _speechBubbleWindow = window;
}

- (void)vroidPositionSpeechBubble {
    if (_speechBubbleWindow == nil || self.window == nil) {
        return;
    }

    NSRect anchor = self.window.frame;
    CGFloat bubbleWidth = NSWidth(_speechBubbleWindow.frame);
    CGFloat bubbleHeight = NSHeight(_speechBubbleWindow.frame);
    CGFloat x = NSMinX(anchor) + (NSWidth(anchor) - bubbleWidth) * 0.5;
    CGFloat y = NSMaxY(anchor) - bubbleHeight - 8.0;

    NSScreen *screen = self.window.screen ?: NSScreen.mainScreen;
    NSRect visible = screen.visibleFrame;

    x = MAX(NSMinX(visible) + 8.0, MIN(x, NSMaxX(visible) - bubbleWidth - 8.0));
    y = MAX(NSMinY(visible) + 8.0, MIN(y, NSMaxY(visible) - bubbleHeight - 8.0));

    [_speechBubbleWindow setFrameOrigin:NSMakePoint(x, y)];
}

- (void)vroidShowSpeechBubbleWithText:(NSString *)text {
    if (text.length == 0) {
        return;
    }

    [self vroidEnsureSpeechBubbleWindow];
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.alignment = NSTextAlignmentCenter;
    style.lineBreakMode = NSLineBreakByWordWrapping;
    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: NSColor.whiteColor,
        NSParagraphStyleAttributeName: style,
    };
    NSAttributedString *attributed = [[NSAttributedString alloc] initWithString:text attributes:attributes];
    _speechBubbleLabel.attributedStringValue = attributed;

    CGSize maxSize = CGSizeMake(VroidOverlaySpeechBubbleMaxWidth - 32.0, CGFLOAT_MAX);
    CGRect bounds = [attributed boundingRectWithSize:maxSize options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading];
    CGFloat labelWidth = ceil(MIN(maxSize.width, MAX(VroidOverlaySpeechBubbleMinWidth - 32.0, bounds.size.width)));
    CGFloat labelHeight = ceil(MAX(24.0, bounds.size.height));
    if (labelHeight < VroidOverlaySpeechBubbleMinHeight - 32.0) {
        labelHeight = VroidOverlaySpeechBubbleMinHeight - 32.0;
    }

    _speechBubbleLabel.frame = NSMakeRect(16, 16, labelWidth, labelHeight);
    NSRect frame = NSMakeRect(0, 0, labelWidth + 32.0, labelHeight + 32.0);
    _speechBubbleWindow.contentView.frame = frame;
    _speechBubbleWindow.contentView.layer.cornerRadius = 14.0;
    [_speechBubbleWindow setFrame:frame display:NO];
    [self vroidPositionSpeechBubble];
    _speechBubbleLastShownAt = [[NSDate date] timeIntervalSince1970];
    _speechBubbleToken += 1;
    _speechBubbleWindow.alphaValue = 1.0;
    _speechBubbleWindow.opaque = NO;
    [NSApp activateIgnoringOtherApps:YES];
    [_speechBubbleWindow makeKeyAndOrderFront:nil];
    [_speechBubbleWindow orderFrontRegardless];
    [_speechBubbleLabel setNeedsDisplay:YES];
    [_speechBubbleWindow.contentView setNeedsDisplay:YES];
    [_speechBubbleWindow displayIfNeeded];
}

- (void)vroidHideSpeechBubble {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (_speechBubbleLastShownAt > 0.0 && (now - _speechBubbleLastShownAt) < VroidOverlaySpeechBubbleMinVisibleSeconds) {
        NSUInteger token = _speechBubbleToken;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VroidOverlaySpeechBubbleDismissDelaySeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (_speechBubbleWindow != nil && token == _speechBubbleToken) {
                [_speechBubbleWindow orderOut:nil];
            }
        });
        return;
    }
    [_speechBubbleWindow orderOut:nil];
}

- (NSRect)vroidChatInputFrame {
    if (self.window == nil) {
        return NSMakeRect(0, 0, 380, 140);
    }

    NSScreen *screen = self.window.screen ?: NSScreen.mainScreen;
    NSRect visible = screen.visibleFrame;
    CGFloat width = 380.0;
    CGFloat height = 140.0;
    CGFloat x = NSMinX(self.window.frame) + (NSWidth(self.window.frame) - width) * 0.5;
    CGFloat y = NSMaxY(self.window.frame) + 12.0;
    if (y + height > NSMaxY(visible) - 8.0) {
        y = NSMinY(self.window.frame) - height - 12.0;
    }
    x = MAX(NSMinX(visible) + 8.0, MIN(x, NSMaxX(visible) - width - 8.0));
    y = MAX(NSMinY(visible) + 8.0, MIN(y, NSMaxY(visible) - height - 8.0));
    return NSMakeRect(x, y, width, height);
}

- (void)vroidEnsureChatInputWindow {
    if (_chatInputWindow != nil) {
        return;
    }

    NSRect frame = [self vroidChatInputFrame];
    NSPanel *window = [[NSPanel alloc] initWithContentRect:frame
                                                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskFullSizeContentView
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    window.title = @"Habla con Tuli";
    window.titleVisibility = NSWindowTitleHidden;
    window.titlebarAppearsTransparent = YES;
    window.opaque = NO;
    window.backgroundColor = NSColor.clearColor;
    window.hasShadow = YES;
    window.level = NSStatusWindowLevel + 2;
    window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorFullScreenAuxiliary |
        NSWindowCollectionBehaviorIgnoresCycle;
    window.hidesOnDeactivate = NO;
    window.movableByWindowBackground = YES;

    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
    content.wantsLayer = YES;
    content.layer.backgroundColor = [[NSColor colorWithCalibratedWhite:0.11 alpha:0.92] CGColor];
    content.layer.cornerRadius = 16.0;
    content.layer.borderWidth = 1.0;
    content.layer.borderColor = [[NSColor colorWithCalibratedWhite:1.0 alpha:0.12] CGColor];

    NSTextField *title = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 104, 220, 18)];
    title.bezeled = NO;
    title.drawsBackground = NO;
    title.editable = NO;
    title.selectable = NO;
    title.textColor = NSColor.whiteColor;
    title.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    title.stringValue = @"Habla con Tuli";
    [content addSubview:title];

    _chatInputField = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 64, 348, 28)];
    _chatInputField.placeholderString = @"Escribe algo y pulsa Enter...";
    _chatInputField.bordered = YES;
    _chatInputField.bezeled = YES;
    _chatInputField.focusRingType = NSFocusRingTypeNone;
    _chatInputField.font = [NSFont systemFontOfSize:13 weight:NSFontWeightRegular];
    _chatInputField.target = self;
    _chatInputField.action = @selector(vroidSubmitChatInput:);
    [content addSubview:_chatInputField];

    _chatInputStatusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 38, 220, 16)];
    _chatInputStatusLabel.bezeled = NO;
    _chatInputStatusLabel.drawsBackground = NO;
    _chatInputStatusLabel.editable = NO;
    _chatInputStatusLabel.selectable = NO;
    _chatInputStatusLabel.textColor = [NSColor colorWithCalibratedWhite:0.82 alpha:1.0];
    _chatInputStatusLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
    _chatInputStatusLabel.stringValue = @"Enter para enviar, Esc para cerrar.";
    [content addSubview:_chatInputStatusLabel];

    NSButton *sendButton = [[NSButton alloc] initWithFrame:NSMakeRect(264, 24, 100, 28)];
    sendButton.title = @"Enviar";
    sendButton.bezelStyle = NSBezelStyleRounded;
    sendButton.target = self;
    sendButton.action = @selector(vroidSubmitChatInput:);
    [content addSubview:sendButton];

    NSButton *cancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(156, 24, 100, 28)];
    cancelButton.title = @"Cerrar";
    cancelButton.bezelStyle = NSBezelStyleRounded;
    cancelButton.target = self;
    cancelButton.action = @selector(vroidHideChatInputWindow);
    [content addSubview:cancelButton];

    window.contentView = content;
    _chatInputWindow = window;
}

- (void)vroidShowChatInputWindow {
    [self vroidEnsureChatInputWindow];
    if (_chatTask != nil) {
        _chatInputStatusLabel.stringValue = @"Tuli está pensando...";
    } else {
        _chatInputStatusLabel.stringValue = @"Enter para enviar, Esc para cerrar.";
    }
    NSRect frame = [self vroidChatInputFrame];
    [_chatInputWindow setFrame:frame display:NO];
    [_chatInputWindow orderFrontRegardless];
    [_chatInputWindow makeKeyAndOrderFront:nil];
    [_chatInputWindow makeFirstResponder:_chatInputField];
    if (_chatInputField != nil) {
        _chatInputField.stringValue = _chatInputField.stringValue ?: @"";
        [_chatInputField selectText:nil];
    }
}

- (void)vroidHideChatInputWindow {
    [_chatInputWindow orderOut:nil];
}

- (void)vroidSubmitChatInput:(id)sender {
    (void)sender;
    if (_chatTask != nil) {
        return;
    }

    NSString *prompt = [_chatInputField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (prompt.length == 0) {
        _chatInputStatusLabel.stringValue = @"Escribe algo antes de enviar.";
        return;
    }

    _chatInputStatusLabel.stringValue = @"Pensando con qwen3:1.7b...";
    _chatInputField.enabled = NO;
    [self vroidBeginChatPrompt:prompt];
}

- (void)vroidFinishChatPromptWithResponse:(NSString *)response error:(NSString *)errorText {
    _chatTask = nil;
    _chatInputField.enabled = YES;
    _chatInputField.stringValue = @"";

    if (response.length > 0) {
        _chatInputStatusLabel.stringValue = @"";
        [self vroidHideChatInputWindow];
        [self vroidSpeakText:response];
        return;
    }

    _chatInputStatusLabel.stringValue = errorText.length > 0 ? errorText : @"No salió respuesta del modelo.";
    [self vroidShowChatInputWindow];
}

- (void)vroidBeginChatPrompt:(NSString *)prompt {
    NSString *projectRoot = [self vroidProjectRootPath];
    NSString *scriptPath = [projectRoot stringByAppendingPathComponent:@"local_agent/vroid_agent_daemon.py"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:scriptPath]) {
        [self vroidFinishChatPromptWithResponse:@"" error:@"No encontré el daemon local."];
        return;
    }

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/env";
    task.arguments = @[
        @"python3",
        scriptPath,
        @"--chat",
        prompt
    ];
    task.currentDirectoryPath = projectRoot;

    NSMutableDictionary *environment = [[[NSProcessInfo processInfo] environment] mutableCopy];
    environment[@"PYTHONUNBUFFERED"] = @"1";
    task.environment = environment;

    NSPipe *stdoutPipe = [NSPipe pipe];
    NSPipe *stderrPipe = [NSPipe pipe];
    task.standardOutput = stdoutPipe;
    task.standardError = stderrPipe;

    _chatTask = task;
    __weak typeof(self) weakSelf = self;
    task.terminationHandler = ^(NSTask *finishedTask) {
        __unused NSTask *unusedTask = finishedTask;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSData *stdoutData = [[stdoutPipe fileHandleForReading] readDataToEndOfFile];
            NSData *stderrData = [[stderrPipe fileHandleForReading] readDataToEndOfFile];
            NSString *response = [[NSString alloc] initWithData:stdoutData encoding:NSUTF8StringEncoding] ?: @"";
            NSString *errorText = [[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding] ?: @"";
            response = [response stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            errorText = [errorText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) strongSelf = weakSelf;
                if (!strongSelf) {
                    return;
                }
                [strongSelf vroidFinishChatPromptWithResponse:response error:errorText.length > 0 ? errorText : @"No salió respuesta del modelo."];
            });
        });
    };

    @try {
        [task launch];
    } @catch (NSException *exception) {
        _chatTask = nil;
        _chatInputField.enabled = YES;
        [self vroidFinishChatPromptWithResponse:@"" error:[NSString stringWithFormat:@"No pude abrir el modelo: %@", exception.reason ?: @"error"]];
    }
}

- (NSString *)vroidProjectRootPath {
    NSString *bundlePath = NSBundle.mainBundle.bundlePath;
    NSString *projectRoot = [[[bundlePath stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] stringByStandardizingPath];
    return projectRoot.length > 0 ? projectRoot : [[NSFileManager defaultManager] currentDirectoryPath];
}

- (void)installAxisGuides {
    if (_axesNode != nil) {
        return;
    }

    _axesNode = [SCNNode node];
    _axesNode.name = @"Axes";

    CGFloat axisLength = 1.4;
    CGFloat axisRadius = 0.025;
    CGFloat coneHeight = 0.14;

    [self addAxisWithColor:NSColor.systemRedColor
                      axis:SCNVector3Make(1, 0, 0)
                     length:axisLength
                      root:_axesNode
                      tube:axisRadius
                 coneHeight:coneHeight];

    [self addAxisWithColor:NSColor.systemGreenColor
                      axis:SCNVector3Make(0, 1, 0)
                     length:axisLength
                      root:_axesNode
                      tube:axisRadius
                 coneHeight:coneHeight];

    [self addAxisWithColor:NSColor.systemBlueColor
                      axis:SCNVector3Make(0, 0, 1)
                     length:axisLength
                      root:_axesNode
                      tube:axisRadius
                 coneHeight:coneHeight];

    SCNSphere *origin = [SCNSphere sphereWithRadius:0.055];
    origin.firstMaterial.diffuse.contents = NSColor.whiteColor;
    origin.firstMaterial.emission.contents = NSColor.whiteColor;
    SCNNode *originNode = [SCNNode nodeWithGeometry:origin];
    originNode.renderingOrder = 10;
    [_axesNode addChildNode:originNode];
    [_rotationNode addChildNode:_axesNode];
        [self vroidHideAxesGizmo];
}

- (void)addAxisWithColor:(NSColor *)color
                    axis:(SCNVector3)axis
                   length:(CGFloat)length
                    root:(SCNNode *)root
                    tube:(CGFloat)tubeRadius
               coneHeight:(CGFloat)coneHeight {
    SCNMaterial *material = [SCNMaterial material];
    material.diffuse.contents = color;
    material.emission.contents = color;

    SCNCylinder *shaft = [SCNCylinder cylinderWithRadius:tubeRadius height:length];
    shaft.firstMaterial = material;
    SCNNode *shaftNode = [SCNNode nodeWithGeometry:shaft];

    SCNCone *tip = [SCNCone coneWithTopRadius:0.0 bottomRadius:tubeRadius * 2.2 height:coneHeight];
    tip.firstMaterial = material;
    SCNNode *tipNode = [SCNNode nodeWithGeometry:tip];

    if (axis.x != 0) {
        shaftNode.eulerAngles = SCNVector3Make(0, 0, M_PI_2);
        tipNode.eulerAngles = SCNVector3Make(0, 0, M_PI_2);
        shaftNode.position = SCNVector3Make(length * 0.5f, 0, 0);
        tipNode.position = SCNVector3Make(length + coneHeight * 0.5f, 0, 0);
    } else if (axis.y != 0) {
        shaftNode.position = SCNVector3Make(0, length * 0.5f, 0);
        tipNode.position = SCNVector3Make(0, length + coneHeight * 0.5f, 0);
    } else {
        shaftNode.eulerAngles = SCNVector3Make(M_PI_2, 0, 0);
        tipNode.eulerAngles = SCNVector3Make(M_PI_2, 0, 0);
        shaftNode.position = SCNVector3Make(0, 0, length * 0.5f);
        tipNode.position = SCNVector3Make(0, 0, length + coneHeight * 0.5f);
    }

    shaftNode.renderingOrder = 5;
    tipNode.renderingOrder = 6;
    [root addChildNode:shaftNode];
    [root addChildNode:tipNode];
}

- (void)applyRotationX:(CGFloat)x y:(CGFloat)y z:(CGFloat)z {
    if (_rotationNode == nil) {
        return;
    }

    if ([self vroidUnlockRotationEnabled]) {
        _rotationNode.eulerAngles = SCNVector3Make(x, y, z);
    } else {
        [self vroidApplyFixedLookRotation];
    [self vroidApplyCleanOverlayMode];
    }
    [self notifyRotationChanged];
}

- (NSString *)rotationString {
    SCNVector3 rot = _rotationNode.eulerAngles;
    return [NSString stringWithFormat:@"X %.3f  Y %.3f  Z %.3f", rot.x, rot.y, rot.z];
}

- (void)notifyRotationChanged {
    [self.rotationControlWindowController refreshFromSceneView];
}

- (BOOL)vroidDebugEnabled {
    NSString *value = [[[NSProcessInfo processInfo] environment] objectForKey:@"VROID_DEBUG"];
    if (!value) return NO;
    value = [value lowercaseString];
    return [value isEqualToString:@"1"] ||
           [value isEqualToString:@"true"] ||
           [value isEqualToString:@"yes"] ||
           [value isEqualToString:@"on"];
}

- (NSString *)vroidDebugLogPath {
    NSString *override = [[[NSProcessInfo processInfo] environment] objectForKey:@"VROID_DEBUG_LOG_PATH"];
    if (override.length > 0) {
        return [override stringByStandardizingPath];
    }

    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *base = paths.firstObject ?: NSTemporaryDirectory();
    NSString *dir = [base stringByAppendingPathComponent:@"VroidOverlay"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"overlay_debug.log"];
}

- (void)vroidAppendDebugLine:(NSString *)line {
    if (![self vroidDebugEnabled] || line.length == 0) {
        return;
    }

    NSString *path = [self vroidDebugLogPath];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length == 0) {
        return;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [path stringByDeletingLastPathComponent];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    if (![fm fileExistsAtPath:path]) {
        [fm createFileAtPath:path contents:nil attributes:nil];
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        return;
    }

    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
        [handle synchronizeFile];
    } @catch (__unused NSException *exception) {
    } @finally {
        [handle closeFile];
    }
}

- (void)vroidDebugLogMessage:(NSString *)message fields:(NSDictionary *)fields {
    if (![self vroidDebugEnabled]) {
        return;
    }

    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"ts"] = @([[NSDate date] timeIntervalSince1970]);
    payload[@"message"] = message ?: @"";
    if (fields.count > 0) {
        [payload addEntriesFromDictionary:fields];
    }

    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
    if (json == nil || error != nil) {
        return;
    }

    NSString *line = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    [self vroidAppendDebugLine:line];
    NSLog(@"%@", line);
}

- (void)vroidDebugLogEvent:(NSDictionary *)event rawLine:(NSString *)rawLine action:(NSString *)action result:(NSString *)result {
    if (![self vroidDebugEnabled]) {
        return;
    }

    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"ts"] = @([[NSDate date] timeIntervalSince1970]);
    payload[@"message"] = @"overlay_event";
    if (event.count > 0) {
        payload[@"event"] = event;
    }
    if (rawLine.length > 0) {
        payload[@"raw"] = rawLine;
    }
    if (action.length > 0) {
        payload[@"action"] = action;
    }
    if (result.length > 0) {
        payload[@"result"] = result;
    }

    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
    if (json == nil || error != nil) {
        return;
    }

    NSString *line = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    [self vroidAppendDebugLine:line];
    NSLog(@"%@", line);
}

- (NSString *)vroidJSONStringFromObject:(id)object {
    id safeObject = object ?: @"";
    NSError *error = nil;
    NSData *jsonData = nil;

    @try {
        if ([safeObject isKindOfClass:[NSString class]] ||
            [safeObject isKindOfClass:[NSNumber class]] ||
            [safeObject isKindOfClass:[NSNull class]]) {
            NSArray *wrapped = @[safeObject];
            NSData *wrappedData = [NSJSONSerialization dataWithJSONObject:wrapped options:0 error:&error];
            if (wrappedData.length >= 2 && error == nil) {
                NSString *wrappedString = [[NSString alloc] initWithData:wrappedData encoding:NSUTF8StringEncoding];
                if (wrappedString.length >= 2) {
                    return [wrappedString substringWithRange:NSMakeRange(1, wrappedString.length - 2)];
                }
            }
        } else if ([NSJSONSerialization isValidJSONObject:safeObject]) {
            jsonData = [NSJSONSerialization dataWithJSONObject:safeObject options:0 error:&error];
        }
    } @catch (__unused NSException *exception) {
        jsonData = nil;
    }

    if (jsonData.length == 0 || error != nil) {
        return @"\"\"";
    }

    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    return jsonString.length > 0 ? jsonString : @"\"\"";
}

- (void)vroidAppendSpeechTraceLine:(NSString *)line {
    if (line.length == 0) {
        return;
    }

    NSString *path = VroidOverlaySpeechTraceLogPath();
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length == 0) {
        return;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [path stringByDeletingLastPathComponent];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    if (![fm fileExistsAtPath:path]) {
        [fm createFileAtPath:path contents:nil attributes:nil];
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        return;
    }

    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
        [handle synchronizeFile];
    } @catch (__unused NSException *exception) {
    } @finally {
        [handle closeFile];
    }
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)mouseDown:(NSEvent *)event {
    _isDragging = YES;
    _didDrag = NO;
    _isRepositioning = NO;
    _animationsPausedForHold = NO;
    _holdScaleCaptured = NO;
    _holdToken += 1;
    NSUInteger holdToken = _holdToken;
    _lastDragPoint = [self convertPoint:event.locationInWindow fromView:nil];
    _mouseDownPoint = _lastDragPoint;
    _mouseDownScreenPoint = [self vroidScreenPointForEvent:event];
    _windowDragStartOrigin = self.window.frame.origin;
    _mouseDownTime = event.timestamp;
    _dragStartRotation = _rotationNode.eulerAngles;

    if (_modelContainer != nil) {
        _holdOriginalScale = _modelContainer.scale;
        _holdScaleCaptured = YES;
        CGFloat shrinkFactor = 0.86;
        _modelContainer.scale = SCNVector3Make(_holdOriginalScale.x * shrinkFactor,
                                               _holdOriginalScale.y * shrinkFactor,
                                               _holdOriginalScale.z * shrinkFactor);
        NSLog(@"[HOLD] model scaled down for press");
    }

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || holdToken != strongSelf->_holdToken || !strongSelf->_isDragging) {
            return;
        }

        strongSelf.scene.paused = YES;
        strongSelf->_animationsPausedForHold = YES;
        strongSelf->_isRepositioning = YES;
        strongSelf->_didDrag = YES;
        NSLog(@"[HOLD] animations paused");
    });
}

- (void)mouseDragged:(NSEvent *)event {
    if (!_isDragging) {
        return;
    }

    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (_isRepositioning) {
        NSPoint currentScreenPoint = [self vroidScreenPointForEvent:event];
        CGFloat dx = currentScreenPoint.x - _mouseDownScreenPoint.x;
        CGFloat dy = currentScreenPoint.y - _mouseDownScreenPoint.y;
        NSPoint nextOrigin = NSMakePoint(_windowDragStartOrigin.x + dx, _windowDragStartOrigin.y + dy);
        [self.window setFrameOrigin:nextOrigin];
        [self vroidSaveWindowFrame];
        [self vroidPositionSpeechBubble];
        return;
    }

    CGFloat dx = point.x - _lastDragPoint.x;
    CGFloat dy = point.y - _lastDragPoint.y;

    CGFloat totalDx = point.x - _mouseDownPoint.x;
    CGFloat totalDy = point.y - _mouseDownPoint.y;
    CGFloat totalDistance = hypot(totalDx, totalDy);
    if (totalDistance > 4.0) {
        _didDrag = YES;
    }

    CGFloat scale = 0.0125;
    SCNVector3 nextRotation = _dragStartRotation;
    nextRotation.y += dx * scale;
    nextRotation.x += dy * scale;

    if ((event.modifierFlags & NSEventModifierFlagOption) != 0) {
        nextRotation.z += dx * scale;
    }

    if ([self vroidUnlockRotationEnabled]) {
        _rotationNode.eulerAngles = nextRotation;
    } else {
        [self vroidApplyFixedLookRotation];
    }
    [self notifyRotationChanged];
}

- (void)mouseUp:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat totalDx = point.x - _mouseDownPoint.x;
    CGFloat totalDy = point.y - _mouseDownPoint.y;
    CGFloat totalDistance = hypot(totalDx, totalDy);
    NSTimeInterval heldTime = event.timestamp - _mouseDownTime;

    _isDragging = NO;
    _holdToken += 1;
    if (_isRepositioning) {
        [self vroidSaveWindowFrame];
        _isRepositioning = NO;
        if (_animationsPausedForHold) {
            self.scene.paused = NO;
            _animationsPausedForHold = NO;
            NSLog(@"[HOLD] animations resumed after reposition");
        }
        if (_holdScaleCaptured && _modelContainer != nil) {
            _modelContainer.scale = _holdOriginalScale;
            _holdScaleCaptured = NO;
        }
        [self notifyRotationChanged];
        return;
    }

    if (_animationsPausedForHold) {
        self.scene.paused = NO;
        _animationsPausedForHold = NO;
        NSLog(@"[HOLD] animations resumed");
    }

    if (_holdScaleCaptured && _modelContainer != nil) {
        _modelContainer.scale = _holdOriginalScale;
        _holdScaleCaptured = NO;
        NSLog(@"[HOLD] model scale restored");
    }

    if (!_didDrag && totalDistance <= 4.0 && heldTime <= 0.5) {
        _rapidTapCount = 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self vroidShowChatInputWindow];
        });
    } else if (heldTime > 0.5) {
        _rapidTapCount = 0;
    }
    [self notifyRotationChanged];
}

- (NSPoint)vroidScreenPointForEvent:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSRect screenRect = [self.window convertRectToScreen:NSMakeRect(point.x, point.y, 0.0, 0.0)];
    return screenRect.origin;
}

- (void)vroidSaveWindowFrame {
    if (self.window == nil) {
        return;
    }

    NSString *frameString = NSStringFromRect(self.window.frame);
    [[NSUserDefaults standardUserDefaults] setObject:frameString forKey:VroidOverlayWindowFrameDefaultsKey];
}

- (void)vroidMoveWindowAwayFromScreenPoint:(NSPoint)screenPoint {
    if (self.window == nil) {
        return;
    }

    NSScreen *screen = self.window.screen ?: NSScreen.mainScreen;
    NSRect visible = screen.visibleFrame;
    NSRect frame = self.window.frame;
    CGFloat margin = 24.0;

    CGFloat targetX = NSMinX(visible) + margin;
    CGFloat targetY = NSMinY(visible) + margin;
    CGFloat farthestDistance = -1.0;

    for (NSInteger i = 0; i < 24; i++) {
        CGFloat maxX = MAX(NSMinX(visible), NSMaxX(visible) - NSWidth(frame));
        CGFloat maxY = MAX(NSMinY(visible), NSMaxY(visible) - NSHeight(frame));
        CGFloat candidateX = NSMinX(visible) + (CGFloat)arc4random_uniform((uint32_t)MAX(1.0, maxX - NSMinX(visible) + 1.0));
        CGFloat candidateY = NSMinY(visible) + (CGFloat)arc4random_uniform((uint32_t)MAX(1.0, maxY - NSMinY(visible) + 1.0));
        NSPoint candidateCenter = NSMakePoint(candidateX + NSWidth(frame) * 0.5, candidateY + NSHeight(frame) * 0.5);
        CGFloat distance = hypot(candidateCenter.x - screenPoint.x, candidateCenter.y - screenPoint.y);

        if (distance > farthestDistance) {
            farthestDistance = distance;
            targetX = candidateX;
            targetY = candidateY;
        }
    }

    targetX = MAX(NSMinX(visible), MIN(targetX, NSMaxX(visible) - NSWidth(frame)));
    targetY = MAX(NSMinY(visible), MIN(targetY, NSMaxY(visible) - NSHeight(frame)));

    [self.window setFrameOrigin:NSMakePoint(targetX, targetY)];
    [self vroidSaveWindowFrame];
    [self vroidPositionSpeechBubble];
    NSLog(@"[MOVE] jumped away from click point");
}

@end

@interface RotationControlWindowController : NSWindowController <NSTextFieldDelegate, RotationControlUpdating>
- (instancetype)initWithSceneView:(OverlaySceneView *)sceneView;
- (void)refreshFromSceneView;
@end

@implementation RotationControlWindowController {
    __weak OverlaySceneView *_sceneView;
    NSTextField *_xField;
    NSTextField *_yField;
    NSTextField *_zField;
    NSTextField *_statusField;
}

- (instancetype)initWithSceneView:(OverlaySceneView *)sceneView {
    NSRect frame = NSMakeRect(0, 0, 270, 166);
    NSPanel *window = [[NSPanel alloc]
        initWithContentRect:frame
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskUtilityWindow
        backing:NSBackingStoreBuffered
        defer:NO
    ];

    window.floatingPanel = YES;
    window.becomesKeyOnlyIfNeeded = YES;
    window.level = NSFloatingWindowLevel;
    window.hidesOnDeactivate = NO;
    window.title = @"Rotation";

    NSView *content = [[NSView alloc] initWithFrame:frame];
    content.wantsLayer = YES;
    content.layer.backgroundColor = [[NSColor colorWithCalibratedWhite:0.12 alpha:0.92] CGColor];
    window.contentView = content;

    _sceneView = sceneView;

    NSTextField *title = [self labelWithText:@"Rotacion del modelo (radianes)" frame:NSMakeRect(14, 126, 240, 18)];
    [content addSubview:title];

    _xField = [self fieldWithFrame:NSMakeRect(40, 92, 72, 24)];
    _yField = [self fieldWithFrame:NSMakeRect(116, 92, 72, 24)];
    _zField = [self fieldWithFrame:NSMakeRect(192, 92, 72, 24)];
    _xField.stringValue = @"0.0";
    _yField.stringValue = @"3.1416";
    _zField.stringValue = @"0.0";

    [content addSubview:[self smallLabel:@"X" frame:NSMakeRect(22, 95, 12, 16)]];
    [content addSubview:[self smallLabel:@"Y" frame:NSMakeRect(98, 95, 12, 16)]];
    [content addSubview:[self smallLabel:@"Z" frame:NSMakeRect(174, 95, 12, 16)]];
    [content addSubview:_xField];
    [content addSubview:_yField];
    [content addSubview:_zField];

    NSButton *apply = [self buttonWithTitle:@"Aplicar" action:@selector(applyRotation:) frame:NSMakeRect(14, 52, 76, 28)];
    NSButton *reset = [self buttonWithTitle:@"Reset" action:@selector(resetRotation:) frame:NSMakeRect(96, 52, 64, 28)];
    NSButton *copy = [self buttonWithTitle:@"Copiar" action:@selector(copyRotation:) frame:NSMakeRect(166, 52, 64, 28)];

    [content addSubview:apply];
    [content addSubview:reset];
    [content addSubview:copy];

    _statusField = [self labelWithText:@"" frame:NSMakeRect(14, 18, 242, 18)];
    _statusField.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    [content addSubview:_statusField];

    self = [super initWithWindow:window];
    if (self) {
        [self syncStatus];
    }
    return self;
}

- (NSTextField *)labelWithText:(NSString *)text frame:(NSRect)frame {
    NSTextField *field = [[NSTextField alloc] initWithFrame:frame];
    field.stringValue = text;
    field.bezeled = NO;
    field.drawsBackground = NO;
    field.editable = NO;
    field.selectable = NO;
    field.textColor = NSColor.whiteColor;
    field.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    return field;
}

- (NSTextField *)smallLabel:(NSString *)text frame:(NSRect)frame {
    NSTextField *field = [self labelWithText:text frame:frame];
    field.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    return field;
}

- (NSTextField *)fieldWithFrame:(NSRect)frame {
    NSTextField *field = [[NSTextField alloc] initWithFrame:frame];
    field.bordered = YES;
    field.bezeled = YES;
    field.backgroundColor = NSColor.blackColor;
    field.textColor = NSColor.whiteColor;
    field.focusRingType = NSFocusRingTypeNone;
    field.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    field.delegate = self;
    return field;
}

- (NSButton *)buttonWithTitle:(NSString *)title action:(SEL)action frame:(NSRect)frame {
    NSButton *button = [[NSButton alloc] initWithFrame:frame];
    button.title = title;
    button.bezelStyle = NSBezelStyleRounded;
    button.target = self;
    button.action = action;
    return button;
}

- (void)applyRotation:(id)sender {
    CGFloat x = _xField.doubleValue;
    CGFloat y = _yField.doubleValue;
    CGFloat z = _zField.doubleValue;
    [_sceneView applyRotationX:x y:y z:z];
    [self syncStatus];
}

- (void)resetRotation:(id)sender {
    _xField.stringValue = @"0.0";
    _yField.stringValue = @"3.1416";
    _zField.stringValue = @"0.0";
    [self applyRotation:nil];
}

- (void)copyRotation:(id)sender {
    NSString *rotation = [_sceneView rotationString];
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:rotation forType:NSPasteboardTypeString];
    [self syncStatus];
}

- (void)syncStatus {
    _statusField.stringValue = [_sceneView rotationString];
}

- (void)refreshFromSceneView {
    [self syncStatus];
}

@end

@interface OverlayWindowController : NSWindowController
@end

@implementation OverlayWindowController

- (instancetype)init {
    NSRect frame = NSMakeRect(0, 0, 360, 360);
    NSPanel *window = [[NSPanel alloc]
        initWithContentRect:frame
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered
        defer:NO
    ];

    window.opaque = NO;
    window.backgroundColor = NSColor.clearColor;
    window.hasShadow = NO;
    window.level = NSStatusWindowLevel;
    window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorFullScreenAuxiliary |
        NSWindowCollectionBehaviorIgnoresCycle;
    window.ignoresMouseEvents = NO;
    window.titleVisibility = NSWindowTitleHidden;
    window.titlebarAppearsTransparent = YES;

    OverlaySceneView *view = [[OverlaySceneView alloc] initWithFrame:frame];
    [view loadModelAtURL:ModelURL()];
    window.contentView = view;
    window.initialFirstResponder = view;

    self = [super initWithWindow:window];
    if (self) {
        NSString *savedFrameString = [[NSUserDefaults standardUserDefaults] stringForKey:VroidOverlayWindowFrameDefaultsKey];
        NSRect savedFrame = savedFrameString.length > 0 ? NSRectFromString(savedFrameString) : NSZeroRect;

        if (!NSEqualRects(savedFrame, NSZeroRect)) {
            NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
            NSRect visible = screen.visibleFrame;
            CGFloat x = MAX(NSMinX(visible), MIN(savedFrame.origin.x, NSMaxX(visible) - NSWidth(frame)));
            CGFloat y = MAX(NSMinY(visible), MIN(savedFrame.origin.y, NSMaxY(visible) - NSHeight(frame)));
            [window setFrameOrigin:NSMakePoint(x, y)];
        } else {
            NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
            NSRect visible = screen.visibleFrame;
            CGFloat inset = 24.0;
            NSPoint origin = NSMakePoint(
                NSMaxX(visible) - NSWidth(frame) - inset,
                NSMaxY(visible) - NSHeight(frame) - inset
            );
            [window setFrameOrigin:origin];
        }
    }
    return self;
}

@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) OverlayWindowController *windowController;
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenu *statusMenu;
@property (nonatomic, strong) NSMenuItem *memoryModeItem;
@property (nonatomic, strong) NSWindow *logsWindow;
@property (nonatomic, strong) NSTextView *logsTextView;
@property (nonatomic, strong) NSTimer *logsRefreshTimer;
@end

@implementation AppDelegate

- (NSImage *)vroidStatusBarCircleImage {
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(18.0, 18.0)];
    [image lockFocus];
    [[NSGraphicsContext currentContext] setShouldAntialias:YES];
    NSBezierPath *path = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(NSMakeRect(0, 0, 18.0, 18.0), 4.0, 4.0)];
    [[NSColor colorWithCalibratedWhite:0.95 alpha:1.0] setFill];
    [path fill];
    [image unlockFocus];
    image.template = YES;
    return image;
}

- (void)vroidTerminateApp:(id)sender {
    [NSApp terminate:nil];
}

- (void)vroidShowLogsWindow:(id)sender {
    if (self.logsWindow == nil) {
        NSRect frame = NSMakeRect(0, 0, 720, 460);
        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:frame
                      styleMask:(NSWindowStyleMaskTitled |
                                 NSWindowStyleMaskClosable |
                                 NSWindowStyleMaskResizable)
                        backing:NSBackingStoreBuffered
                          defer:NO];
        window.title = @"VroidOverlay Logs";
        window.releasedWhenClosed = NO;
        window.minSize = NSMakeSize(520, 320);

        NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:frame];
        scrollView.hasVerticalScroller = YES;
        scrollView.hasHorizontalScroller = YES;
        scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

        NSTextView *textView = [[NSTextView alloc] initWithFrame:frame];
        textView.editable = NO;
        textView.selectable = YES;
        textView.font = [NSFont fontWithName:@"Menlo" size:11.0] ?: [NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightRegular];
        textView.backgroundColor = [NSColor colorWithCalibratedWhite:0.10 alpha:1.0];
        textView.textColor = [NSColor colorWithCalibratedWhite:0.92 alpha:1.0];
        textView.automaticQuoteSubstitutionEnabled = NO;
        textView.automaticDashSubstitutionEnabled = NO;
        textView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        scrollView.documentView = textView;

        window.contentView = scrollView;
        self.logsWindow = window;
        self.logsTextView = textView;
    }

    [self vroidRefreshLogsWindowContents];
    [self.logsWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    if (self.logsRefreshTimer == nil) {
        self.logsRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:0.75
                                                                 target:self
                                                               selector:@selector(vroidRefreshLogsWindowContents)
                                                               userInfo:nil
                                                                repeats:YES];
    }
}

- (void)vroidRefreshLogsWindowContents {
    if (self.logsTextView == nil) {
        return;
    }

    NSString *overlayPath = VroidOverlayOverlayDebugLogPath();
    NSString *bridgePath = VroidOverlayBridgeDebugLogPath();
    NSFileManager *fm = [NSFileManager defaultManager];

    NSString *overlayText = @"[overlay_debug.log]\n(no file yet)\n";
    if ([fm fileExistsAtPath:overlayPath]) {
        overlayText = [NSString stringWithContentsOfFile:overlayPath encoding:NSUTF8StringEncoding error:nil] ?: @"[overlay_debug.log]\n(could not read file)\n";
    }

    NSString *bridgeText = @"[bridge_debug.log]\n(no file yet)\n";
    if ([fm fileExistsAtPath:bridgePath]) {
        bridgeText = [NSString stringWithContentsOfFile:bridgePath encoding:NSUTF8StringEncoding error:nil] ?: @"[bridge_debug.log]\n(could not read file)\n";
    }

    NSString *combined = [NSString stringWithFormat:
        @"=== Overlay ===\nPath: %@\n\n%@\n\n=== Bridge ===\nPath: %@\n\n%@",
        overlayPath,
        overlayText,
        bridgePath,
        bridgeText];
    self.logsTextView.string = combined;
    [self.logsTextView scrollRangeToVisible:NSMakeRange(MAX((NSInteger)combined.length - 1, 0), 1)];
}

- (NSString *)vroidProjectRootPath {
    NSString *bundlePath = NSBundle.mainBundle.bundlePath;
    NSString *projectRoot = [[[bundlePath stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] stringByStandardizingPath];
    return projectRoot.length > 0 ? projectRoot : [[NSFileManager defaultManager] currentDirectoryPath];
}

- (NSString *)vroidAgentStatePath {
    return [[self vroidProjectRootPath] stringByAppendingPathComponent:VroidOverlayAgentStateRelativePath];
}

- (NSMutableDictionary *)vroidLoadAgentState {
    NSString *path = [self vroidAgentStatePath];
    NSData *data = [NSData dataWithContentsOfFile:path];
    id object = nil;
    if (data.length > 0) {
        object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    }
    NSMutableDictionary *state = [object isKindOfClass:[NSDictionary class]] ? [(NSDictionary *)object mutableCopy] : [NSMutableDictionary dictionary];
    NSString *mode = [state[VroidOverlayMemoryModeKey] isKindOfClass:[NSString class]] ? state[VroidOverlayMemoryModeKey] : nil;
    if (mode.length == 0) {
        state[VroidOverlayMemoryModeKey] = VroidOverlayMemoryModeConversational;
    }
    return state;
}

- (BOOL)vroidSaveAgentState:(NSDictionary *)state {
    NSString *path = [self vroidAgentStatePath];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *data = [NSJSONSerialization dataWithJSONObject:state ?: @{} options:NSJSONWritingPrettyPrinted error:nil];
    if (data.length == 0) {
        return NO;
    }
    return [data writeToFile:path atomically:YES];
}

- (NSString *)vroidCurrentMemoryMode {
    NSDictionary *state = [self vroidLoadAgentState];
    NSString *mode = [state[VroidOverlayMemoryModeKey] isKindOfClass:[NSString class]] ? state[VroidOverlayMemoryModeKey] : nil;
    if (mode.length == 0) {
        return VroidOverlayMemoryModeConversational;
    }
    mode = [mode lowercaseString];
    if ([mode isEqualToString:VroidOverlayMemoryModeProgrammer]) {
        return VroidOverlayMemoryModeProgrammer;
    }
    return VroidOverlayMemoryModeConversational;
}

- (NSString *)vroidTitleForMemoryMode:(NSString *)mode {
    if ([mode isEqualToString:VroidOverlayMemoryModeProgrammer]) {
        return @"Modo: Programador";
    }
    return @"Modo: Conversacional";
}

- (void)vroidRefreshMemoryModeMenuTitle {
    if (self.memoryModeItem == nil) {
        return;
    }
    self.memoryModeItem.title = [self vroidTitleForMemoryMode:[self vroidCurrentMemoryMode]];
}

- (void)vroidSetMemoryMode:(NSString *)mode {
    NSString *normalized = [mode isEqualToString:VroidOverlayMemoryModeProgrammer] ? VroidOverlayMemoryModeProgrammer : VroidOverlayMemoryModeConversational;
    NSMutableDictionary *state = [self vroidLoadAgentState];
    state[VroidOverlayMemoryModeKey] = normalized;
    if (![self vroidSaveAgentState:state]) {
        NSLog(@"[MODE] failed to save memory mode to %@", [self vroidAgentStatePath]);
        return;
    }
    NSLog(@"[MODE] memory mode set to %@", normalized);
    [self vroidRefreshMemoryModeMenuTitle];
}

- (void)vroidToggleMemoryMode:(id)sender {
    (void)sender;
    NSString *next = [[self vroidCurrentMemoryMode] isEqualToString:VroidOverlayMemoryModeProgrammer]
        ? VroidOverlayMemoryModeConversational
        : VroidOverlayMemoryModeProgrammer;
    [self vroidSetMemoryMode:next];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:24.0];
    self.statusItem.button.image = [self vroidStatusBarCircleImage];
    self.statusItem.button.toolTip = @"VroidOverlay";

    self.statusMenu = [[NSMenu alloc] initWithTitle:@"VroidOverlay"];
    NSMenuItem *logsItem = [[NSMenuItem alloc] initWithTitle:@"Logs"
                                                      action:@selector(vroidShowLogsWindow:)
                                               keyEquivalent:@""];
    logsItem.target = self;
    [self.statusMenu addItem:logsItem];

    self.memoryModeItem = [[NSMenuItem alloc] initWithTitle:[self vroidTitleForMemoryMode:[self vroidCurrentMemoryMode]]
                                                     action:@selector(vroidToggleMemoryMode:)
                                              keyEquivalent:@""];
    self.memoryModeItem.target = self;
    [self.statusMenu addItem:self.memoryModeItem];

    [self.statusMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Cerrar"
                                                      action:@selector(vroidTerminateApp:)
                                               keyEquivalent:@""];
    quitItem.target = self;
    [self.statusMenu addItem:quitItem];
    self.statusItem.menu = self.statusMenu;

    self.windowController = [[OverlayWindowController alloc] init];
    [self.windowController showWindow:nil];
    [(OverlaySceneView *)self.windowController.window.contentView vroidStartPendingSpeechIfNeeded];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return NO;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.logsRefreshTimer invalidate];
    self.logsRefreshTimer = nil;
}

@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return EXIT_SUCCESS;
}
