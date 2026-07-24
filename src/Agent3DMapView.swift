import AppKit
import SceneKit
import QuartzCore
import simd

// MARK: - Left HUD document (flipped for top-down scroll)

/// NSScrollView document with y-down so TRACKING sits at the top of the stack.
private final class LeftHUDStackView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Left HUD horizontal splitter (always wins hit-test over SceneKit)

/// 16pt hit strip on the right edge of the left column. Uses mouseDown/drag
/// (not a pan gesture) so SCNView never steals the widen drag. Draws a 2–3pt
/// lime line; brightens on hover. Double-click resets default width.
private final class LeftHUDSplitterView: NSView {
    /// Called with horizontal delta in **window** coordinates (stable across hosts).
    var onDragDelta: ((CGFloat) -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onDoubleClickReset: (() -> Void)?

    private var dragStartX: CGFloat = 0
    private var isDragging = false
    private var isHovering = false
    private let lineLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        // Visible 2.5pt center line
        lineLayer.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.22).cgColor
        lineLayer.cornerRadius = 1
        layer?.addSublayer(lineLayer)
        toolTip = "Drag right edge to widen human / cron panels · double-click resets"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let lw: CGFloat = 2.5
        let h = max(24, bounds.height - 16)
        lineLayer.frame = CGRect(
            x: (bounds.width - lw) * 0.5,
            y: (bounds.height - h) * 0.5,
            width: lw,
            height: h
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
            owner: self,
            userInfo: nil
        ))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Always claim our bounds (and a 1pt pad) so SceneKit cannot win the strip
        let expanded = bounds.insetBy(dx: -1, dy: 0)
        return expanded.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        applyChrome()
        NSCursor.resizeLeftRight.set()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        if !isDragging { applyChrome() }
        NSCursor.arrow.set()
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleClickReset?()
            return
        }
        isDragging = true
        // Window coords — reliable after promote-to-canvasPage and pure 3D
        dragStartX = event.locationInWindow.x
        onDragBegan?()
        applyChrome()
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let x = event.locationInWindow.x
        let dx = x - dragStartX
        dragStartX = x
        onDragDelta?(dx)
        NSCursor.resizeLeftRight.set()
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        onDragEnded?()
        applyChrome()
        NSCursor.arrow.set()
    }

    private func applyChrome() {
        if isDragging || isHovering {
            layer?.backgroundColor = PongSheetChrome.lime.withAlphaComponent(0.18).cgColor
            lineLayer.backgroundColor = PongSheetChrome.lime.withAlphaComponent(0.95).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            lineLayer.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.28).cgColor
        }
    }

    func resetChrome() {
        isDragging = false
        isHovering = false
        applyChrome()
    }
}

/// Human panel accepts arbitrary file drag-and-drop (paths staged for Send).
private final class PongFileDropView: NSView {
    var onPaths: (([String]) -> Void)?
    var onHighlight: ((Bool) -> Void)?
    private var baseBorder: CGColor?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasFileURLs(sender) else { return [] }
        baseBorder = layer?.borderColor
        onHighlight?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasFileURLs(sender) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onHighlight?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hasFileURLs(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onHighlight?(false)
        let paths = filePaths(from: sender)
        guard !paths.isEmpty else { return false }
        onPaths?(paths)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        onHighlight?(false)
    }

    private func hasFileURLs(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ])
    }

    private func filePaths(from sender: NSDraggingInfo) -> [String] {
        let pb = sender.draggingPasteboard
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ]) as? [URL] else { return [] }
        // Cap at 40 paths — folders stay as one path each (no recursive expand)
        return urls.prefix(40).map { $0.path }
    }
}

// MARK: - Seat model for 3D map

struct Seat3D {
    let session: String
    let id: String
    let role: String          // conductor | worker | subagent
    let title: String
    let subtitle: String
    let detail: String
    let status: String        // live | busy | idle | human | hidden
    let parentId: String?     // for subagents
    let openJobs: Int
    /// Short task preview for edge labels (from open jobs)
    let flowHint: String
    /// Mission role (coder / reviewer / operator / …) for map glyph
    let missionRole: String
    /// True = live only while active (spawned subagents); removed from map when done.
    let ephemeral: Bool
    /// Neon catalog accent for primitive body + active plane glow (nil = role default).
    let accent: NSColor?
    var globalId: String { "\(session)::\(id)" }

    init(
        session: String, id: String, role: String, title: String, subtitle: String,
        detail: String, status: String, parentId: String?, openJobs: Int,
        flowHint: String, missionRole: String, ephemeral: Bool = false,
        accent: NSColor? = nil
    ) {
        self.session = session; self.id = id; self.role = role
        self.title = title; self.subtitle = subtitle; self.detail = detail
        self.status = status; self.parentId = parentId; self.openJobs = openJobs
        self.flowHint = flowHint; self.missionRole = missionRole
        self.ephemeral = ephemeral
        self.accent = accent
    }

    var resolvedMission: MissionRole {
        if role == "conductor" { return .orchestrator }
        return MissionRole.parse(missionRole) ?? .coder
    }

    /// Lattice-style link label (named plotline)
    var linkLabel: String {
        let st = status.lowercased()
        if st.contains("human") { return "NEEDS YOU" }
        if openJobs > 0 {
            let h = flowHint.trimmingCharacters(in: .whitespacesAndNewlines)
            if !h.isEmpty { return String(h.prefix(28)).uppercased() }
            return "JOB ×\(openJobs)"
        }
        if st.contains("busy") || st.contains("running") { return "BUILD" }
        if st.contains("live") { return "LINK" }
        return "IDLE"
    }
}

/// Named directed link (Palantir plotline / Lattice track)
struct FlowLink3D {
    let id: String
    let fromGid: String
    let toGid: String
    let label: String
    let kind: Kind
    let active: Bool
    let human: Bool
    /// Origin seat role for line/arrow color (conductor → blue, agent → magenta)
    let fromRole: String
    enum Kind: String { case delegate, peer, sub, claim }
}

/// SCNView that routes scroll/pinch to us before the default camera controller.
private final class PongSCNView: SCNView {
    /// Return true if the event was handled (caller should not call super).
    var handleCameraGesture: ((NSEvent) -> Bool)?

    override func scrollWheel(with event: NSEvent) {
        if handleCameraGesture?(event) == true { return }
        super.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        if handleCameraGesture?(event) == true { return }
        super.magnify(with: event)
    }
}

// MARK: - 3D constellation map

/// SceneKit constellation: soft seat orbs inside a dotted sphere shell.
/// Hierarchy: orchestrator high · agents mid · subagents low.
/// Click orb → floating module card (2D); Open on card → terminal.
final class Agent3DMapView: NSView, SCNSceneRendererDelegate, NSGestureRecognizerDelegate {
    private let scnView = PongSCNView(frame: .zero)
    private let scene = SCNScene()
    private let rootNode = SCNNode()
    /// Decks, grid dots, atmosphere — rebuilt on light/dark switch
    private let decorRoot = SCNNode()
    private var seatNodes: [String: SCNNode] = [:]   // globalId → blob root
    private var edgeNodes: [String: SCNNode] = [:]    // "a>b" → line
    /// World radius of each flow-line cylinder at scale 1 (KVC Float boxing is unreliable).
    private var edgeBaseRadius: [String: Float] = [:]
    /// Content signatures for live edges — skip teardown when unchanged so packets keep moving.
    private var edgeSigs: [String: String] = [:]
    /// Edge id → unix time when packet flow should stop (linger after last real data).
    private var edgeFlowExpire: [String: TimeInterval] = [:]
    /// How long packets keep running after the last real handoff (seconds).
    private let flowLingerSec: TimeInterval = 5.0
    /// Face texture cache keyed by role|status|title|mission|active (avoid 256px redraw every 2.5s).
    private var faceImageCache: [String: NSImage] = [:]
    /// Active ground rings live on the deck plane (not parented to bobbing seat roots).
    private var planeRings: [String: SCNNode] = [:]
    private var seats: [Seat3D] = []
    private var multiTeam = false
    private var themeObserver: NSObjectProtocol?
    /// Last camera XZ for billboard — skip yaw write when camera is static.
    private var lastCamXZ: (Float, Float)?
    /// Serialize scene-graph mutations: main-thread rebuilds race SceneKit's render queue
    /// (`advancePulse` was EXC_BAD_ACCESS after a few minutes of orbit/poll).
    private let sceneLock = NSLock()
    /// LOD face swaps must not call updateBlobMaterial on the render queue.
    private var pendingFaceLOD: [String: Bool] = [:]

    private let hoverHUD = NSView(frame: .zero)
    private let hoverTitle = NSTextField(labelWithString: "")
    private let hoverBody = NSTextField(wrappingLabelWithString: "")
    private let hoverStatus = NSTextField(labelWithString: "")
    private var hoverTracking: NSTrackingArea?
    private var hoveredId: String?
    /// SCNView + camera control swallows mouseMoved; local monitor keeps hover alive.
    private var hoverMonitor: Any?

    /// Hit categories: interactive seats/edges vs ghost décor (decks, shell, grid).
    private static let hitInteractive: Int = 1
    private static let hitDecor: Int = 2

    /// Floating 2D module card (old canvas module) after orb click
    private var moduleHost: NSView?
    private var moduleCard: AgentNodeView?
    private var moduleSeat: Seat3D?

    /// Palantir-style tracking list (active links / seats)
    private let trackPanel = NSView(frame: .zero)
    private let trackTitle = NSTextField(labelWithString: "TRACKING")
    private let trackBody = NSTextField(wrappingLabelWithString: "")
    private let legendPanel = NSView(frame: .zero)

    /// Docked YOU chat under TRACKING (same chrome). Collapse/expand only — never gone.
    private let humanPanel = PongFileDropView(frame: .zero)
    private let humanTitle = NSTextField(labelWithString: "YOU · HUMAN")
    private let humanToggle = NSButton(frame: .zero)  // chevron ▾ / ▸ top-right
    private let humanOrchPop = NSPopUpButton(frame: .zero, pullsDown: false)
    /// Interactive card stream (replaces mono text dump).
    private let humanChatStream = HumanChatStreamView(frame: .zero)
    /// Legacy ask chrome kept hidden — ask cards live in the stream.
    private let humanAskLabel = NSTextField(wrappingLabelWithString: "")
    private let humanDenyBtn = NSButton(frame: .zero)
    private let humanAcceptOnceBtn = NSButton(frame: .zero)
    private let humanAlwaysBtn = NSButton(frame: .zero)
    private let humanAskRow = NSView(frame: .zero)
    private let humanInput = NSTextField(frame: .zero)
    private let humanSend = NSButton(frame: .zero)
    private let humanClear = NSButton(frame: .zero)
    private let humanGrow = NSButton(frame: .zero)
    /// Staged file paths from drag-drop (included on Send).
    private var humanPendingFiles: [String] = []
    private let humanAttachLabel = NSTextField(labelWithString: "")
    private var humanSession: String = ""
    /// Top-bar team focus: real session id, `"__all__"`, or nil.
    private var focusedTeamSession: String?
    private var lastSingleTeamFocus: String?
    private let humanLockLabel = NSTextField(labelWithString: "")
    private let humanAllBanner = NSTextField(labelWithString: "")
    private var humanExpanded = true
    private var humanTall = false
    /// Preferred expanded height (persisted); continuous drag resize.
    /// First-run default ~380 when prefs has no `human_panel_height` (never clobber saved, even tiny).
    private var humanPreferredHeight: CGFloat = {
        let prefs = Pong.loadJSON(Pong.stateDir + "/ui-prefs.json")
        if let v = prefs["human_panel_height"] as? Double {
            return CGFloat(min(700, max(160, v)))
        }
        return 380
    }()
    private var humanPanelHeight: NSLayoutConstraint?
    private var humanAskRowHeight: NSLayoutConstraint?
    private var humanChatStreamHeight: NSLayoutConstraint?
    private var humanInputHeight: NSLayoutConstraint?
    private var humanPanelBaseBorder: CGColor?
    private let humanVResizeGrip = NSView(frame: .zero)
    private var humanVResizeStartY: CGFloat = 0
    private var humanVResizeStartH: CGFloat = 0

    /// Task recap under YOU — “worker → what they’re doing” (replaces orch Focus button).
    private let taskPanel = NSView(frame: .zero)
    private let taskTitle = NSTextField(labelWithString: "TASKS")
    private let taskBody = NSTextField(wrappingLabelWithString: "")
    private var taskPanelHeight: NSLayoutConstraint?

    private let hintLabel = NSTextField(labelWithString: "")
    private var pulsePhase: CGFloat = 0
    private var displayLink: CVDisplayLink?
    /// Pulse timer kept on `.common` so bob/yaw keep running during orbit gestures.
    private var pulseTimer: Timer?
    /// True while the user is live-resizing the window — pause SceneKit + pulse.
    private var isLiveResizing = false
    /// True during orbit/pan/move — poll skips full map reload (beachball fix).
    private(set) var isUserInteracting = false
    private var interactionIdleWork: DispatchWorkItem?
    private var lastLinks: [FlowLink3D] = []
    /// Skip layoutSeats when seat list signature unchanged (poll path).
    private var lastSeatsSig: String = ""

    /// edit: move seats on deck · normal: orbit / module popup
    /// (Topology editing is Architecture… sheet — same as wizard; map Flow mode removed.)
    private enum MapMode { case navigate, move }
    private var mapMode: MapMode = .navigate
    private var linkSourceGid: String?
    private var dragGid: String?
    private var dragPlaneY: CGFloat = 0
    private let editBar = NSView(frame: .zero)
    private var modeButtons: [NSButton] = []
    /// Only active in Move mode — otherwise it steals pans from SceneKit orbit.
    private var movePan: NSPanGestureRecognizer!
    /// Orbit mode: ⇧ + drag pans (hand cursor). Regular drag still orbits.
    private var orbitShiftPan: NSPanGestureRecognizer!
    private var isShiftPanning = false
    private var flagsMonitor: Any?

    var onOpen: ((Seat3D) -> Void)?
    var onFocus: ((Seat3D) -> Void)?
    var onRename: ((Seat3D) -> Void)?
    var onKill: ((Seat3D) -> Void)?
    var onOptions: ((Seat3D) -> Void)?
    var onPerms: ((Seat3D) -> Void)?
    /// Switch live seat CLI / model (workers).
    var onChangeModel: ((Seat3D) -> Void)?
    /// Side pad: add peer agent on the AGENTS plane (no parent).
    var onPlus: ((Seat3D) -> Void)?
    /// Under-cube pad: add subagent under this agent (SUB plane).
    var onAddSub: ((Seat3D) -> Void)?
    var onMinus: ((Seat3D) -> Void)?
    var onGraphChanged: (() -> Void)?
    /// You / human console (prompt + answers without Terminal)
    var onHuman: ((Seat3D) -> Void)?

    // Hierarchy heights — redesign: 24×24 planes, gap 10
    private let yConductor: Float = 10.0
    private let yHuman: Float = 17.0
    private let yWorker: Float = 0.0
    private let ySub: Float = -10.0
    private let planeSize: Float = 24
    private let shellRadius: Float = 28

    /// Scrollable left HUD: TRACKING → YOU → CRON → TASKS (short windows still see all panels)
    private let leftHUDScroll = NSScrollView(frame: .zero)
    /// Flipped so top-to-bottom Auto Layout matches scroll origin (y grows downward).
    private let leftHUDStack = LeftHUDStackView(frame: .zero)
    /// Horizontal width of tracking/YOU column — user-resizable.
    private var leftHUDColW: CGFloat = {
        let v = (Pong.loadJSON(Pong.stateDir + "/ui-prefs.json")["left_hud_width"] as? Double) ?? 240
        return CGFloat(min(420, max(180, v)))
    }()
    private var leftHUDScrollW: NSLayoutConstraint?
    private var leftHUDStackW: NSLayoutConstraint?
    private var leftHUDPanelWidthConstraints: [NSLayoutConstraint] = []
    private let leftHUDSplitter = LeftHUDSplitterView(frame: .zero)
    /// Width constraint for the hit strip (14–16pt).
    private var leftHUDSplitterW: NSLayoutConstraint?
    private static let leftHUDSplitterHitW: CGFloat = 16
    private static let leftHUDDefaultColW: CGFloat = 240

    /// Cron timeline panel (left stack, collapsible list) + 3D ruler
    private let cronPanel = NSView(frame: .zero)
    private let cronTitle = NSTextField(labelWithString: "CRON · TIMELINE")
    private let cronBody = NSTextField(wrappingLabelWithString: "")
    private let cronEditBtn = NSButton(frame: .zero)
    private let cronToggle = NSButton(frame: .zero)
    private var cronListExpanded = true
    private var cronPanelHeightConstraint: NSLayoutConstraint?
    /// 3D scrollable ruler (variant B)
    private let rulerRoot = SCNNode()
    private let rulerDyn = SCNNode()
    private var rulerOffsetH: Double = 0
    private var rulerDirty = true
    private var rulerDragLastZ: Float?
    private let rulerX: Float = 15.5
    private let rulerHalf: Float = 18
    private let rulerW: Float = 2.8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        setupScene()
        setupHUD()
        setupLeftHUDScroll()
        setupTrackingPanel()
        setupHumanPanel()
        setupCronPanel()   // left: under YOU
        setupTaskPanel()   // left: under CRON
        finalizeLeftHUDStack()
        setupLegend()      // right: legend only
        setupEditBar()
        setupHint()
        applyCameraMode()
        startPulse()
        applyMapTheme()
        themeObserver = NotificationCenter.default.addObserver(
            forName: PongTheme.appearanceDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyMapTheme()
        }
        // HUD above SceneKit (AppKit: re-add above siblings)
        for v in [leftHUDScroll, leftHUDSplitter, legendPanel, hintLabel, editBar, hoverHUD] as [NSView] {
            addSubview(v, positioned: .above, relativeTo: nil)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        stopPulse()
        if let hoverMonitor { NSEvent.removeMonitor(hoverMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }

    // MARK: - Light / dark map chrome

    private var mapIsDark: Bool { PongTheme.appearance == .dark }

    /// Void behind the constellation
    private var mapVoid: NSColor {
        // Design: deep blue-black #06090d (not pure black — kills depth)
        mapIsDark
            ? NSColor(calibratedRed: 0.024, green: 0.035, blue: 0.051, alpha: 1)
            : NSColor(calibratedWhite: 0.94, alpha: 1)
    }
    /// Deck plate / grid / shell dots
    private var mapInk: NSColor {
        mapIsDark ? NSColor.white : NSColor(calibratedWhite: 0.12, alpha: 1)
    }
    private var mapPanelFill: NSColor {
        mapIsDark
            ? NSColor(calibratedWhite: 0.04, alpha: 0.88)
            : NSColor(calibratedWhite: 1.0, alpha: 0.94)
    }
    private var mapPanelBorder: NSColor {
        mapIsDark
            ? NSColor(calibratedWhite: 1, alpha: 0.12)
            : NSColor(calibratedWhite: 0, alpha: 0.12)
    }
    private var mapHUDText: NSColor {
        mapIsDark ? NSColor(calibratedWhite: 0.85, alpha: 1) : NSColor(calibratedWhite: 0.10, alpha: 1)
    }
    private var mapHUDMuted: NSColor {
        // Light: deeper muted greys so captions don't vanish on white panels
        mapIsDark ? NSColor(calibratedWhite: 0.55, alpha: 1) : NSColor(calibratedWhite: 0.32, alpha: 1)
    }

    /// Re-tint scene + HUD when appearance flips; rebuild décor & seat faces.
    private func applyMapTheme() {
        let void = mapVoid
        layer?.backgroundColor = void.cgColor
        scnView.backgroundColor = void
        scene.background.contents = void
        scene.fogColor = void
        // Keep fog off (wash fix)
        scene.fogStartDistance = 0
        scene.fogEndDistance = 0
        scene.fogDensityExponent = 0
        // Lights
        for n in scene.rootNode.childNodes {
            guard let light = n.light else { continue }
            if light.type == .ambient {
                light.color = mapIsDark
                    ? NSColor(calibratedWhite: 0.22, alpha: 1)
                    : NSColor(calibratedWhite: 0.72, alpha: 1)
            } else if light.type == .directional {
                light.color = mapIsDark
                    ? NSColor(calibratedWhite: 0.65, alpha: 1)
                    : NSColor(calibratedWhite: 0.9, alpha: 1)
                light.intensity = mapIsDark ? 450 : 380
            }
        }
        applyHUDTheme()
        sceneLock.lock()
        rebuildDecor()
        faceImageCache.removeAll(keepingCapacity: true)
        // Force edge rebuild with new palette (packets restart once on theme flip — OK)
        for e in edgeNodes.values { e.removeFromParentNode() }
        edgeNodes.removeAll()
        edgeBaseRadius.removeAll()
        edgeSigs.removeAll()
        // Refresh seats (cube faces, wire, links) with new palette
        if !seats.isEmpty {
            layoutSeats()
        }
        sceneLock.unlock()
    }

    private func applyHUDTheme() {
        let fill = mapPanelFill.cgColor
        let border = mapPanelBorder.cgColor
        let muted = mapHUDMuted
        let body = mapHUDText

        for panel in [trackPanel, humanPanel, taskPanel, cronPanel, legendPanel, hoverHUD, editBar] {
            panel.layer?.backgroundColor = fill
            panel.layer?.borderColor = border
        }
        trackTitle.textColor = muted
        trackBody.textColor = body
        humanTitle.textColor = PongTheme.amber
        humanToggle.contentTintColor = muted
        taskTitle.textColor = muted
        taskBody.textColor = body
        cronTitle.textColor = muted
        cronBody.textColor = body
        cronEditBtn.contentTintColor = PongTheme.blue
        hintLabel.textColor = muted
        hoverTitle.textColor = body
        hoverBody.textColor = muted
        // Legend labels recolored in place
        for v in legendPanel.subviews {
            if let t = v as? NSTextField, t.stringValue.contains("YOU") {
                t.textColor = PongTheme.amber
            } else if let t = v as? NSTextField {
                // Keep role colors on orch/agent lines; mute structure labels
                if t.stringValue.contains("Orchestrator") { t.textColor = PongTheme.blue }
                else if t.stringValue.contains("Agent") { t.textColor = PongTheme.magenta }
                else if t.stringValue.contains("Idle") || t.stringValue.contains("Active") {
                    t.textColor = muted
                }
            }
        }
    }

    private func rebuildDecor() {
        decorRoot.childNodes.forEach { $0.removeFromParentNode() }
        buildDotSphere()
        buildLevelLabels()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let hoverMonitor {
            NSEvent.removeMonitor(hoverMonitor)
            self.hoverMonitor = nil
        }
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
        guard window != nil else { return }
        // Fires even while SCNView owns the cursor for orbit
        hoverMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.processHover(with: event)
            self?.updateOrbitCursor()
            return event
        }
        // ⇧ held → open-hand cursor in Orbit (ready to pan)
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.updateOrbitCursor()
            return event
        }
        // Orbit: scroll pans · pinch zooms · ⌥-scroll also zooms (mouse-friendly)
        scnView.handleCameraGesture = { [weak self] event in
            guard let self, self.mapMode == .navigate else { return false }
            if event.type == .magnify {
                guard abs(event.magnification) > 0.0005 else { return false }
                self.markUserInteracting()
                self.zoomTowardPointer(event)
                return true
            }
            // Option + scroll = zoom toward cursor (for mouse wheels / precision)
            if event.modifierFlags.contains(.option) {
                let dy = abs(event.scrollingDeltaY)
                guard dy > 0.1 else { return false }
                self.markUserInteracting()
                self.zoomTowardPointer(event)
                return true
            }
            // Two-finger / wheel scroll in any direction = pan
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            guard abs(dx) > 0.08 || abs(dy) > 0.08 else { return false }
            self.markUserInteracting()
            self.panFromScroll(event)
            return true
        }
        updateTrackingAreas()
        refreshOrbitHint()
    }

    /// Bottom chrome for current map mode (orbit pan hint included).
    private func refreshOrbitHint() {
        guard !isShiftPanning else { return }
        hintLabel.stringValue = {
            switch mapMode {
            case .navigate:
                return "Drag orbit · Scroll or ⇧-drag pan · Pinch zoom · Click cube → card · Architecture… for links"
            case .move:
                return "Move: drag cubes on their deck only (X–Z · height locked) · release to save"
            }
        }()
    }

    /// Open hand while ⇧ is held in Orbit; closed hand while shift-panning.
    private func updateOrbitCursor() {
        guard mapMode == .navigate, let window, window.isKeyWindow else { return }
        let mouse = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(mouse) else { return }
        if isShiftPanning {
            NSCursor.closedHand.set()
        } else if NSEvent.modifierFlags.contains(.shift) {
            NSCursor.openHand.set()
        }
    }

    /// Two-finger / wheel scroll → pan (camera + orbit target together).
    private func panFromScroll(_ event: NSEvent) {
        var dx = Float(event.scrollingDeltaX)
        var dy = Float(event.scrollingDeltaY)
        if !event.hasPreciseScrollingDeltas {
            dx *= 8
            dy *= 8
        }
        // Invert Y so scroll-up moves the view down (iPad-style content pan).
        panCamera(screenDX: dx, screenDY: -dy)
        keepCameraHorizontal()
    }

    /// Screen-space pan: drag/scroll right moves the world right (camera left).
    private func panCamera(screenDX: Float, screenDY: Float) {
        guard #available(macOS 10.13, *), let cam = scnView.pointOfView else { return }
        let ctrl = scnView.defaultCameraController
        ctrl.pointOfView = cam
        let target = SIMD3<Float>(
            Float(ctrl.target.x), Float(ctrl.target.y), Float(ctrl.target.z)
        )
        let dist = max(2.5, simd_length(cam.simdPosition - target))
        let scale = max(0.0035, dist * 0.00105)
        let before = cam.simdPosition
        // Camera-space X right, Y up — invert so grab/drag feels natural
        ctrl.translateInCameraSpaceBy(x: -screenDX * scale, y: -screenDY * scale, z: 0)
        let d = cam.simdPosition - before
        ctrl.target = SCNVector3(
            Float(ctrl.target.x) + d.x,
            Float(ctrl.target.y) + d.y,
            Float(ctrl.target.z) + d.z
        )
        keepCameraHorizontal()
    }

    /// ⇧ + left-drag in Orbit → pan with hand cursor.
    @objc private func handleOrbitShiftPan(_ g: NSPanGestureRecognizer) {
        guard mapMode == .navigate else { return }
        switch g.state {
        case .began:
            isShiftPanning = true
            scnView.allowsCameraControl = false
            NSCursor.closedHand.set()
            hintLabel.stringValue = "Panning · release mouse · ⇧-drag or scroll also pans"
        case .changed:
            let t = g.translation(in: scnView)
            g.setTranslation(.zero, in: scnView)
            panCamera(screenDX: Float(t.x), screenDY: Float(t.y))
        case .ended, .cancelled:
            isShiftPanning = false
            applyCameraMode()
            refreshOrbitHint()
            if NSEvent.modifierFlags.contains(.shift) {
                NSCursor.openHand.set()
            } else {
                NSCursor.arrow.set()
            }
        default:
            break
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
        if gestureRecognizer === orbitShiftPan {
            return mapMode == .navigate && NSEvent.modifierFlags.contains(.shift)
        }
        if gestureRecognizer === movePan {
            if mapMode == .move { return true }
            // Orbit: only steal pan when starting on the cron ruler
            if mapMode == .navigate {
                let p = gestureRecognizer.location(in: scnView)
                return isOverRuler(at: p)
            }
            return false
        }
        return true
    }

    private func isOverRuler(at viewPt: NSPoint) -> Bool {
        let hits = scnView.hitTest(viewPt, options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
        for hit in hits {
            var n: SCNNode? = hit.node
            while let c = n {
                if c.name == "ruler-surface" || c.name == "cron-ruler" || c.name == "ruler-dyn" {
                    return true
                }
                n = c.parent
            }
        }
        let near = scnView.unprojectPoint(SCNVector3(viewPt.x, viewPt.y, 0))
        let far = scnView.unprojectPoint(SCNVector3(viewPt.x, viewPt.y, 1))
        let dy = far.y - near.y
        guard abs(dy) > 1e-5 else { return false }
        let t = (0 - near.y) / dy
        let wx = near.x + (far.x - near.x) * t
        let wz = near.z + (far.z - near.z) * t
        return abs(Float(wx) - rulerX) < rulerW * 1.6 && abs(Float(wz)) < rulerHalf + 1.5
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: NSGestureRecognizer) -> Bool {
        false
    }

    /// Pointer-centered zoom via SceneKit’s camera controller (keeps screen point fixed).
    private func zoomTowardPointer(_ event: NSEvent) {
        guard #available(macOS 10.13, *) else { return }
        guard let cam = scnView.pointOfView else { return }
        let viewPt = scnView.convert(event.locationInWindow, from: nil)
        let viewport = scnView.bounds.size
        guard viewport.width > 1, viewport.height > 1, scnView.bounds.contains(viewPt) else { return }

        // Positive delta → move camera toward the world point under the cursor (zoom in).
        let delta: Float = {
            if event.type == .magnify {
                // Pinch out (positive magnification) → zoom in
                return Float(event.magnification) * 14
            }
            var dy = Float(event.scrollingDeltaY)
            // Natural trackpad: fingers up → positive scrollingDeltaY + inverted flag
            // We want fingers-up / wheel-forward → zoom in.
            if event.isDirectionInvertedFromDevice {
                // natural: keep sign (scroll up → +dy → zoom in with positive dolly)
            } else {
                dy = -dy
            }
            if event.hasPreciseScrollingDeltas {
                return dy * 0.04
            }
            return dy * 0.28
        }()
        guard abs(delta) > 0.0001 else { return }

        let ctrl = scnView.defaultCameraController
        ctrl.pointOfView = cam

        // When pointing at a seat/edge, pull orbit pivot there so zoom + next orbit
        // share the same focus. Empty space: keep current target; dollyBy still
        // holds the pixel under the cursor fixed (no décor-dot hit tests).
        if let solid = scnView.hitTest(viewPt, options: [
            .categoryBitMask: NSNumber(value: Self.hitInteractive),
            .searchMode: SCNHitTestSearchMode.closest.rawValue,
        ]).first {
            ctrl.target = solid.worldCoordinates
        }

        // SceneKit API: zoom while keeping this screen point stable.
        ctrl.dolly(by: delta, onScreenPoint: viewPt, viewport: viewport)
        clampCameraDistance()
    }

    /// Clamp camera distance from orbit target so we don’t clip through or fly away.
    private func clampCameraDistance() {
        guard #available(macOS 10.13, *), let cam = scnView.pointOfView else { return }
        let ctrl = scnView.defaultCameraController
        let target = SIMD3<Float>(
            Float(ctrl.target.x), Float(ctrl.target.y), Float(ctrl.target.z)
        )
        let pos = cam.simdPosition
        var offset = pos - target
        let dist = simd_length(offset)
        guard dist > 1e-4 else { return }
        let minD: Float = 2.5
        let maxD: Float = 75
        if dist < minD {
            offset = simd_normalize(offset) * minD
            cam.simdPosition = target + offset
        } else if dist > maxD {
            offset = simd_normalize(offset) * maxD
            cam.simdPosition = target + offset
        }
        keepCameraHorizontal()
    }

    /// Lock roll so the world stays level — orbit/pan only, no left/right bank.
    private func keepCameraHorizontal() {
        guard let cam = scnView.pointOfView else { return }
        if #available(macOS 10.13, *) {
            scnView.defaultCameraController.clearRoll()
        }
        // Hard zero roll on the camera node (turntable can still drip roll)
        if abs(cam.eulerAngles.z) > 0.0005 {
            cam.eulerAngles.z = 0
        }
        // Keep world-up as the camera’s up vector
        let t = scnView.defaultCameraController.target
        let target = SIMD3<Float>(Float(t.x), Float(t.y), Float(t.z))
        let pos = cam.simdPosition
        let forward = simd_normalize(target - pos)
        let worldUp = SIMD3<Float>(0, 1, 0)
        // If looking nearly straight up/down, skip reorthonormalize
        let align = abs(simd_dot(forward, worldUp))
        guard align < 0.98 else { return }
        let right = simd_normalize(simd_cross(forward, worldUp))
        let up = simd_normalize(simd_cross(right, forward))
        // Build orientation that keeps up = world up projection
        var m = matrix_identity_float4x4
        // SceneKit camera looks down local -Z
        let back = -forward
        m.columns.0 = SIMD4<Float>(right.x, right.y, right.z, 0)
        m.columns.1 = SIMD4<Float>(up.x, up.y, up.z, 0)
        m.columns.2 = SIMD4<Float>(back.x, back.y, back.z, 0)
        m.columns.3 = SIMD4<Float>(pos.x, pos.y, pos.z, 1)
        cam.simdTransform = m
    }

    // MARK: - Scene

    private func setupScene() {
        scnView.translatesAutoresizingMaskIntoConstraints = false
        scnView.scene = scene
        scnView.backgroundColor = NSColor.black
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = false
        // 2X is enough for wire/point décor; 4X was a major GPU cost on dense scenes.
        // MSAA off — major drag/orbit cost; soft edges acceptable for HUD map
        // 2X MSAA smooths thin edge/flow lines without heavy 4X cost
        scnView.antialiasingMode = .multisampling2X
        scnView.delegate = self
        // On-demand render: start paused; advancePulse / gestures re-enable (designer A1)
        scnView.isPlaying = false
        if #available(macOS 10.13, *) { scnView.preferredFramesPerSecond = 24 }
        // Turntable: orbit yaw/pitch, keep horizon level (no free roll / bank)
        if #available(macOS 10.13, *) {
            scnView.defaultCameraController.interactionMode = .orbitTurntable
            scnView.defaultCameraController.inertiaEnabled = true
            scnView.defaultCameraController.maximumVerticalAngle = 85
            scnView.defaultCameraController.minimumVerticalAngle = 5
            scnView.defaultCameraController.clearRoll()
            scnView.defaultCameraController.inertiaEnabled = true
            // Allow looking under the stack (was -10 / 10 → stuck above plane)
            scnView.defaultCameraController.maximumVerticalAngle = 88
            scnView.defaultCameraController.minimumVerticalAngle = -85
        }
        addSubview(scnView)
        NSLayoutConstraint.activate([
            scnView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scnView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scnView.topAnchor.constraint(equalTo: topAnchor),
            scnView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        scene.rootNode.addChildNode(rootNode)
        decorRoot.name = "map-decor"
        rootNode.addChildNode(decorRoot)
        scene.background.contents = mapVoid
        // No distance fog — it greys the stack and can wash to a white haze after orbit.
        scene.fogStartDistance = 0
        scene.fogEndDistance = 0
        scene.fogColor = mapVoid
        scene.fogDensityExponent = 0
        scnView.backgroundColor = mapVoid
        layer?.backgroundColor = mapVoid.cgColor

        // Camera
        let cam = SCNNode()
        cam.name = "camera"
        cam.camera = SCNCamera()
        cam.camera?.zFar = 200
        cam.camera?.zNear = 0.1
        cam.camera?.fieldOfView = 48
        // HDR/bloom OFF for usability — soft YOU light is a mesh, not bloom (perf)
        cam.camera?.wantsHDR = false
        cam.camera?.bloomIntensity = 0
        cam.camera?.bloomThreshold = 1
        cam.camera?.bloomBlurRadius = 0
        // Redesign home: FOV 42, pos (27,19,35), look at origin stack
        cam.camera?.fieldOfView = 42
        cam.position = SCNVector3(27, 19, 35)
        cam.look(at: SCNVector3(0, 0.5, 0))
        scene.rootNode.addChildNode(cam)
        scnView.pointOfView = cam
        if #available(macOS 10.13, *) {
            scnView.defaultCameraController.pointOfView = cam
            scnView.defaultCameraController.target = SCNVector3(0, 0.5, 0)
            scnView.defaultCameraController.automaticTarget = false
            scnView.defaultCameraController.inertiaEnabled = true
            scnView.defaultCameraController.minimumVerticalAngle = -85
            scnView.defaultCameraController.maximumVerticalAngle = 88
        }

        let amb = SCNNode()
        amb.light = SCNLight()
        amb.light?.type = .ambient
        amb.light?.color = NSColor(calibratedWhite: 0.22, alpha: 1)
        scene.rootNode.addChildNode(amb)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.color = NSColor(calibratedWhite: 0.65, alpha: 1)
        key.light?.intensity = 450
        key.eulerAngles = SCNVector3(-0.6, 0.4, 0)
        scene.rootNode.addChildNode(key)

        rebuildDecor()

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        scnView.addGestureRecognizer(click)
        let right = NSClickGestureRecognizer(target: self, action: #selector(handleRightClick(_:)))
        right.buttonMask = 0x2
        scnView.addGestureRecognizer(right)
        // Move-mode only — must not block Orbit camera pans
        movePan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        movePan.buttonMask = 0x1
        movePan.isEnabled = false
        movePan.delegate = self
        scnView.addGestureRecognizer(movePan)
        // Orbit: ⇧ + drag pans without leaving navigate mode
        orbitShiftPan = NSPanGestureRecognizer(target: self, action: #selector(handleOrbitShiftPan(_:)))
        orbitShiftPan.buttonMask = 0x1
        orbitShiftPan.delegate = self
        scnView.addGestureRecognizer(orbitShiftPan)
        scnView.allowsCameraControl = true
    }

    private func setupEditBar() {
        // Mode controls live on the panel canvas toolbar (Orbit / Move / Architecture).
        // Keep a hidden bar only for internal modeButton bookkeeping if needed — no floating chips.
        editBar.isHidden = true
        editBar.translatesAutoresizingMaskIntoConstraints = false
        modeButtons = []
    }

    /// Panel toolbar: Orbit (navigate).
    func setNavigateMode() {
        mapMode = .navigate
        linkSourceGid = nil
        isShiftPanning = false
        applyCameraMode()
        refreshOrbitHint()
    }

    /// Panel toolbar: Move seats on deck.
    func setMoveMode() {
        mapMode = .move
        linkSourceGid = nil
        isShiftPanning = false
        applyCameraMode()
        refreshOrbitHint()
    }

    var isMoveMode: Bool { mapMode == .move }

    /// Panel toolbar: Architecture sheet (same as former map chip).
    func openArchitectureSheet() {
        openFlowDesign()
    }

    @objc private func openFlowDesign() {
        // Prefer the team of the selected/focused seat, else first non-human seat
        let preferred = seats.first(where: { $0.role != "human" })?.session
            ?? PairState.listPairs().first
        guard let preferred else { return }
        FlowDesignSheetController.shared.show(session: preferred, seats: seats) { [weak self] in
            self?.onGraphChanged?()
            guard let self else { return }
            self.reload(seats: self.seats, multiTeam: self.multiTeam)
        }
    }

    @objc private func modePressed(_ sender: NSButton) {
        let id = sender.identifier?.rawValue ?? "navigate"
        if id == "move" { setMoveMode() } else { setNavigateMode() }
        styleModeButtons()
    }

    /// Orbit needs SceneKit camera control and no competing pan gesture.
    private func applyCameraMode() {
        let orbit = (mapMode == .navigate)
        scnView.allowsCameraControl = orbit && !isShiftPanning && rulerDragLastZ == nil
        // Pan enabled in Move (seats) and Orbit (cron ruler scroll)
        movePan?.isEnabled = (mapMode == .move || mapMode == .navigate)
        orbitShiftPan?.isEnabled = orbit
        if #available(macOS 10.13, *), orbit {
            scnView.defaultCameraController.interactionMode = .orbitTurntable
            scnView.defaultCameraController.inertiaEnabled = true
            scnView.defaultCameraController.automaticTarget = false
            if let cam = scnView.pointOfView {
                scnView.defaultCameraController.pointOfView = cam
            }
        }
    }

    private func styleModeButtons() {
        for b in modeButtons {
            let on = (b.identifier?.rawValue == "navigate" && mapMode == .navigate)
                || (b.identifier?.rawValue == "move" && mapMode == .move)
            b.layer?.backgroundColor = (on ? NSColor.white.withAlphaComponent(0.2) : NSColor.clear).cgColor
            b.contentTintColor = .white
            b.attributedTitle = NSAttributedString(string: b.title, attributes: [
                .foregroundColor: NSColor.white,
                .font: PongTheme.labelFont(10),
            ])
        }
    }

    /// Redesign planes: 24×24, accent rim/brackets/grid, faint fill, range ring.
    private func buildDotSphere() {
        let decks: [(y: Float, label: String, idx: String, accent: NSColor)] = [
            (yConductor, "ORCHESTRATOR", "01", PongTheme.blue),
            (yWorker, "AGENTS", "02", PongTheme.magenta),
            (ySub, "SUB-AGENTS", "03", PongTheme.violet),
        ]
        let size = planeSize
        let half = size / 2

        for d in decks {
            // Whisper tint only (design opacity 0.03) — single flat plane, not a double-sided box
            // (6-face box stacked the tint and read as a hot neon plate).
            let plate = SCNPlane(width: CGFloat(size), height: CGFloat(size))
            let pm = SCNMaterial()
            pm.diffuse.contents = d.accent.withAlphaComponent(0.03)
            pm.emission.contents = NSColor.black
            pm.isDoubleSided = false
            pm.writesToDepthBuffer = false
            pm.lightingModel = .constant
            plate.materials = [pm]
            let pn = SCNNode(geometry: plate)
            pn.eulerAngles.x = -.pi / 2
            pn.position = SCNVector3(0, d.y - 0.02, 0)
            pn.name = "deck-\(d.label)"
            pn.categoryBitMask = Self.hitDecor
            pn.renderingOrder = -10
            decorRoot.addChildNode(pn)

            // Rim frame (accent ~0.32)
            addPlaneRim(y: d.y, half: half, accent: d.accent.withAlphaComponent(0.32))
            // Corner brackets
            addCornerBrackets(y: d.y, half: half, accent: d.accent.withAlphaComponent(0.55))
            // Center cross-hair
            addCrossHair(y: d.y, accent: d.accent.withAlphaComponent(0.1))
            // Range ring r=7.5
            addRangeRing(y: d.y, radius: 7.5, accent: d.accent.withAlphaComponent(0.07))

            // 13×13 dotted grid as ONE point-cloud geometry (not 169 SCNSphere nodes).
            let n = 13
            let step = size / Float(n - 1)
            let gridCol = PongTheme.mapGrid
            var pts: [SCNVector3] = []
            pts.reserveCapacity(n * n)
            for ix in 0..<n {
                for iz in 0..<n {
                    let gx = -half + Float(ix) * step
                    let gz = -half + Float(iz) * step
                    let dist = sqrt(gx * gx + gz * gz)
                    let edgeFade = max(0, min(1, 1 - dist / (half * 1.05)))
                    let a = 0.55 * edgeFade
                    guard a > 0.04 else { continue }
                    pts.append(SCNVector3(gx, d.y + 0.01, gz))
                }
            }
            if !pts.isEmpty {
                let cloud = pointCloudGeometry(vertices: pts, pointSize: 2.4)
                let sm = SCNMaterial()
                sm.diffuse.contents = gridCol.withAlphaComponent(0.45)
                sm.emission.contents = NSColor.black // matte dots — no bloom
                sm.lightingModel = .constant
                sm.writesToDepthBuffer = false
                sm.isDoubleSided = true
                cloud.materials = [sm]
                let sn = SCNNode(geometry: cloud)
                sn.name = "plane-dots-\(d.idx)"
                sn.categoryBitMask = Self.hitDecor
                sn.renderingOrder = -9
                decorRoot.addChildNode(sn)
            }

            // Label plate: "01 · ORCHESTRATOR"
            addDeckIndexLabel(y: d.y, half: half, index: d.idx, title: d.label, accent: d.accent)
        }

        // Cron ruler strip (alongside agents plane)
        buildCronRulerBase()

        // Sparse atmosphere as one point cloud (not hundreds of SCNSpheres).
        let R = shellRadius
        var shellPts: [SCNVector3] = []
        for latDeg in stride(from: -55, through: 55, by: 32) {
            let lat = Float(latDeg) * .pi / 180
            let lonStep = max(28, 40 - abs(latDeg) / 5)
            for lonDeg in stride(from: 0, to: 360, by: lonStep) {
                let lon = Float(lonDeg) * .pi / 180
                shellPts.append(SCNVector3(R * cos(lat) * cos(lon), R * sin(lat), R * cos(lat) * sin(lon)))
            }
        }
        if !shellPts.isEmpty {
            let cloud = pointCloudGeometry(vertices: shellPts, pointSize: 1.2)
            let mat = SCNMaterial()
            mat.diffuse.contents = mapInk.withAlphaComponent(0.06)
            mat.lightingModel = .constant
            mat.writesToDepthBuffer = false
            cloud.materials = [mat]
            let shell = SCNNode(geometry: cloud)
            shell.name = "dot-sphere"
            shell.categoryBitMask = Self.hitDecor
            shell.renderingOrder = -20
            decorRoot.addChildNode(shell)
        }
    }

    private func addPlaneRim(y: Float, half: Float, accent: NSColor) {
        let thick: CGFloat = 0.04
        let len = CGFloat(half * 2)
        func bar(_ w: CGFloat, _ l: CGFloat, _ pos: SCNVector3) {
            let b = SCNBox(width: w, height: 0.03, length: l, chamferRadius: 0)
            let m = SCNMaterial()
            m.diffuse.contents = accent
            m.emission.contents = NSColor.black // matte rim
            m.lightingModel = .constant
            m.writesToDepthBuffer = false
            b.materials = [m]
            let n = SCNNode(geometry: b)
            n.position = pos
            n.categoryBitMask = Self.hitDecor
            n.renderingOrder = -8
            decorRoot.addChildNode(n)
        }
        bar(len, thick, SCNVector3(0, y, half))
        bar(len, thick, SCNVector3(0, y, -half))
        bar(thick, len, SCNVector3(half, y, 0))
        bar(thick, len, SCNVector3(-half, y, 0))
    }

    private func addCornerBrackets(y: Float, half: Float, accent: NSColor) {
        let arm: CGFloat = 1.1
        let t: CGFloat = 0.05
        let corners: [(Float, Float)] = [
            (half, half), (half, -half), (-half, half), (-half, -half),
        ]
        for (cx, cz) in corners {
            let sx: Float = cx > 0 ? -1 : 1
            let sz: Float = cz > 0 ? -1 : 1
            for (w, l, ox, oz) in [
                (arm, t, sx * Float(arm) / 2, Float(0)),
                (t, arm, Float(0), sz * Float(arm) / 2),
            ] as [(CGFloat, CGFloat, Float, Float)] {
                let b = SCNBox(width: w, height: 0.04, length: l, chamferRadius: 0)
                let m = SCNMaterial()
                m.diffuse.contents = accent
                m.emission.contents = NSColor.black // matte brackets
                m.lightingModel = .constant
                m.writesToDepthBuffer = false
                b.materials = [m]
                let n = SCNNode(geometry: b)
                n.position = SCNVector3(cx + ox * (cx > 0 ? -1 : 1) * 0, y + 0.02, cz)
                // place arms along edges from corner
                n.position = SCNVector3(
                    cx + (w > l ? ox : 0),
                    y + 0.02,
                    cz + (l > w ? oz : 0)
                )
                n.categoryBitMask = Self.hitDecor
                n.renderingOrder = -7
                decorRoot.addChildNode(n)
            }
        }
    }

    private func addCrossHair(y: Float, accent: NSColor) {
        for (w, l) in [(CGFloat(2.4), CGFloat(0.03)), (CGFloat(0.03), CGFloat(2.4))] {
            let b = SCNBox(width: w, height: 0.02, length: l, chamferRadius: 0)
            let m = SCNMaterial()
            m.diffuse.contents = accent
            m.lightingModel = .constant
            m.writesToDepthBuffer = false
            b.materials = [m]
            let n = SCNNode(geometry: b)
            n.position = SCNVector3(0, y + 0.015, 0)
            n.categoryBitMask = Self.hitDecor
            n.renderingOrder = -8
            decorRoot.addChildNode(n)
        }
    }

    private func addRangeRing(y: Float, radius: Float, accent: NSColor) {
        let ring = SCNTube(innerRadius: CGFloat(radius - 0.04), outerRadius: CGFloat(radius), height: 0.02)
        let m = SCNMaterial()
        m.diffuse.contents = accent
        m.lightingModel = .constant
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        ring.materials = [m]
        let n = SCNNode(geometry: ring)
        n.position = SCNVector3(0, y + 0.01, 0)
        n.categoryBitMask = Self.hitDecor
        n.renderingOrder = -8
        decorRoot.addChildNode(n)
    }

    private func addDeckIndexLabel(y: Float, half: Float, index: String, title: String, accent: NSColor) {
        let texW: CGFloat = 720
        let texH: CGFloat = 96
        let img = NSImage(size: NSSize(width: texW, height: texH))
        img.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: texW, height: texH).fill()
        let idxAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 42, weight: .semibold),
            .foregroundColor: accent.withAlphaComponent(0.9),
        ]
        let titleAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 36, weight: .semibold),
            .foregroundColor: mapInk.withAlphaComponent(0.55),
            .kern: 4,
        ]
        let line = "\(index)  ·  \(title)" as NSString
        // Draw index in accent, rest muted — single string for simplicity
        let fullAttr: [NSAttributedString.Key: Any] = [
            .font: PongTheme.mono(40, weight: .semibold),
            .foregroundColor: accent.withAlphaComponent(0.75),
            .kern: 3,
        ]
        let sz = line.size(withAttributes: fullAttr)
        line.draw(at: NSPoint(x: 12, y: (texH - sz.height) / 2), withAttributes: fullAttr)
        // suppress unused
        _ = idxAttr; _ = titleAttr
        img.unlockFocus()

        let plane = SCNPlane(width: 7.2, height: 0.95)
        let mat = SCNMaterial()
        mat.diffuse.contents = img
        mat.emission.contents = NSColor.black
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        mat.writesToDepthBuffer = false
        // Prototype: upright HUD tab (not flat on floor / not near-invisible)
        mat.transparency = 1.0
        plane.materials = [mat]
        let tn = SCNNode(geometry: plane)
        tn.position = SCNVector3(half - 4.2, y + 0.55, -half + 1.1)
        tn.constraints = [SCNBillboardConstraint()]
        tn.name = "deck-label-\(title)"
        tn.categoryBitMask = Self.hitDecor
        tn.renderingOrder = -4
        decorRoot.addChildNode(tn)
    }

    /// Legacy name — labels now built in buildDotSphere.
    private func buildLevelLabels() {}

    // MARK: - HUD

    private func setupHUD() {
        hoverHUD.wantsLayer = true
        hoverHUD.layer?.backgroundColor = NSColor(calibratedWhite: 0.05, alpha: 0.92).cgColor
        hoverHUD.layer?.cornerRadius = 8
        hoverHUD.layer?.borderWidth = 1
        hoverHUD.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.18).cgColor
        hoverHUD.isHidden = true
        hoverHUD.frame = NSRect(x: 20, y: 20, width: 280, height: 110)
        addSubview(hoverHUD)

        hoverTitle.font = PongTheme.font(14, weight: .semibold)
        hoverTitle.textColor = .white
        hoverTitle.isBordered = false
        hoverTitle.drawsBackground = false
        hoverTitle.frame = NSRect(x: 14, y: 78, width: 250, height: 20)
        hoverHUD.addSubview(hoverTitle)

        hoverStatus.font = PongTheme.labelFont(10)
        hoverStatus.isBordered = false
        hoverStatus.drawsBackground = false
        hoverStatus.frame = NSRect(x: 14, y: 60, width: 250, height: 14)
        hoverHUD.addSubview(hoverStatus)

        hoverBody.font = PongTheme.font(11)
        hoverBody.textColor = NSColor(calibratedWhite: 0.65, alpha: 1)
        hoverBody.isBordered = false
        hoverBody.drawsBackground = false
        hoverBody.maximumNumberOfLines = 3
        hoverBody.frame = NSRect(x: 14, y: 12, width: 250, height: 44)
        hoverHUD.addSubview(hoverBody)
    }

    /// Height of the map chrome strip under the panel toolbar (hint line only).
    /// Panel lays out toolbar just above this; keep tight so map gains space.
    static let hintStripHeight: CGFloat = 14

    private func setupHint() {
        hintLabel.font = PongTheme.labelFont(10)
        hintLabel.textColor = NSColor(calibratedWhite: 0.5, alpha: 1)
        hintLabel.isBordered = false
        hintLabel.drawsBackground = false
        hintLabel.alignment = .center
        hintLabel.lineBreakMode = .byTruncatingTail
        // Frame-laid in layout() — sits under the floating toolbar (no -124 dead zone)
        hintLabel.translatesAutoresizingMaskIntoConstraints = true
        addSubview(hintLabel)
        refreshOrbitHint()
    }

    private func layoutHintStrip() {
        let h = Self.hintStripHeight
        let inset: CGFloat = 10
        hintLabel.frame = NSRect(
            x: inset,
            y: 2,
            width: max(40, bounds.width - inset * 2),
            height: h
        )
        // Keep on top of SceneKit
        addSubview(hintLabel)
    }

    /// Left column scroller so TRACKING / YOU / CRON / TASKS remain reachable in a short window.
    private func setupLeftHUDScroll() {
        leftHUDScroll.translatesAutoresizingMaskIntoConstraints = false
        leftHUDScroll.drawsBackground = false
        leftHUDScroll.backgroundColor = .clear
        leftHUDScroll.hasVerticalScroller = true
        leftHUDScroll.hasHorizontalScroller = false
        leftHUDScroll.autohidesScrollers = true
        leftHUDScroll.scrollerStyle = .overlay
        leftHUDScroll.borderType = .noBorder
        leftHUDScroll.scrollerKnobStyle = .light
        // Clip only the scroll viewport; panels keep their own corner radii
        leftHUDScroll.contentView.wantsLayer = true
        leftHUDScroll.wantsLayer = true
        leftHUDScroll.layer?.backgroundColor = NSColor.clear.cgColor

        leftHUDStack.translatesAutoresizingMaskIntoConstraints = false
        leftHUDStack.wantsLayer = true
        leftHUDScroll.documentView = leftHUDStack
        addSubview(leftHUDScroll)

        leftHUDScrollW = leftHUDScroll.widthAnchor.constraint(equalToConstant: leftHUDColW + 20)
        leftHUDStackW = leftHUDStack.widthAnchor.constraint(equalToConstant: leftHUDColW)
        NSLayoutConstraint.activate([
            leftHUDScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            leftHUDScroll.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            // Clear edit bar + hint along the bottom
            leftHUDScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -130),
            leftHUDScrollW!,
            leftHUDStack.leadingAnchor.constraint(equalTo: leftHUDScroll.contentView.leadingAnchor, constant: 6),
            leftHUDStack.topAnchor.constraint(equalTo: leftHUDScroll.contentView.topAnchor, constant: 4),
            leftHUDStackW!,
        ])

        // Horizontal splitter on outer edge of left HUD (16pt hit · mouse-driven drag)
        leftHUDSplitter.translatesAutoresizingMaskIntoConstraints = false
        addSubview(leftHUDSplitter)
        leftHUDSplitterW = leftHUDSplitter.widthAnchor.constraint(equalToConstant: Self.leftHUDSplitterHitW)
        // Overlap ~6pt into the scroll so the grip sits on the column’s right edge
        NSLayoutConstraint.activate([
            leftHUDSplitter.leadingAnchor.constraint(equalTo: leftHUDScroll.trailingAnchor, constant: -6),
            leftHUDSplitter.topAnchor.constraint(equalTo: leftHUDScroll.topAnchor),
            leftHUDSplitter.bottomAnchor.constraint(equalTo: leftHUDScroll.bottomAnchor),
            leftHUDSplitterW!,
        ])
        wireLeftHUDSplitter()
        raiseLeftHUDChrome()
    }

    private func wireLeftHUDSplitter() {
        leftHUDSplitter.onDragBegan = { [weak self] in
            guard let self else { return }
            // Ensure strip is above SceneKit / map chrome for the whole drag
            self.raiseLeftHUDChrome()
        }
        leftHUDSplitter.onDragDelta = { [weak self] dx in
            guard let self else { return }
            self.setLeftHUDWidth(self.leftHUDColW + dx)
        }
        leftHUDSplitter.onDragEnded = { [weak self] in
            self?.persistHUDPrefs()
        }
        leftHUDSplitter.onDoubleClickReset = { [weak self] in
            guard let self else { return }
            self.setLeftHUDWidth(Self.leftHUDDefaultColW)
            self.persistHUDPrefs()
        }
    }

    /// Keep left column + splitter above scnView / siblings after every layout or promote.
    private func raiseLeftHUDChrome() {
        guard let host = leftHUDScroll.superview else { return }
        host.addSubview(leftHUDScroll, positioned: .above, relativeTo: nil)
        host.addSubview(leftHUDSplitter, positioned: .above, relativeTo: leftHUDScroll)
        if legendPanel.superview === host {
            host.addSubview(legendPanel, positioned: .above, relativeTo: nil)
        }
    }

    /// Hit-test helper for canvasPage: return splitter when point is on the strip (host coords).
    func hitTestLeftHUDSplitter(in host: NSView, point: NSPoint) -> NSView? {
        guard leftHUDSplitter.superview === host, !leftHUDSplitter.isHidden else { return nil }
        let local = leftHUDSplitter.convert(point, from: host)
        // Slightly expand hit for easier grab
        if leftHUDSplitter.bounds.insetBy(dx: -2, dy: 0).contains(local) {
            return leftHUDSplitter
        }
        return nil
    }

    /// Prefer splitter over SceneKit when still parented here (pure 3D / pre-promote).
    override func hitTest(_ point: NSPoint) -> NSView? {
        if leftHUDSplitter.superview === self, !leftHUDSplitter.isHidden {
            let p = leftHUDSplitter.convert(point, from: self)
            if leftHUDSplitter.bounds.insetBy(dx: -2, dy: 0).contains(p) {
                return leftHUDSplitter
            }
        }
        if leftHUDScroll.superview === self, !leftHUDScroll.isHidden {
            let p = leftHUDScroll.convert(point, from: self)
            if leftHUDScroll.bounds.contains(p), let hit = leftHUDScroll.hitTest(p) {
                return hit
            }
        }
        return super.hitTest(point)
    }

    private func setLeftHUDWidth(_ w: CGFloat) {
        let hostW = (leftHUDScroll.superview ?? self).bounds.width
        let maxW = min(520, max(200, hostW * 0.50))
        leftHUDColW = min(maxW, max(180, w))
        leftHUDScrollW?.constant = leftHUDColW + 20
        leftHUDStackW?.constant = leftHUDColW
        for c in leftHUDPanelWidthConstraints { c.constant = leftHUDColW }
        // Keep promoted fixed-width constraints in sync if present
        if hudPromoted, let host = leftHUDScroll.superview {
            for c in host.constraints where c.firstItem as? NSView === leftHUDScroll && c.firstAttribute == .width {
                c.constant = leftHUDColW + 20
            }
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        leftHUDScroll.superview?.layoutSubtreeIfNeeded()
        raiseLeftHUDChrome()
    }

    private func persistHUDPrefs() {
        var prefs = Pong.loadJSON(Pong.stateDir + "/ui-prefs.json")
        prefs["left_hud_width"] = Double(leftHUDColW)
        prefs["human_panel_height"] = Double(humanPreferredHeight)
        prefs["updated"] = Date().timeIntervalSince1970
        Pong.writeJSON(Pong.stateDir + "/ui-prefs.json", prefs)
    }

    /// Re-tint human chrome after appearance flip.
    func applyChromeTheme() {
        PongTheme.stylePopUp(humanOrchPop)
        humanPanel.layer?.backgroundColor = mapPanelFill.cgColor
        humanPanelBaseBorder = mapPanelBorder.cgColor
        humanPanel.layer?.borderColor = humanPanelBaseBorder
    }

    /// PanelController top-bar team selection → lock human console target.
    func setFocusedTeamSession(_ session: String?) {
        focusedTeamSession = session
        if let s = session, s != "__all__", !s.isEmpty {
            lastSingleTeamFocus = s
            humanSession = s
        } else if session == "__all__" {
            // Prefer last single-team focus in the picker
            if let last = lastSingleTeamFocus, PairState.listPairs().contains(last) {
                humanSession = last
            }
        }
        applyHumanFocusLock()
        reloadHumanOrchPicker()
        if !humanSession.isEmpty {
            selectHumanOrch(session: humanSession)
        }
        reloadHumanInbox()
    }

    private func applyHumanFocusLock() {
        let single: String? = {
            guard let s = focusedTeamSession, s != "__all__", !s.isEmpty else { return nil }
            return s
        }()
        let allMode = focusedTeamSession == "__all__" || focusedTeamSession == nil
        if let s = single {
            humanSession = s
            humanOrchPop.isEnabled = false
            humanOrchPop.isHidden = true
            humanLockLabel.isHidden = !humanExpanded
            humanAllBanner.isHidden = true
            let name = teamDisplayName(for: s)
            humanLockLabel.stringValue = "→ \(name)  (locked to focused team)"
            humanTitle.stringValue = "YOU · \(name)"
        } else {
            humanOrchPop.isEnabled = true
            humanOrchPop.isHidden = !humanExpanded
            humanLockLabel.isHidden = true
            if allMode && humanExpanded {
                let name = teamDisplayName(for: humanSession)
                humanAllBanner.isHidden = false
                humanAllBanner.stringValue = "⚠ All teams · Sending to: \(name.isEmpty ? "—" : name)"
            } else {
                humanAllBanner.isHidden = true
            }
            let name = teamDisplayName(for: humanSession)
            humanTitle.stringValue = name.isEmpty ? "YOU · HUMAN" : "YOU · \(name)"
        }
    }

    /// Resolve session for send/ask; hard-refuses cross-team when single-focused.
    private func resolvedSendSession() -> String? {
        if let focus = focusedTeamSession, focus != "__all__", !focus.isEmpty {
            if !humanSession.isEmpty, humanSession != focus {
                Pong.log("human send refused: session=\(humanSession) focus=\(focus)")
                humanAllBanner.isHidden = false
                humanAllBanner.stringValue = "Blocked: focused team is \(teamDisplayName(for: focus))"
                return nil
            }
            return focus
        }
        if let s = humanOrchPop.selectedItem?.representedObject as? String, !s.isEmpty {
            humanSession = s
            return s
        }
        return humanSession.isEmpty ? nil : humanSession
    }

    /// Pin stack bottom after all left panels exist so document height grows with content.
    private func finalizeLeftHUDStack() {
        NSLayoutConstraint.activate([
            taskPanel.bottomAnchor.constraint(equalTo: leftHUDStack.bottomAnchor, constant: -8),
        ])
    }

    /// Phase 0 parity: re-parent left HUD + right ops rail onto `canvasPage`
    /// so 2D and 3D share one HUD. Call once after both maps are in the tree.
    private var hudPromoted = false
    func promoteSharedHUD(to host: NSView) {
        guard !hudPromoted else {
            layoutPromotedHUD(in: host.bounds)
            return
        }
        hudPromoted = true
        leftHUDScroll.removeFromSuperview()
        leftHUDSplitter.removeFromSuperview()
        legendPanel.removeFromSuperview()
        host.addSubview(leftHUDScroll)
        host.addSubview(leftHUDSplitter)
        host.addSubview(legendPanel)
        leftHUDScroll.translatesAutoresizingMaskIntoConstraints = false
        leftHUDSplitter.translatesAutoresizingMaskIntoConstraints = false
        // Re-pin to host; keep width constraint object so setLeftHUDWidth still works
        leftHUDScrollW?.isActive = false
        leftHUDScrollW = leftHUDScroll.widthAnchor.constraint(equalToConstant: leftHUDColW + 20)
        leftHUDSplitterW?.isActive = false
        leftHUDSplitterW = leftHUDSplitter.widthAnchor.constraint(equalToConstant: Self.leftHUDSplitterHitW)
        NSLayoutConstraint.activate([
            leftHUDScroll.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 8),
            leftHUDScroll.topAnchor.constraint(equalTo: host.topAnchor, constant: 8),
            leftHUDScroll.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -100),
            leftHUDScrollW!,
            leftHUDSplitter.leadingAnchor.constraint(equalTo: leftHUDScroll.trailingAnchor, constant: -6),
            leftHUDSplitter.topAnchor.constraint(equalTo: leftHUDScroll.topAnchor),
            leftHUDSplitter.bottomAnchor.constraint(equalTo: leftHUDScroll.bottomAnchor),
            leftHUDSplitterW!,
        ])
        raiseLeftHUDChrome()
        layoutPromotedHUD(in: host.bounds)
        Pong.log("Agent3DMapView: shared HUD promoted to canvasPage")
    }

    func layoutPromotedHUD(in hostBounds: NSRect) {
        guard hudPromoted else { return }
        layoutRightHUD(in: hostBounds)
        raiseLeftHUDChrome()
    }

    /// TRACKING views only — panel is merged into the right ops rail (legendPanel).
    private func setupTrackingPanel() {
        trackTitle.font = PongTheme.labelFont(10)
        trackTitle.textColor = NSColor(calibratedWhite: 0.7, alpha: 1)
        trackTitle.isBordered = false
        trackTitle.drawsBackground = false
        trackTitle.stringValue = "TRACKING"
        trackBody.font = PongTheme.mono(9)
        trackBody.textColor = NSColor(calibratedWhite: 0.85, alpha: 1)
        trackBody.isBordered = false
        trackBody.drawsBackground = false
        trackBody.maximumNumberOfLines = 20
        trackBody.lineBreakMode = .byWordWrapping
        // Not on left stack — lives inside right ops rail
    }

    /// YOU chat on left stack (TRACKING moved to right).
    private func setupHumanPanel() {
        humanPanel.wantsLayer = true
        humanPanel.layer?.backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 0.88).cgColor
        humanPanel.layer?.cornerRadius = 6
        humanPanel.layer?.borderWidth = 1
        humanPanel.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.12).cgColor
        humanPanelBaseBorder = humanPanel.layer?.borderColor
        humanPanel.translatesAutoresizingMaskIntoConstraints = false
        humanPanel.toolTip = "Drop any files here to attach paths for the orchestrator"
        humanPanel.onHighlight = { [weak self] on in
            guard let self else { return }
            if on {
                self.humanPanel.layer?.borderColor = PongTheme.amber.cgColor
                self.humanPanel.layer?.borderWidth = 2
            } else {
                self.humanPanel.layer?.borderColor = self.humanPanelBaseBorder
                    ?? NSColor(calibratedWhite: 1, alpha: 0.12).cgColor
                self.humanPanel.layer?.borderWidth = 1
            }
        }
        humanPanel.onPaths = { [weak self] paths in
            self?.stageHumanFiles(paths)
        }
        leftHUDStack.addSubview(humanPanel)

        humanTitle.font = PongTheme.labelFont(10)
        humanTitle.textColor = PongTheme.amber
        humanTitle.isBordered = false
        humanTitle.drawsBackground = false
        humanTitle.translatesAutoresizingMaskIntoConstraints = false
        humanPanel.addSubview(humanTitle)

        // Top-right chevron: expand / collapse (never removes the panel)
        humanToggle.title = "▾"
        humanToggle.bezelStyle = .inline
        humanToggle.isBordered = false
        humanToggle.font = PongTheme.font(13, weight: .semibold)
        humanToggle.contentTintColor = NSColor(calibratedWhite: 0.65, alpha: 1)
        humanToggle.target = self
        humanToggle.action = #selector(toggleHumanExpand)
        humanToggle.toolTip = "Collapse / expand"
        humanToggle.translatesAutoresizingMaskIntoConstraints = false
        humanPanel.addSubview(humanToggle)

        humanOrchPop.font = PongTheme.labelFont(10)
        humanOrchPop.target = self
        humanOrchPop.action = #selector(humanOrchChanged)
        humanOrchPop.toolTip = "Which orchestrator receives your prompt (All teams mode only)"
        humanOrchPop.translatesAutoresizingMaskIntoConstraints = false
        PongTheme.stylePopUp(humanOrchPop)
        humanPanel.addSubview(humanOrchPop)

        humanLockLabel.font = PongTheme.labelFont(9)
        humanLockLabel.textColor = PongSheetChrome.lime
        humanLockLabel.isBordered = false
        humanLockLabel.drawsBackground = false
        humanLockLabel.isHidden = true
        humanLockLabel.translatesAutoresizingMaskIntoConstraints = false
        humanPanel.addSubview(humanLockLabel)

        humanAllBanner.font = PongTheme.labelFont(9)
        humanAllBanner.textColor = PongTheme.amber
        humanAllBanner.isBordered = false
        humanAllBanner.drawsBackground = false
        humanAllBanner.isHidden = true
        humanAllBanner.translatesAutoresizingMaskIntoConstraints = false
        humanPanel.addSubview(humanAllBanner)

        // Interactive card stream (primary chat UI)
        humanChatStream.translatesAutoresizingMaskIntoConstraints = false
        humanChatStream.onDecision = { [weak self] d in self?.humanRespondAsk(d) }
        humanChatStream.onReplyFocus = { [weak self] in
            self?.window?.makeFirstResponder(self?.humanInput)
        }
        humanChatStream.onJobTap = { [weak self] jid in self?.humanTapJob(jid) }
        humanChatStream.onSeatTap = { [weak self] sid in self?.humanTapSeat(sid) }
        humanChatStream.onFileTap = { path in
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        humanPanel.addSubview(humanChatStream)

        // Legacy ask row kept off-screen/hidden — decisions live on stream cards
        humanAskRow.isHidden = true
        humanAskRow.translatesAutoresizingMaskIntoConstraints = false
        humanPanel.addSubview(humanAskRow)
        humanAskLabel.isHidden = true
        humanDenyBtn.isHidden = true
        humanAcceptOnceBtn.isHidden = true
        humanAlwaysBtn.isHidden = true

        humanAttachLabel.font = PongTheme.labelFont(9)
        humanAttachLabel.textColor = PongTheme.amber
        humanAttachLabel.isBordered = false
        humanAttachLabel.drawsBackground = false
        humanAttachLabel.isHidden = true
        humanAttachLabel.lineBreakMode = .byTruncatingMiddle
        humanAttachLabel.translatesAutoresizingMaskIntoConstraints = false
        humanAttachLabel.toolTip = "Click to clear staged files"
        humanPanel.addSubview(humanAttachLabel)

        humanInput.font = PongTheme.font(11)
        humanInput.placeholderString = "Reply to orchestrator…"
        humanInput.isBordered = true
        humanInput.bezelStyle = .roundedBezel
        humanInput.focusRingType = .none
        humanInput.translatesAutoresizingMaskIntoConstraints = false
        humanInput.target = self
        humanInput.action = #selector(sendHumanChat)
        if let cell = humanInput.cell as? NSTextFieldCell {
            cell.wraps = true
            cell.isScrollable = false
            cell.usesSingleLineMode = false
        }
        humanInput.maximumNumberOfLines = 6
        humanInput.lineBreakMode = .byWordWrapping
        humanPanel.addSubview(humanInput)

        // Vertical resize grip on **bottom** edge of human panel
        humanVResizeGrip.wantsLayer = true
        humanVResizeGrip.layer?.backgroundColor = PongTheme.lineSoft.withAlphaComponent(0.55).cgColor
        humanVResizeGrip.layer?.cornerRadius = 1
        humanVResizeGrip.translatesAutoresizingMaskIntoConstraints = false
        humanVResizeGrip.toolTip = "Drag bottom edge to resize height"
        humanPanel.addSubview(humanVResizeGrip)
        let vPan = NSPanGestureRecognizer(target: self, action: #selector(humanVResizePan(_:)))
        humanVResizeGrip.addGestureRecognizer(vPan)

        humanSend.title = "Send"
        humanSend.bezelStyle = .inline
        humanSend.isBordered = false
        humanSend.wantsLayer = true
        humanSend.layer?.cornerRadius = 4
        humanSend.layer?.backgroundColor = NSColor(calibratedWhite: 0.15, alpha: 1).cgColor
        humanSend.font = PongTheme.labelFont(10)
        humanSend.contentTintColor = .white
        humanSend.target = self
        humanSend.action = #selector(sendHumanChat)
        humanSend.translatesAutoresizingMaskIntoConstraints = false
        humanPanel.addSubview(humanSend)

        humanClear.title = "Clear"
        humanClear.bezelStyle = .inline
        humanClear.isBordered = false
        humanClear.font = PongTheme.labelFont(9)
        humanClear.contentTintColor = PongTheme.textTertiary
        humanClear.toolTip = "Clear chat history for this team only"
        humanClear.target = self
        humanClear.action = #selector(clearHumanHistory)
        humanClear.translatesAutoresizingMaskIntoConstraints = false
        humanPanel.addSubview(humanClear)

        humanGrow.title = "↕"
        humanGrow.bezelStyle = .inline
        humanGrow.isBordered = false
        humanGrow.font = PongTheme.font(11, weight: .medium)
        humanGrow.contentTintColor = PongTheme.textSecondary
        humanGrow.toolTip = "Snap taller / shorter"
        humanGrow.target = self
        humanGrow.action = #selector(toggleHumanTall)
        humanGrow.translatesAutoresizingMaskIntoConstraints = false
        humanPanel.addSubview(humanGrow)

        humanInput.placeholderString = "Reply to orchestrator…"

        humanPanelHeight = humanPanel.heightAnchor.constraint(equalToConstant: humanPreferredHeight)
        humanAskRowHeight = humanAskRow.heightAnchor.constraint(equalToConstant: 0)
        humanChatStreamHeight = humanChatStream.heightAnchor.constraint(greaterThanOrEqualToConstant: 72)
        humanInputHeight = humanInput.heightAnchor.constraint(equalToConstant: 48)
        let humanW = humanPanel.widthAnchor.constraint(equalToConstant: leftHUDColW)
        leftHUDPanelWidthConstraints.append(humanW)
        NSLayoutConstraint.activate([
            humanPanel.leadingAnchor.constraint(equalTo: leftHUDStack.leadingAnchor),
            humanPanel.topAnchor.constraint(equalTo: leftHUDStack.topAnchor, constant: 4),
            humanW,
            humanPanelHeight!,
            // Title at top (grip is on bottom edge)
            humanTitle.leadingAnchor.constraint(equalTo: humanPanel.leadingAnchor, constant: 12),
            humanTitle.topAnchor.constraint(equalTo: humanPanel.topAnchor, constant: 10),
            humanTitle.trailingAnchor.constraint(lessThanOrEqualTo: humanGrow.leadingAnchor, constant: -4),
            humanGrow.trailingAnchor.constraint(equalTo: humanClear.leadingAnchor, constant: -2),
            humanGrow.centerYAnchor.constraint(equalTo: humanTitle.centerYAnchor),
            humanGrow.widthAnchor.constraint(equalToConstant: 22),
            humanClear.trailingAnchor.constraint(equalTo: humanToggle.leadingAnchor, constant: -2),
            humanClear.centerYAnchor.constraint(equalTo: humanTitle.centerYAnchor),
            humanToggle.trailingAnchor.constraint(equalTo: humanPanel.trailingAnchor, constant: -8),
            humanToggle.centerYAnchor.constraint(equalTo: humanTitle.centerYAnchor),
            humanToggle.widthAnchor.constraint(equalToConstant: 22),
            humanToggle.heightAnchor.constraint(equalToConstant: 20),
            humanLockLabel.leadingAnchor.constraint(equalTo: humanPanel.leadingAnchor, constant: 10),
            humanLockLabel.trailingAnchor.constraint(equalTo: humanPanel.trailingAnchor, constant: -10),
            humanLockLabel.topAnchor.constraint(equalTo: humanTitle.bottomAnchor, constant: 4),
            humanLockLabel.heightAnchor.constraint(equalToConstant: 16),
            humanOrchPop.leadingAnchor.constraint(equalTo: humanPanel.leadingAnchor, constant: 10),
            humanOrchPop.trailingAnchor.constraint(equalTo: humanPanel.trailingAnchor, constant: -10),
            humanOrchPop.topAnchor.constraint(equalTo: humanTitle.bottomAnchor, constant: 4),
            humanOrchPop.heightAnchor.constraint(equalToConstant: 24),
            humanAllBanner.leadingAnchor.constraint(equalTo: humanPanel.leadingAnchor, constant: 10),
            humanAllBanner.trailingAnchor.constraint(equalTo: humanPanel.trailingAnchor, constant: -10),
            humanAllBanner.topAnchor.constraint(equalTo: humanOrchPop.bottomAnchor, constant: 2),
            humanAllBanner.heightAnchor.constraint(equalToConstant: 16),
            humanChatStream.leadingAnchor.constraint(equalTo: humanPanel.leadingAnchor, constant: 8),
            humanChatStream.trailingAnchor.constraint(equalTo: humanPanel.trailingAnchor, constant: -8),
            humanChatStream.topAnchor.constraint(equalTo: humanAllBanner.bottomAnchor, constant: 4),
            humanChatStreamHeight!,
            // Legacy ask row collapsed
            humanAskRow.leadingAnchor.constraint(equalTo: humanPanel.leadingAnchor, constant: 8),
            humanAskRow.trailingAnchor.constraint(equalTo: humanPanel.trailingAnchor, constant: -8),
            humanAskRow.topAnchor.constraint(equalTo: humanChatStream.bottomAnchor, constant: 0),
            humanAskRowHeight!,
            humanAskRow.bottomAnchor.constraint(equalTo: humanAttachLabel.topAnchor, constant: -4),
            humanAttachLabel.leadingAnchor.constraint(equalTo: humanPanel.leadingAnchor, constant: 12),
            humanAttachLabel.trailingAnchor.constraint(equalTo: humanPanel.trailingAnchor, constant: -12),
            humanAttachLabel.heightAnchor.constraint(equalToConstant: 14),
            humanAttachLabel.bottomAnchor.constraint(equalTo: humanInput.topAnchor, constant: -4),
            humanInput.leadingAnchor.constraint(equalTo: humanPanel.leadingAnchor, constant: 10),
            // Input sits above bottom resize grip
            humanInput.bottomAnchor.constraint(equalTo: humanVResizeGrip.topAnchor, constant: -6),
            humanInputHeight!,
            humanSend.leadingAnchor.constraint(equalTo: humanInput.trailingAnchor, constant: 6),
            humanSend.trailingAnchor.constraint(equalTo: humanPanel.trailingAnchor, constant: -10),
            humanSend.bottomAnchor.constraint(equalTo: humanInput.bottomAnchor),
            humanSend.widthAnchor.constraint(equalToConstant: 44),
            humanSend.heightAnchor.constraint(equalToConstant: 28),
            humanInput.trailingAnchor.constraint(equalTo: humanSend.leadingAnchor, constant: -6),
            // Bottom-edge height grip (standard resize chrome)
            humanVResizeGrip.leadingAnchor.constraint(equalTo: humanPanel.leadingAnchor),
            humanVResizeGrip.trailingAnchor.constraint(equalTo: humanPanel.trailingAnchor),
            humanVResizeGrip.bottomAnchor.constraint(equalTo: humanPanel.bottomAnchor),
            humanVResizeGrip.heightAnchor.constraint(equalToConstant: 6),
        ])
        // Click attach label to clear staged files
        let clearClick = NSClickGestureRecognizer(target: self, action: #selector(clearHumanAttachments))
        humanAttachLabel.addGestureRecognizer(clearClick)
        refreshHumanDock()
        reloadHumanOrchPicker()
        applyHumanFocusLock()
    }

    @objc private func humanVResizePan(_ g: NSPanGestureRecognizer) {
        switch g.state {
        case .began:
            humanVResizeStartY = g.location(in: self).y
            humanVResizeStartH = humanPreferredHeight
            humanExpanded = true
        case .changed:
            // Flipped: drag up (higher y in window coords often down in view) — use delta
            let dy = g.location(in: self).y - humanVResizeStartY
            // In AppKit default coords, y grows up; dragging grip down increases height
            let maxH = max(200, bounds.height * 0.7)
            humanPreferredHeight = min(maxH, max(160, humanVResizeStartH - dy))
            applyHumanPanelSize()
        case .ended, .cancelled:
            persistHUDPrefs()
        default: break
        }
    }

    private func stageHumanFiles(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        var seen = Set(humanPendingFiles)
        for p in paths {
            let t = p.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !seen.contains(t) else { continue }
            seen.insert(t)
            humanPendingFiles.append(t)
        }
        // Cap staged list
        if humanPendingFiles.count > 40 {
            humanPendingFiles = Array(humanPendingFiles.suffix(40))
        }
        updateHumanAttachLabel()
        if !humanExpanded {
            humanExpanded = true
            refreshHumanDock()
        }
        Pong.log("human panel staged files n=\(humanPendingFiles.count)")
    }

    private func updateHumanAttachLabel() {
        if humanPendingFiles.isEmpty {
            humanAttachLabel.isHidden = true
            humanAttachLabel.stringValue = ""
            return
        }
        humanAttachLabel.isHidden = false
        let n = humanPendingFiles.count
        let preview = humanPendingFiles.prefix(2).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        let more = n > 2 ? " +\(n - 2)" : ""
        humanAttachLabel.stringValue = "📎 \(n) file\(n == 1 ? "" : "s"): \(preview)\(more)  · click to clear"
    }

    @objc private func clearHumanAttachments() {
        humanPendingFiles.removeAll()
        updateHumanAttachLabel()
    }

    @objc private func toggleHumanTall() {
        humanTall.toggle()
        // Snap presets still available via ↕
        humanPreferredHeight = humanTall ? min(bounds.height * 0.65, 480) : 280
        applyHumanPanelSize()
        persistHUDPrefs()
    }

    @objc private func clearHumanHistory() {
        guard let session = resolvedSendSession() else { return }
        HumanConsoleController.clearHistory(session: session)
        reloadHumanInbox()
    }

    private func applyHumanPanelSize() {
        guard humanExpanded else { return }
        var h = humanPreferredHeight
        let maxH = max(200, bounds.height * 0.7)
        h = min(maxH, max(160, h))
        humanPreferredHeight = h
        humanPanelHeight?.constant = h
        // Input grows with panel (~18–28% of body)
        let inputH = max(36, min(140, h * 0.22))
        humanInputHeight?.constant = inputH
        let chrome: CGFloat = 100 + (humanAllBanner.isHidden ? 0 : 18)
        humanChatStreamHeight?.constant = max(72, h - chrome - inputH)
        humanPanel.needsLayout = true
        leftHUDStack.layoutSubtreeIfNeeded()
        leftHUDScroll.reflectScrolledClipView(leftHUDScroll.contentView)
    }

    /// Per-agent work recap under YOU — not generic status events.
    private func setupTaskPanel() {
        taskPanel.wantsLayer = true
        taskPanel.layer?.backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 0.88).cgColor
        taskPanel.layer?.cornerRadius = 6
        taskPanel.layer?.borderWidth = 1
        taskPanel.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.12).cgColor
        taskPanel.translatesAutoresizingMaskIntoConstraints = false
        leftHUDStack.addSubview(taskPanel)

        taskTitle.font = PongTheme.labelFont(10)
        taskTitle.textColor = NSColor(calibratedWhite: 0.7, alpha: 1)
        taskTitle.isBordered = false
        taskTitle.drawsBackground = false
        taskTitle.translatesAutoresizingMaskIntoConstraints = false
        taskPanel.addSubview(taskTitle)

        taskBody.font = PongTheme.mono(9)
        taskBody.textColor = NSColor(calibratedWhite: 0.85, alpha: 1)
        taskBody.isBordered = false
        taskBody.drawsBackground = false
        taskBody.maximumNumberOfLines = 0
        taskBody.lineBreakMode = .byWordWrapping
        taskBody.cell?.truncatesLastVisibleLine = true
        taskBody.translatesAutoresizingMaskIntoConstraints = false
        taskPanel.addSubview(taskBody)

        taskPanelHeight = taskPanel.heightAnchor.constraint(equalToConstant: 168)
        let taskW = taskPanel.widthAnchor.constraint(equalToConstant: leftHUDColW)
        leftHUDPanelWidthConstraints.append(taskW)
        // TASKS sits under CRON (cron is between YOU and TASKS on the left stack)
        NSLayoutConstraint.activate([
            taskPanel.leadingAnchor.constraint(equalTo: leftHUDStack.leadingAnchor),
            taskPanel.topAnchor.constraint(equalTo: cronPanel.bottomAnchor, constant: 8),
            taskW,
            taskPanelHeight!,
            taskTitle.leadingAnchor.constraint(equalTo: taskPanel.leadingAnchor, constant: 12),
            taskTitle.topAnchor.constraint(equalTo: taskPanel.topAnchor, constant: 10),
            taskTitle.trailingAnchor.constraint(equalTo: taskPanel.trailingAnchor, constant: -12),
            taskBody.leadingAnchor.constraint(equalTo: taskPanel.leadingAnchor, constant: 12),
            taskBody.trailingAnchor.constraint(equalTo: taskPanel.trailingAnchor, constant: -12),
            taskBody.topAnchor.constraint(equalTo: taskTitle.bottomAnchor, constant: 8),
            taskBody.bottomAnchor.constraint(equalTo: taskPanel.bottomAnchor, constant: -12),
        ])
        reloadTaskRecap()
    }

    func openHumanDock(session: String) {
        // Respect top-bar single-team lock
        if let focus = focusedTeamSession, focus != "__all__", !focus.isEmpty {
            humanSession = focus
        } else {
            humanSession = session
            lastSingleTeamFocus = session
        }
        humanExpanded = true
        reloadHumanOrchPicker()
        selectHumanOrch(session: humanSession)
        refreshHumanDock()
        reloadHumanInbox()
        relayoutHumanToLinkedOrch()
        window?.makeFirstResponder(humanInput)
    }

    @objc private func toggleHumanExpand() {
        humanExpanded.toggle()
        refreshHumanDock()
        if humanExpanded {
            reloadHumanInbox()
            window?.makeFirstResponder(humanInput)
        }
    }

    private func refreshHumanDock() {
        // Panel always visible; body collapses
        humanPanel.isHidden = false
        humanToggle.title = humanExpanded ? "▾" : "▸"
        humanToggle.toolTip = humanExpanded ? "Collapse" : "Expand"
        humanChatStream.isHidden = !humanExpanded
        humanAskRow.isHidden = true
        humanInput.isHidden = !humanExpanded
        humanSend.isHidden = !humanExpanded
        humanClear.isHidden = !humanExpanded
        humanGrow.isHidden = !humanExpanded
        humanVResizeGrip.isHidden = !humanExpanded
        humanAttachLabel.isHidden = !humanExpanded || humanPendingFiles.isEmpty
        if humanExpanded {
            applyHumanFocusLock()
            applyHumanPanelSize()
            updateHumanAttachLabel()
            reloadHumanInbox()
        } else {
            humanPanelHeight?.constant = 34
            humanOrchPop.isHidden = true
            humanLockLabel.isHidden = true
            humanAllBanner.isHidden = true
            humanPanel.needsLayout = true
            leftHUDStack.layoutSubtreeIfNeeded()
            leftHUDScroll.reflectScrolledClipView(leftHUDScroll.contentView)
        }
        layoutSubtreeIfNeeded()
    }

    /// Fill dropdown with every known orchestrator (all teams).
    private func reloadHumanOrchPicker() {
        let prev = (humanOrchPop.selectedItem?.representedObject as? String) ?? humanSession
        humanOrchPop.removeAllItems()
        let pairs = PairState.listPairs()
        let db = PairState.loadPairsDb()
        if pairs.isEmpty {
            humanOrchPop.addItem(withTitle: "(no teams)")
            return
        }
        for session in pairs {
            let entry = db[session] as? [String: Any] ?? [:]
            let display = (entry["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? session
            let cond = entry["conductor"] as? [String: Any]
            let lab = (cond?["label"] as? String) ?? "Orchestrator"
            let title = "\(lab) · \(display)"
            humanOrchPop.addItem(withTitle: title)
            humanOrchPop.lastItem?.representedObject = session
        }
        selectHumanOrch(session: prev.isEmpty ? pairs[0] : prev)
    }

    private func selectHumanOrch(session: String) {
        for item in humanOrchPop.itemArray {
            if (item.representedObject as? String) == session {
                humanOrchPop.select(item)
                humanSession = session
                return
            }
        }
        if let first = humanOrchPop.itemArray.first,
           let s = first.representedObject as? String {
            humanOrchPop.select(first)
            humanSession = s
        }
    }

    @objc private func humanOrchChanged() {
        // Single-team focus: picker is locked — ignore / reset
        if let focus = focusedTeamSession, focus != "__all__", !focus.isEmpty {
            selectHumanOrch(session: focus)
            humanSession = focus
            applyHumanFocusLock()
            return
        }
        if let s = humanOrchPop.selectedItem?.representedObject as? String {
            humanSession = s
            lastSingleTeamFocus = s
            applyHumanFocusLock()
            reloadHumanInbox()
            reloadTaskRecap()
            reloadCronTimeline()
            relayoutHumanToLinkedOrch()
        }
    }

    /// Lightweight poll from PanelController timer — refresh asks without Focus window.
    func pollHumanConsole() {
        guard humanExpanded else { return }
        if let focus = focusedTeamSession, focus != "__all__", !focus.isEmpty {
            humanSession = focus
        }
        reloadHumanInbox()
    }

    /// Move the YOU blob and rewire YOU→orch to `humanSession` (console dropdown).
    private func relayoutHumanToLinkedOrch() {
        sceneLock.lock()
        lastSeatsSig = ""
        layoutSeats()
        sceneLock.unlock()
        requestMapRender()
    }

    /// True when the linked team is actually waiting on a human (not “any team”).
    private func sessionNeedsHuman(_ session: String) -> Bool {
        guard !session.isEmpty else { return false }
        for s in seats where s.session == session {
            let st = s.status.lowercased()
            if st.contains("human") || st.contains("takeover") || st.contains("ask") {
                return true
            }
        }
        // Snapshot open jobs for this session (seat status can lag)
        let snap = Pong.loadJSON(Pong.stateDir + "/snapshot.json")
        if let team = (snap["teams"] as? [[String: Any]])?.first(where: { ($0["session"] as? String) == session }) {
            for j in ((team["jobs"] as? [String: Any])?["open"] as? [[String: Any]]) ?? [] {
                let st = ((j["status"] as? String) ?? "").lowercased()
                if st.contains("human") || st.contains("ask") { return true }
            }
            for w in (team["workers"] as? [[String: Any]]) ?? [] {
                let h = ((w["status_hint"] as? String) ?? "").lowercased()
                if h.contains("human") || h.contains("takeover") { return true }
            }
        }
        return false
    }

    /// Orchestrator the human console is wired to (dropdown), not a guessed primary team.
    private func linkedHumanOrchSession(fallbackSeatSession: String) -> String {
        if let s = humanOrchPop.selectedItem?.representedObject as? String, !s.isEmpty {
            return s
        }
        if !humanSession.isEmpty { return humanSession }
        if !fallbackSeatSession.isEmpty { return fallbackSeatSession }
        return seats.first(where: { $0.role == "conductor" })?.session ?? ""
    }

    /// Build “Name → brief recap” lines from open jobs + seat state (not event jargon).
    private func reloadTaskRecap() {
        let session: String = {
            if !humanSession.isEmpty { return humanSession }
            if let s = seats.first(where: { $0.role != "human" })?.session { return s }
            return PairState.listPairs().first ?? ""
        }()

        guard !session.isEmpty else {
            taskTitle.stringValue = "TASKS"
            taskBody.stringValue = "No team yet."
            taskPanelHeight?.constant = 72
            return
        }

        let snap = Pong.loadJSON(Pong.stateDir + "/snapshot.json")
        let team = ((snap["teams"] as? [[String: Any]]) ?? [])
            .first { ($0["session"] as? String) == session }
        let openJobs = ((team?["jobs"] as? [String: Any])?["open"] as? [[String: Any]]) ?? []
        let snapWorkers = (team?["workers"] as? [[String: Any]]) ?? []

        // id → display name from seats (preferred) or snapshot labels
        var nameById: [String: String] = [:]
        for s in seats where s.session == session && s.role != "human" && s.role != "conductor" {
            nameById[s.id] = s.title
        }
        for w in snapWorkers {
            guard let id = w["id"] as? String, !id.isEmpty else { continue }
            if nameById[id] == nil {
                nameById[id] = (w["label"] as? String) ?? id
            }
        }

        var lines: [String] = []
        var covered = Set<String>()

        // 1) Open jobs — authoritative task text
        for j in openJobs {
            let wid = (j["worker"] as? String) ?? (j["worker_id"] as? String) ?? "?"
            let name = nameById[wid]
                ?? (j["worker_label"] as? String)
                ?? wid
            let preview = cleanTaskPreview(
                (j["task_preview"] as? String) ?? (j["task"] as? String)
            )
            let st = ((j["status"] as? String) ?? "").lowercased()
            let recap: String = {
                if st.contains("human") || st.contains("ask") || (j["human_takeover"] as? Bool) == true {
                    if !preview.isEmpty { return "needs you · \(preview)" }
                    return "needs your input"
                }
                if !preview.isEmpty { return preview }
                return friendlyStatusRecap(st)
            }()
            lines.append("\(shortName(name)) → \(recap)")
            covered.insert(wid)
        }

        // 2) Seats busy / human without a job row still
        for s in seats where s.session == session && s.role != "human" && s.role != "conductor" {
            guard !covered.contains(s.id) else { continue }
            let st = s.status.lowercased()
            let hint = cleanTaskPreview(s.flowHint)
            if st.contains("human") || st.contains("takeover") || st.contains("ask") {
                let recap = hint.isEmpty ? "needs your input" : "needs you · \(hint)"
                lines.append("\(shortName(s.title)) → \(recap)")
                covered.insert(s.id)
            } else if s.openJobs > 0 || st.contains("busy") || st.contains("running") || st.contains("live") {
                let recap = hint.isEmpty ? "working" : hint
                lines.append("\(shortName(s.title)) → \(recap)")
                covered.insert(s.id)
            }
        }

        // 3) Snapshot workers with status_hint noise we can translate
        for w in snapWorkers {
            let id = (w["id"] as? String) ?? ""
            guard !id.isEmpty, !covered.contains(id) else { continue }
            let hint = ((w["status_hint"] as? String) ?? "").lowercased()
            let openN = w["open_jobs"] as? Int ?? 0
            guard openN > 0 || hint.contains("human") || hint.contains("busy")
                    || hint.contains("running") || hint.contains("notified") else { continue }
            let name = nameById[id] ?? (w["label"] as? String) ?? id
            let recap: String = {
                if hint.contains("human") || hint.contains("takeover") { return "needs your input" }
                if openN > 0 { return openN == 1 ? "1 open job" : "\(openN) open jobs" }
                return friendlyStatusRecap(hint)
            }()
            lines.append("\(shortName(name)) → \(recap)")
            covered.insert(id)
        }

        let display = {
            let entry = PairState.loadPairsDb()[session] as? [String: Any]
            return (entry?["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? session
        }()
        if lines.isEmpty {
            taskTitle.stringValue = "TASKS · \(display)"
            taskBody.stringValue = "Queue clear — no active work."
            taskPanelHeight?.constant = 72
        } else {
            taskTitle.stringValue = "TASKS · \(lines.count) LIVE · \(display)"
            // Cap body so the panel stays scannable
            let shown = Array(lines.prefix(12))
            var body = shown.joined(separator: "\n")
            if lines.count > shown.count {
                body += "\n+\(lines.count - shown.count) more"
            }
            taskBody.stringValue = body
            // ~14pt per line + chrome
            let h = min(220, max(88, CGFloat(shown.count) * 15 + 40))
            taskPanelHeight?.constant = h
        }
        taskPanel.needsLayout = true
    }

    private func shortName(_ name: String) -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= 18 { return t }
        return String(t.prefix(17)) + "…"
    }

    private func cleanTaskPreview(_ raw: String?) -> String {
        guard var t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return "" }
        t = t.replacingOccurrences(of: "\n", with: " ")
        // Strip junk labels that used to leak into the UI
        let lower = t.lowercased()
        if lower == "notified" || lower == "running" || lower == "queued"
            || lower == "status" || lower.hasPrefix("status →")
            || lower == "worker filed a claim" || lower.hasPrefix("worker filed") {
            return ""
        }
        if t.count <= 52 { return t }
        return String(t.prefix(51)) + "…"
    }

    /// Human-readable verb for a machine status — never dump the raw token alone.
    private func friendlyStatusRecap(_ status: String) -> String {
        let s = status.lowercased()
        if s.contains("human") || s.contains("takeover") || s.contains("ask") {
            return "needs your input"
        }
        if s.contains("claim") { return "claim ready for review" }
        if s.contains("notified") || s.contains("dispatch") { return "picked up assignment" }
        if s.contains("running") || s.contains("busy") || s.contains("live") {
            return "building"
        }
        if s.contains("queued") { return "queued — waiting to start" }
        if s.contains("done") || s.contains("accept") { return "done" }
        if s.contains("reject") { return "reworking after reject" }
        if s.isEmpty { return "working" }
        return "working"
    }

    private func reloadHumanInbox() {
        // Keep picker in sync when teams change
        if humanOrchPop.numberOfItems == 0 || PairState.listPairs().count != humanOrchPop.numberOfItems {
            reloadHumanOrchPicker()
        }
        // Single-team focus always wins
        if let focus = focusedTeamSession, focus != "__all__", !focus.isEmpty {
            humanSession = focus
        }
        applyHumanFocusLock()
        let teamName = teamDisplayName(for: humanSession)
        guard !humanSession.isEmpty else {
            humanTitle.stringValue = "YOU · HUMAN"
            humanChatStream.reload(
                messages: [],
                pendingAsk: nil,
                emptyHint: focusedTeamSession == "__all__"
                    ? "Pick an orchestrator above (All teams mode)."
                    : "Select a team in the top bar.",
                force: true
            )
            return
        }
        let ask = HumanConsoleController.loadPendingAsk(session: humanSession)
        let cards = HumanConsoleController.loadCards(session: humanSession, limit: 60)
        if ask != nil {
            humanTitle.stringValue = "YOU · \(teamName) · DECIDE"
        } else {
            humanTitle.stringValue = "YOU · \(teamName)"
        }
        humanChatStream.reload(
            messages: cards,
            pendingAsk: ask,
            emptyHint: "No messages · team locked to \(teamName)",
            force: false
        )
        // Keep legacy ask row collapsed — interaction is on stream cards
        humanAskRow.isHidden = true
        humanAskRowHeight?.constant = 0
    }

    private func humanRespondAsk(_ decision: HumanAskDecision) {
        guard let session = resolvedSendSession() else { return }
        pulseHumanOrchLink(session: session)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = HumanConsoleController.respondToAsk(session: session, decision: decision)
            DispatchQueue.main.async { self.reloadHumanInbox() }
        }
    }

    private func humanTapJob(_ jobId: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(jobId, forType: .string)
        PanelController.shared.goToMission()
        Pong.log("human chat job chip → Mission job=\(jobId) (copied)")
    }

    private func humanTapSeat(_ seatId: String) {
        let sess = humanSession
        guard !sess.isEmpty else { return }
        let gid = "\(sess)::\(seatId)"
        if let seat = seats.first(where: { $0.globalId == gid })
            ?? seats.first(where: { $0.session == sess && $0.id == seatId }) {
            let mid = convert(NSPoint(x: bounds.midX, y: bounds.midY), from: nil)
            // Prefer module card near center of map
            showModuleCard(for: seat, near: NSPoint(x: bounds.midX * 0.55, y: bounds.midY * 0.55))
            _ = mid
            Pong.log("human chat seat chip → \(gid)")
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(seatId, forType: .string)
            Pong.log("human chat seat chip copy \(seatId)")
        }
    }

    @objc private func sendHumanChat() {
        guard let session = resolvedSendSession() else { return }
        let typed = humanInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = humanPendingFiles
        guard !typed.isEmpty || !files.isEmpty else { return }
        // Free-text reply to open ask (open-ended questions)
        var text = typed
        if let ask = HumanConsoleController.loadPendingAsk(session: session), !typed.isEmpty {
            if !typed.lowercased().hasPrefix("deny") && !typed.lowercased().hasPrefix("accept") {
                text = "Reply to ask:\n\(ask.question)\n\n\(typed)"
            }
        }
        humanInput.stringValue = ""
        humanPendingFiles.removeAll()
        updateHumanAttachLabel()
        if !files.isEmpty {
            let list = files.map { "- \($0)" }.joined(separator: "\n")
            let block = "Attached files:\n\(list)"
            text = text.isEmpty ? block : "\(text)\n\n\(block)"
        }
        if focusedTeamSession == "__all__" {
            humanAllBanner.isHidden = false
            humanAllBanner.stringValue = "Sending to: \(teamDisplayName(for: session))"
        }
        pulseHumanOrchLink(session: session)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = HumanConsoleController.deliver(session: session, text: text)
            DispatchQueue.main.async { self.reloadHumanInbox() }
        }
    }

    /// Briefly animate the YOU↔orch floor line after the user actually sends a message.
    private func pulseHumanOrchLink(session: String) {
        let orch = seats.first(where: { $0.session == session && $0.role == "conductor" })
            ?? seats.first(where: { $0.role == "conductor" })
        guard let orch else { return }
        let edgeKey = "you>\(orch.session)|\(orch.id)"
        edgeFlowExpire[edgeKey] = Date().timeIntervalSince1970 + flowLingerSec
        sceneLock.lock()
        lastSeatsSig = ""
        layoutSeats()
        sceneLock.unlock()
        requestMapRender()
    }

    /// Right ops rail: compact legend + TRACKING list; expands on hover.
    private var rightOpsExpanded = false
    private var rightOpsTracking: NSTrackingArea?

    private func setupLegend() {
        legendPanel.wantsLayer = true
        legendPanel.layer?.backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 0.92).cgColor
        legendPanel.layer?.cornerRadius = 8
        legendPanel.layer?.borderWidth = 1
        legendPanel.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.12).cgColor
        legendPanel.translatesAutoresizingMaskIntoConstraints = true
        legendPanel.toolTip = "Hover to expand live agent tracking"
        addSubview(legendPanel)

        rebuildRightOpsContent()
        layoutRightHUD()
        installRightOpsTracking()
    }

    private func rebuildRightOpsContent() {
        legendPanel.subviews.forEach { $0.removeFromSuperview() }
        let expanded = rightOpsExpanded
        let w: CGFloat = expanded ? 220 : 132
        var y: CGFloat = 8

        // Header
        let head = NSTextField(labelWithString: expanded ? "TRACKING · LIVE" : "TRACKING")
        head.font = PongTheme.labelFont(9)
        head.textColor = PongTheme.textSecondary
        head.isBordered = false
        head.drawsBackground = false
        head.frame = NSRect(x: 10, y: y, width: w - 20, height: 14)
        legendPanel.addSubview(head)
        y += 18

        // Live status (compact when collapsed)
        let bodyText = trackBody.stringValue.isEmpty
            ? "No seats"
            : trackBody.stringValue
        let body = NSTextField(wrappingLabelWithString: bodyText)
        body.font = PongTheme.mono(9)
        body.textColor = PongTheme.textPrimary
        body.isBordered = false
        body.drawsBackground = false
        body.maximumNumberOfLines = expanded ? 16 : 3
        let bodyH: CGFloat = expanded ? min(200, max(48, CGFloat(bodyText.split(separator: "\n").count) * 13 + 8)) : 42
        body.frame = NSRect(x: 10, y: y, width: w - 20, height: bodyH)
        legendPanel.addSubview(body)
        // Keep reference path for refreshTrackingList via trackBody text
        trackBody.stringValue = bodyText
        y += bodyH + 8

        // Divider + legend key
        let div = NSView(frame: NSRect(x: 10, y: y, width: w - 20, height: 1))
        div.wantsLayer = true
        div.layer?.backgroundColor = PongTheme.lineSoft.cgColor
        legendPanel.addSubview(div)
        y += 8

        let lines: [(String, String, NSColor)] = [
            ("—", "Idle link", NSColor(calibratedWhite: 1, alpha: 0.25)),
            ("—", "Active / job", NSColor(calibratedWhite: 1, alpha: 0.7)),
            ("◆", "YOU", PongTheme.amber),
            ("⬡", "Orch", PongTheme.blue),
            ("■", "Agent", PongTheme.magenta),
            ("▲", "Sub", PongTheme.violet),
        ]
        let keyLines = expanded ? lines : Array(lines.prefix(4))
        for (sym, name, col) in keyLines {
            let s = NSTextField(labelWithString: "\(sym)  \(name)")
            s.font = PongTheme.labelFont(9)
            s.textColor = col
            s.isBordered = false
            s.drawsBackground = false
            s.frame = NSRect(x: 10, y: y, width: w - 20, height: 14)
            legendPanel.addSubview(s)
            y += 16
        }
        if !expanded {
            let hint = NSTextField(labelWithString: "hover · expand")
            hint.font = PongTheme.labelFont(8)
            hint.textColor = PongTheme.textTertiary
            hint.isBordered = false
            hint.drawsBackground = false
            hint.frame = NSRect(x: 10, y: y, width: w - 20, height: 12)
            legendPanel.addSubview(hint)
            y += 14
        }
        let h = y + 8
        // Position set in layoutRightHUD
        legendPanel.frame.size = NSSize(width: w, height: h)
    }

    private func installRightOpsTracking() {
        if let old = rightOpsTracking {
            legendPanel.removeTrackingArea(old)
        }
        let t = NSTrackingArea(
            rect: legendPanel.bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: ["role": "rightOps"]
        )
        legendPanel.addTrackingArea(t)
        rightOpsTracking = t
    }

    private func setRightOpsExpanded(_ on: Bool) {
        guard rightOpsExpanded != on else { return }
        rightOpsExpanded = on
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            rebuildRightOpsContent()
            layoutRightHUD()
        })
        installRightOpsTracking()
    }

    /// CRON list on the **left** stack: TRACKING → YOU → CRON → TASKS
    /// (frees the right side for the 3D ruler).
    private func setupCronPanel() {
        cronPanel.wantsLayer = true
        cronPanel.layer?.backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 0.88).cgColor
        cronPanel.layer?.cornerRadius = 7
        cronPanel.layer?.borderWidth = 1
        cronPanel.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.12).cgColor
        cronPanel.translatesAutoresizingMaskIntoConstraints = false
        leftHUDStack.addSubview(cronPanel)

        cronTitle.font = PongTheme.labelFont(10)
        cronTitle.textColor = NSColor(calibratedWhite: 0.7, alpha: 1)
        cronTitle.isBordered = false
        cronTitle.drawsBackground = false
        cronTitle.translatesAutoresizingMaskIntoConstraints = false
        cronPanel.addSubview(cronTitle)

        cronToggle.title = "▾"
        cronToggle.bezelStyle = .inline
        cronToggle.isBordered = false
        cronToggle.font = PongTheme.font(12, weight: .semibold)
        cronToggle.contentTintColor = NSColor(calibratedWhite: 0.65, alpha: 1)
        cronToggle.target = self
        cronToggle.action = #selector(toggleCronList)
        cronToggle.toolTip = "Collapse / expand list"
        cronToggle.translatesAutoresizingMaskIntoConstraints = false
        cronPanel.addSubview(cronToggle)

        cronEditBtn.title = "Manage"
        cronEditBtn.bezelStyle = .inline
        cronEditBtn.isBordered = false
        cronEditBtn.font = PongTheme.labelFont(10)
        cronEditBtn.contentTintColor = PongTheme.blue
        cronEditBtn.target = self
        cronEditBtn.action = #selector(openCronManager)
        cronEditBtn.translatesAutoresizingMaskIntoConstraints = false
        cronPanel.addSubview(cronEditBtn)

        cronBody.font = PongTheme.mono(9)
        cronBody.textColor = NSColor(calibratedWhite: 0.85, alpha: 1)
        cronBody.isBordered = false
        cronBody.drawsBackground = false
        cronBody.maximumNumberOfLines = 0
        cronBody.lineBreakMode = .byWordWrapping
        cronBody.translatesAutoresizingMaskIntoConstraints = false
        cronPanel.addSubview(cronBody)

        cronPanelHeightConstraint = cronPanel.heightAnchor.constraint(equalToConstant: 160)
        let cronW = cronPanel.widthAnchor.constraint(equalToConstant: leftHUDColW)
        leftHUDPanelWidthConstraints.append(cronW)
        NSLayoutConstraint.activate([
            cronPanel.leadingAnchor.constraint(equalTo: leftHUDStack.leadingAnchor),
            cronPanel.topAnchor.constraint(equalTo: humanPanel.bottomAnchor, constant: 8),
            cronW,
            cronPanelHeightConstraint!,
            cronTitle.leadingAnchor.constraint(equalTo: cronPanel.leadingAnchor, constant: 12),
            cronTitle.topAnchor.constraint(equalTo: cronPanel.topAnchor, constant: 10),
            cronToggle.trailingAnchor.constraint(equalTo: cronEditBtn.leadingAnchor, constant: -4),
            cronToggle.centerYAnchor.constraint(equalTo: cronTitle.centerYAnchor),
            cronToggle.widthAnchor.constraint(equalToConstant: 22),
            cronEditBtn.trailingAnchor.constraint(equalTo: cronPanel.trailingAnchor, constant: -8),
            cronEditBtn.centerYAnchor.constraint(equalTo: cronTitle.centerYAnchor),
            cronEditBtn.widthAnchor.constraint(equalToConstant: 58),
            cronBody.leadingAnchor.constraint(equalTo: cronPanel.leadingAnchor, constant: 12),
            cronBody.trailingAnchor.constraint(equalTo: cronPanel.trailingAnchor, constant: -12),
            cronBody.topAnchor.constraint(equalTo: cronTitle.bottomAnchor, constant: 8),
            cronBody.bottomAnchor.constraint(equalTo: cronPanel.bottomAnchor, constant: -10),
        ])
        layoutRightHUD()
        reloadCronTimeline()
    }

    @objc private func toggleCronList() {
        cronListExpanded.toggle()
        cronToggle.title = cronListExpanded ? "▾" : "▸"
        cronBody.isHidden = !cronListExpanded
        cronPanelHeightConstraint?.constant = cronListExpanded ? max(100, cronPanelHeightConstraint?.constant ?? 160) : 34
        layoutRightHUD()
        reloadCronTimeline()
        leftHUDStack.layoutSubtreeIfNeeded()
        leftHUDScroll.reflectScrolledClipView(leftHUDScroll.contentView)
    }

    // MARK: - 3D cron ruler (scrollable, not zoomable)

    private func buildCronRulerBase() {
        rulerRoot.name = "cron-ruler"
        rulerRoot.childNodes.forEach { $0.removeFromParentNode() }
        rulerDyn.childNodes.forEach { $0.removeFromParentNode() }
        // Invisible hit strip only — no solid plate / outline box (design: subtle tick lines).
        let hit = SCNBox(width: CGFloat(rulerW * 1.4), height: 0.08, length: CGFloat(rulerHalf * 2), chamferRadius: 0)
        let hm = SCNMaterial()
        hm.diffuse.contents = NSColor.clear
        hm.lightingModel = .constant
        hm.writesToDepthBuffer = false
        hm.colorBufferWriteMask = []
        hit.materials = [hm]
        let sn = SCNNode(geometry: hit)
        sn.position = SCNVector3(rulerX, 0.02, 0)
        sn.name = "ruler-surface"
        sn.categoryBitMask = Self.hitDecor
        rulerRoot.addChildNode(sn)
        // Faint center spine (single line, not a framed outline)
        addRulerSpine()
        rulerDyn.name = "ruler-dyn"
        rulerRoot.addChildNode(rulerDyn)
        rootNode.addChildNode(rulerRoot)
        rebuildCronRuler()
    }

    /// Thin longitudinal spine for the timeline — no box rim.
    private func addRulerSpine() {
        let len = CGFloat(rulerHalf * 2)
        let box = SCNBox(width: 0.02, height: 0.012, length: len, chamferRadius: 0)
        let m = SCNMaterial()
        m.diffuse.contents = PongTheme.blue.withAlphaComponent(0.18)
        m.emission.contents = NSColor.black
        m.lightingModel = .constant
        m.writesToDepthBuffer = false
        box.materials = [m]
        let n = SCNNode(geometry: box)
        n.position = SCNVector3(rulerX, 0.02, 0)
        n.name = "ruler-spine"
        n.categoryBitMask = Self.hitDecor
        rulerRoot.addChildNode(n)
    }

    private func rebuildCronRuler() {
        rulerDyn.childNodes.forEach { $0.removeFromParentNode() }
        let hour: Double = 3600
        let winH: Double = 72
        let leadH: Double = 8
        let uPerH = Double(rulerHalf * 2) / winH
        let startT = Date().timeIntervalSince1970 - leadH * hour + rulerOffsetH * hour
        let endT = startT + winH * hour
        // Default camera sits at +Z looking at origin → +Z is front, −Z is back.
        // Past stays near the camera; future recedes into the distance.
        func zAt(_ t: Double) -> Float {
            Float(rulerHalf) - Float((t - startT) / hour * uPerH)
        }
        // Hour ticks
        var hh = ceil(startT / hour) * hour
        while hh <= endT {
            let d = Date(timeIntervalSince1970: hh)
            let cal = Calendar.current
            let hod = cal.component(.hour, from: d)
            let z = zAt(hh)
            let mid = hod == 0
            let len: Float = mid ? 1.3 : (hod % 6 == 0 ? 0.7 : 0.32)
            let col = mid
                ? NSColor(calibratedWhite: 0.76, alpha: 0.6)
                : NSColor(calibratedWhite: 0.44, alpha: 0.28)
            addRulerSeg(x1: rulerX - len / 2, z1: z, x2: rulerX + len / 2, z2: z, y: 0.03, color: col)
            if mid {
                let mon = cal.shortMonthSymbols[cal.component(.month, from: d) - 1].uppercased()
                let day = cal.component(.day, from: d)
                addRulerText("\(mon) \(day)", at: SCNVector3(rulerX + rulerW / 2 + 0.6, 0.08, z), color: NSColor(calibratedWhite: 0.76, alpha: 0.85))
            }
            hh += hour
        }
        // NOW tick
        let nz = zAt(Date().timeIntervalSince1970)
        if nz >= -rulerHalf && nz <= rulerHalf {
            addRulerSeg(x1: rulerX - rulerW / 2, z1: nz, x2: rulerX + rulerW / 2, z2: nz, y: 0.04,
                        color: PongTheme.cyanBright.withAlphaComponent(0.75))
            addRulerText("NOW", at: SCNVector3(rulerX + rulerW / 2 + 0.5, 0.08, nz), color: PongTheme.cyanBright)
        }
        // Jobs — dots only for real enabled-job occurrences (no decorative tick dots).
        // Clickable: name cron:<session>|<jobId>, hitInteractive (Claude Addendum 3).
        let session = humanSession.isEmpty
            ? (seats.first(where: { $0.role != "human" })?.session ?? "")
            : humanSession
        let jobs = session.isEmpty ? CronSchedule.defaultJobs(session: "default") : CronSchedule.load(session: session)
        let cronSession = session.isEmpty ? "default" : session
        let nf = DateFormatter()
        nf.dateFormat = "HH:mm"
        // Prefer session-scoped seats so multi-team owner ids (c1/w1) don't collide.
        let sessionSeats = seats.filter { $0.session == cronSession || cronSession == "default" }
        // Collect next-run pins first so we can stack labels in timeline order (no overlap).
        struct CronPin {
            var z: Float
            var t: Double
            var label: String
            var col: NSColor
            var cronName: String
            var tip: String
            var ownerGid: String?
        }
        var pins: [CronPin] = []

        for j in jobs where j.enabled {
            let step = max(j.intervalSec, 60)
            let col = CronSchedule.accent(forOwnerId: j.ownerId, seats: sessionSeats.isEmpty ? seats : sessionSeats)
            let ownerSeat = (sessionSeats.isEmpty ? seats : sessionSeats)
                .first(where: { $0.id == j.ownerId })
            let ownerName = ownerSeat?.title ?? j.ownerTag
            let label = cronDisplayLabel(session: cronSession, jobName: j.name, ownerName: ownerName)
            let cronName = "cron:\(cronSession)|\(j.id)"
            let tipBase = "\(label)\n\(j.cadence) · next \(nf.string(from: j.nextRun()))"

            // Subsequent occurrences: only when spacing is readable on the ruler; fainter + smaller.
            let minDotSpacing = 0.55  // world units along Z
            if step * uPerH / hour >= minDotSpacing {
                var t = ceil((startT - j.phaseSec) / step) * step + j.phaseSec
                let nextT = j.nextRun().timeIntervalSince1970
                while t <= endT {
                    if abs(t - nextT) > step * 0.25 {
                        let z = zAt(t)
                        let dn = makeCronDot(
                            radius: 0.09,
                            color: col.withAlphaComponent(0.55),
                            name: cronName,
                            tooltip: tipBase,
                            interactive: true
                        )
                        dn.position = SCNVector3(rulerX, 0.06, z)
                        rulerDyn.addChildNode(dn)
                    }
                    t += step
                }
            }
            let next = j.nextRun().timeIntervalSince1970
            if next >= startT && next <= endT {
                pins.append(CronPin(
                    z: zAt(next),
                    t: next,
                    label: label,
                    col: col,
                    cronName: cronName,
                    tip: tipBase,
                    ownerGid: ownerSeat?.globalId
                ))
            }
        }

        // Timeline order: earlier times first
        pins.sort { $0.t < $1.t }

        // De-dupe identical job ids (double-rebuild / same next-run twice)
        var seenJob = Set<String>()
        pins = pins.filter { seenJob.insert($0.cronName).inserted }

        // Non-overlapping labels. Billboarded text is wide on screen — use generous
        // Z half-width from real font metrics and a stack step taller than the plane.
        func labelWorldW(_ text: String) -> Float {
            // mono 40 + kern 3 ≈ 24–26 px/char after /100 world scale
            let texW = max(160, CGFloat(text.count) * 26 + 40)
            return Float(texW / 100)
        }
        let planeH: Float = 0.95
        let stackStep: Float = planeH + 0.45   // clear gap between rows
        let labelBaseY: Float = 0.28
        let zPad: Float = 1.2                 // billboard widen
        var placed: [(z: Float, y: Float, halfW: Float)] = []

        for pin in pins {
            let halfW = labelWorldW(pin.label) * 0.55 + zPad
            var y = labelBaseY
            var guardN = 0
            while guardN < 24 {
                var hit = false
                for p in placed {
                    let zClose = abs(p.z - pin.z) < (p.halfW + halfW)
                    let yClose = abs(p.y - y) < stackStep * 0.98
                    if zClose && yClose {
                        hit = true
                        break
                    }
                }
                if !hit { break }
                y += stackStep
                guardN += 1
            }
            placed.append((pin.z, y, halfW))

            let pn = makeCronDot(
                radius: 0.17,
                color: pin.col,
                name: pin.cronName,
                tooltip: pin.tip,
                interactive: true
            )
            pn.position = SCNVector3(rulerX, 0.06, pin.z)
            rulerDyn.addChildNode(pn)

            // Connector to owner
            if let gid = pin.ownerGid, let node = seatNodes[gid] {
                let a = SCNVector3(rulerX, 0.06, pin.z)
                let b = node.position
                let dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z
                let dist = sqrt(dx * dx + dy * dy + dz * dz)
                if dist > 0.1 {
                    let cyl = SCNCylinder(radius: 0.012, height: CGFloat(dist))
                    let cm = SCNMaterial()
                    cm.diffuse.contents = pin.col.withAlphaComponent(0.22)
                    cm.emission.contents = NSColor.black
                    cm.lightingModel = .constant
                    cyl.materials = [cm]
                    let cn = SCNNode(geometry: cyl)
                    cn.position = SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
                    let fromV = SIMD3<Float>(0, 1, 0)
                    let toV = simd_normalize(SIMD3<Float>(Float(dx), Float(dy), Float(dz)))
                    cn.simdOrientation = simd_quatf(from: fromV, to: toV)
                    cn.categoryBitMask = Self.hitDecor
                    rulerDyn.addChildNode(cn)
                }
            }

            // Label RIGHT of ruler; Y stack when Z ranges would overlap
            addRulerText(
                pin.label,
                at: SCNVector3(rulerX + rulerW / 2 + 0.55, y, pin.z),
                color: pin.col.withAlphaComponent(0.95),
                alignLeading: true,
                isCronJobLabel: true
            )
        }

        // Title at the near (past) end of the ruler from the default camera
        addRulerText("CRON TIMELINE", at: SCNVector3(rulerX + rulerW / 2 + 0.55, 0.10, rulerHalf + 1.2),
                     color: NSColor(calibratedWhite: 0.55, alpha: 0.9),
                     alignLeading: true,
                     isCronJobLabel: false)
    }

    /// Team display name for a session (`display_name`, else conductor title, else session id).
    private func teamDisplayName(for session: String) -> String {
        if session.isEmpty || session == "default" {
            return seats.first(where: { $0.role == "conductor" })?.title ?? "Team"
        }
        let entry = PairState.loadPairsDb()[session] as? [String: Any] ?? [:]
        if let name = (entry["display_name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let orch = seats.first(where: { $0.session == session && $0.role == "conductor" }) {
            return orch.title
        }
        // Short session slug if nothing better
        if session.hasPrefix("pong-team") || session.hasPrefix("hermes-") {
            return session
        }
        return session
    }

    /// Cron label: **Team · Owner · Job** so role/team identity leads (not the job verb).
    private func cronDisplayLabel(session: String, jobName: String, ownerName: String) -> String {
        let team = teamDisplayName(for: session)
        let job = jobName.trimmingCharacters(in: .whitespacesAndNewlines)
        let owner = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if owner.isEmpty || owner.caseInsensitiveCompare(team) == .orderedSame {
            return "\(team) · \(job)"
        }
        return "\(team) · \(owner) · \(job)"
    }

    /// Interactive cron occurrence pin/dot (click → edit job, hover → tooltip).
    private func makeCronDot(radius: CGFloat, color: NSColor, name: String,
                             tooltip: String, interactive: Bool) -> SCNNode {
        let sph = SCNSphere(radius: radius)
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.emission.contents = color.withAlphaComponent(0.15)
        m.lightingModel = .constant
        sph.materials = [m]
        let n = SCNNode(geometry: sph)
        n.name = name
        n.categoryBitMask = interactive ? Self.hitInteractive : Self.hitDecor
        n.setValue(tooltip, forKey: "cronTip")
        return n
    }

    /// Parse `cron:<session>|<jobId>` from a hit node (or its parents).
    private func cronJobHit(from node: SCNNode?) -> (session: String, jobId: String)? {
        var n: SCNNode? = node
        while let cur = n {
            if let name = cur.name, name.hasPrefix("cron:") {
                let rest = String(name.dropFirst(5))
                let parts = rest.split(separator: "|", maxSplits: 1).map(String.init)
                if parts.count == 2 { return (parts[0], parts[1]) }
            }
            n = cur.parent
        }
        return nil
    }

    private func addRulerSeg(x1: Float, z1: Float, x2: Float, z2: Float, y: Float, color: NSColor) {
        let dx = x2 - x1, dz = z2 - z1
        let len = sqrt(dx * dx + dz * dz)
        guard len > 0.001 else { return }
        let box = SCNBox(width: CGFloat(len), height: 0.02, length: 0.03, chamferRadius: 0)
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.emission.contents = NSColor.black
        m.lightingModel = .constant
        box.materials = [m]
        let n = SCNNode(geometry: box)
        n.position = SCNVector3((x1 + x2) / 2, y, (z1 + z2) / 2)
        n.eulerAngles.y = CGFloat(atan2(dz, dx))
        n.categoryBitMask = Self.hitDecor
        rulerDyn.addChildNode(n)
    }

    /// Cron / timeline text — same type recipe as deck plane names (`addDeckIndexLabel`).
    /// `alignLeading`: position is the left edge of the label (for text to the right of the ruler).
    /// `isCronJobLabel`: hide when zoomed far (dots stay; text reappears when closer).
    private func addRulerText(_ text: String, at pos: SCNVector3, color: NSColor,
                              alignLeading: Bool = false, isCronJobLabel: Bool = false) {
        // Match deck labels: PongTheme.mono 40 semibold, kern 3, 720×96 → 7.2×0.95 scale
        let texH: CGFloat = 96
        let attrs: [NSAttributedString.Key: Any] = [
            .font: PongTheme.mono(40, weight: .semibold),
            .foregroundColor: color,
            .kern: 3,
        ]
        let textSz = (text as NSString).size(withAttributes: attrs)
        let texW: CGFloat = max(160, textSz.width + 28)
        let img = NSImage(size: NSSize(width: texW, height: texH))
        img.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: texW, height: texH).fill()
        (text as NSString).draw(
            at: NSPoint(x: 12, y: (texH - textSz.height) / 2),
            withAttributes: attrs
        )
        img.unlockFocus()
        // Same world scale as deck labels (tex 720 → width 7.2 ⇒ /100; height 96 → 0.95)
        let planeW = texW / 100
        let planeH: CGFloat = 0.95
        let plane = SCNPlane(width: planeW, height: planeH)
        let m = SCNMaterial()
        m.diffuse.contents = img
        m.emission.contents = NSColor.black
        m.lightingModel = .constant
        // Single-sided + depth write avoids ghosted double-draw on billboards
        m.isDoubleSided = false
        m.writesToDepthBuffer = true
        m.readsFromDepthBuffer = true
        plane.materials = [m]
        let n = SCNNode(geometry: plane)
        if alignLeading {
            n.position = SCNVector3(pos.x + planeW * 0.5, pos.y, pos.z)
        } else {
            n.position = pos
        }
        n.name = isCronJobLabel ? "cron-job-label" : "ruler-text"
        n.setValue(isCronJobLabel, forKey: "cronJobLabel")
        n.setValue(Float(planeH), forKey: "labelBaseH")
        n.categoryBitMask = Self.hitDecor
        n.renderingOrder = 8
        let bb = SCNBillboardConstraint()
        bb.freeAxes = .Y  // keep upright; reduces twin-face ghosting
        n.constraints = [bb]
        rulerDyn.addChildNode(n)
    }

    /// Drag on ruler surface scrolls time (disables orbit while dragging).
    private func handleRulerDrag(at viewPt: NSPoint, state: NSGestureRecognizer.State) {
        let hits = scnView.hitTest(viewPt, options: [
            .searchMode: SCNHitTestSearchMode.all.rawValue,
        ])
        let onRuler = hits.contains { node in
            var n: SCNNode? = node.node
            while let c = n {
                if c.name == "ruler-surface" || c.name == "cron-ruler" || c.name == "ruler-dyn" { return true }
                n = c.parent
            }
            return false
        }
        // Ground plane y=0 near ruler X
        let near = scnView.unprojectPoint(SCNVector3(viewPt.x, viewPt.y, 0))
        let far = scnView.unprojectPoint(SCNVector3(viewPt.x, viewPt.y, 1))
        let dy = far.y - near.y
        guard abs(dy) > 1e-5 else { return }
        let t = (0 - near.y) / dy
        let wx = near.x + (far.x - near.x) * t
        let wz = near.z + (far.z - near.z) * t
        let nearRuler = abs(Float(wx) - rulerX) < rulerW * 1.6 && abs(Float(wz)) < rulerHalf + 1.5

        switch state {
        case .began:
            guard onRuler || nearRuler else { return }
            rulerDragLastZ = Float(wz)
            scnView.allowsCameraControl = false
        case .changed:
            guard let last = rulerDragLastZ else { return }
            let winH: Double = 72
            let uPerH = Double(rulerHalf * 2) / winH
            let dz = Float(wz) - last
            // z decreases as time advances (future → −Z / back), so flip scroll sign
            // so content still follows the drag.
            rulerOffsetH += Double(dz) / uPerH
            rulerDragLastZ = Float(wz)
            rulerDirty = true
        case .ended, .cancelled:
            rulerDragLastZ = nil
            applyCameraMode()
        default: break
        }
    }

    /// Right ops rail (TRACKING + legend) top-right; cron stays left under YOU.
    private func layoutRightHUD(in hostBounds: NSRect? = nil) {
        let b = hostBounds ?? bounds
        let pad: CGFloat = 14
        let legendW = legendPanel.frame.width > 1 ? legendPanel.frame.width : (rightOpsExpanded ? 220 : 132)
        let legendH = max(legendPanel.frame.height, rightOpsExpanded ? 160 : 110)
        let top = b.height > 1 ? b.height : 720
        legendPanel.frame = NSRect(
            x: max(pad, b.width - legendW - pad),
            y: top - pad - legendH,
            width: legendW,
            height: legendH
        )
        cronBody.isHidden = !cronListExpanded
    }

    @objc private func openCronManager() {
        presentCronManager(preselectJobId: nil)
    }

    private func presentCronManager(preselectJobId: String?) {
        let session = humanSession.isEmpty
            ? (seats.first(where: { $0.role != "human" })?.session ?? "")
            : humanSession
        guard !session.isEmpty else { return }
        CronManagerSheet.shared.show(session: session, seats: seats, preselectJobId: preselectJobId) { [weak self] in
            self?.reloadCronTimeline()
            self?.rulerDirty = true
        }
    }

    private func reloadCronTimeline() {
        // AppKit frame mutations must stay on main (render-thread call → SIGABRT).
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.reloadCronTimeline() }
            return
        }
        let session = humanSession.isEmpty
            ? (seats.first(where: { $0.role != "human" })?.session ?? "")
            : humanSession
        guard !session.isEmpty else {
            cronBody.stringValue = "No team · open a seat to bind cron."
            cronPanelHeightConstraint?.constant = 72
            layoutRightHUD()
            return
        }
        let jobs = CronSchedule.load(session: session).filter(\.enabled)
            .sorted { $0.nextRun() < $1.nextRun() }
        cronTitle.stringValue = jobs.isEmpty ? "CRON · TIMELINE" : "CRON · \(jobs.count) JOBS"
        if !cronListExpanded {
            cronBody.stringValue = ""
            cronPanelHeightConstraint?.constant = 34
            layoutRightHUD()
            rulerDirty = true
            return
        }
        if jobs.isEmpty {
            cronBody.stringValue = "No cron jobs · Manage to add.\nDrag the cyan ruler to scroll time."
            cronPanelHeightConstraint?.constant = 88
            layoutRightHUD()
            rulerDirty = true
            return
        }
        let nf = DateFormatter()
        nf.dateFormat = "HH:mm"
        var lines: [String] = []
        let now = Date()
        for (i, j) in jobs.prefix(8).enumerated() {
            let next = j.nextRun(after: now)
            let tag = i == 0 ? "NEXT" : "    "
            // Team first, then owner agent, then job (main role at a glance)
            let owner = seats.first(where: { $0.session == session && $0.id == j.ownerId })?.title
                ?? seats.first(where: { $0.id == j.ownerId })?.title
                ?? j.ownerTag
            let label = cronDisplayLabel(session: session, jobName: j.name, ownerName: owner)
            lines.append("\(tag)  \(nf.string(from: next))")
            lines.append("  \(label)")
            lines.append("  \(j.cadence)")
            if i < jobs.prefix(8).count - 1 { lines.append("") }
        }
        cronBody.stringValue = lines.joined(separator: "\n")
        let h = min(280, max(100, CGFloat(min(jobs.count, 8)) * 48 + 36))
        cronPanelHeightConstraint?.constant = h
        layoutRightHUD()
        rulerDirty = true
    }

    private func refreshTrackingList() {
        // Design: fully monochrome TRACKING (no role accent colors)
        var lines: [String] = []
        let teamSeats = seats.filter { $0.role != "human" }
        let humanN = seats.filter { $0.role == "human" }.count
        let liveN = lastLinks.filter(\.active).count
        lines.append("SEATS  \(seats.count)     LINKS  \(lastLinks.count)     HUMAN  \(humanN)")
        lines.append("")
        let listed = teamSeats + seats.filter { $0.role == "human" }
        for s in listed.prefix(10) {
            let sk = PongTheme.statusKind(s.status).label
            let tag: String = {
                switch s.role {
                case "conductor": return "ORCH"
                case "subagent": return "SUB"
                case "human": return "YOU"
                default: return "AGT"
                }
            }()
            let name = trackingDisplayName(s)
            let mark = isSeatActive(s) ? "●" : "○"
            lines.append("\(mark)  \(tag)  \(name)  \(sk)")
            if s.openJobs > 0 {
                let h = s.flowHint.isEmpty ? "job" : String(s.flowHint.prefix(28))
                lines.append("     → \(h)")
            } else if s.role == "human", s.status.lowercased().contains("human") {
                lines.append("     → needs you")
            }
        }
        lines.append("")
        if liveN == 0 {
            lines.append("No active job flows")
        } else {
            lines.append("LIVE LINKS  \(liveN)")
            for L in lastLinks.filter(\.active).prefix(5) {
                let fromName = seats.first(where: { $0.globalId == L.fromGid }).map(trackingDisplayName) ?? ""
                let toName = seats.first(where: { $0.globalId == L.toGid }).map(trackingDisplayName) ?? ""
                if !fromName.isEmpty, !toName.isEmpty {
                    lines.append("  ▸ \(fromName) → \(toName)")
                } else {
                    lines.append("  ▸ \(L.label)")
                }
            }
        }
        trackBody.stringValue = lines.joined(separator: "\n")
        trackBody.textColor = NSColor(calibratedRed: 0.90, green: 0.93, blue: 0.95, alpha: 1)
        trackTitle.textColor = NSColor(calibratedRed: 0.55, green: 0.60, blue: 0.64, alpha: 1)
        // Refresh right ops rail content (TRACKING + legend)
        rebuildRightOpsContent()
        layoutRightHUD()
    }

    /// Pause expensive SceneKit while Mission/Setup are up.
    func setMapPlaying(_ on: Bool) {
        scnView.isHidden = !on
        if on {
            requestMapRender()
            reevaluateMapPlaying()
        } else {
            scnView.isPlaying = false
            mapNeedsRender = false
        }
    }

    /// Human-facing seat name for TRACKING (label, not internal id).
    private func trackingDisplayName(_ s: Seat3D) -> String {
        if s.role == "human" { return "You" }
        let t = s.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty, t.lowercased() != s.id.lowercased() { return t }
        if !t.isEmpty { return t }
        return s.id
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = hoverTracking { removeTrackingArea(t) }
        // Track over scnView too (it fills the bounds and is what the cursor is over)
        let opts: NSTrackingArea.Options = [
            .activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .enabledDuringMouseDrag,
        ]
        hoverTracking = NSTrackingArea(rect: bounds, options: opts, owner: self, userInfo: nil)
        addTrackingArea(hoverTracking!)
        scnView.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        processHover(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        if let role = event.trackingArea?.userInfo?["role"] as? String, role == "rightOps" {
            setRightOpsExpanded(true)
            return
        }
        processHover(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if let role = event.trackingArea?.userInfo?["role"] as? String, role == "rightOps" {
            setRightOpsExpanded(false)
            return
        }
        clearHover()
    }

    /// Shared hover path for tracking area + event monitor.
    private func processHover(with event: NSEvent) {
        guard window != nil, !isHidden, bounds.width > 1 else { return }
        // Only when pointer is over this map
        let winPt = event.locationInWindow
        let local = convert(winPt, from: nil)
        guard bounds.contains(local) else {
            clearHover()
            return
        }
        let p = scnView.convert(winPt, from: nil)
        let hits = interactiveHits(at: p)

        // Cron pin/dot tooltip (job · owner · next run)
        if let hit = hits.first(where: { cronJobHit(from: $0.node) != nil }) {
            let tip = (hit.node.value(forKey: "cronTip") as? String)
                ?? {
                    var n: SCNNode? = hit.node
                    while let c = n {
                        if let t = c.value(forKey: "cronTip") as? String { return t }
                        n = c.parent
                    }
                    return "Cron job"
                }()
            let cronKey = hit.node.name ?? "cron"
            if hoveredId != cronKey {
                if let prev = hoveredId, !prev.hasPrefix("cron:") { scaleHighlight(prev, on: false) }
                hoveredId = cronKey
                let parts = tip.split(separator: "\n", maxSplits: 1).map(String.init)
                hoverTitle.stringValue = parts.first ?? "Cron"
                hoverStatus.stringValue = "CRON"
                hoverStatus.textColor = PongTheme.cyanBright
                hoverBody.stringValue = parts.count > 1 ? parts[1] : "Click to edit"
                hoverHUD.isHidden = false
                addSubview(hoverHUD, positioned: .above, relativeTo: nil)
            }
            hoverHUD.frame.origin = NSPoint(
                x: min(max(12, local.x + 16), max(12, bounds.width - 292)),
                y: min(max(12, local.y - 120), max(12, bounds.height - 122))
            )
            return
        }

        if let gid = hitTestSeatId(at: p) {
            if hoveredId != gid {
                if let prev = hoveredId, !prev.hasPrefix("cron:") { scaleHighlight(prev, on: false) }
                hoveredId = gid
                showHover(gid)
                scaleHighlight(gid, on: true)
                addSubview(hoverHUD, positioned: .above, relativeTo: nil)
            }
            hoverHUD.frame.origin = NSPoint(
                x: min(max(12, local.x + 16), max(12, bounds.width - 292)),
                y: min(max(12, local.y - 120), max(12, bounds.height - 122))
            )
        } else {
            clearHover()
        }
    }

    private func clearHover() {
        if let prev = hoveredId, !prev.hasPrefix("cron:") {
            scaleHighlight(prev, on: false)
        }
        hoveredId = nil
        hoverHUD.isHidden = true
    }

    /// Hit-test only interactive geometry (seats, edges, +). Decor is category hitDecor.
    private func interactiveHits(at p: NSPoint) -> [SCNHitTestResult] {
        let opts: [SCNHitTestOption: Any] = [
            .searchMode: SCNHitTestSearchMode.all.rawValue,
            .categoryBitMask: Self.hitInteractive,
            .boundingBoxOnly: false,
            .ignoreHiddenNodes: true,
        ]
        return scnView.hitTest(p, options: opts)
    }

    private func hitTestSeatId(at p: NSPoint) -> String? {
        let hits = interactiveHits(at: p)
        // Prefer closest seat (ignore edges under cursor when over a cube)
        for hit in hits {
            if plusHit(from: [hit]) != nil { continue } // don't treat add-pads as hover target for HUD
            if let gid = seatGlobalId(from: hit.node) { return gid }
        }
        return nil
    }

    private func seatGlobalId(from node: SCNNode) -> String? {
        var n: SCNNode? = node
        while let cur = n {
            if let name = cur.name, name.hasPrefix("seat:") {
                return String(name.dropFirst(5))
            }
            n = cur.parent
        }
        return nil
    }

    /// Resolve flow edge id from cylinder / arrow / label / packet hit.
    private func edgeId(from node: SCNNode?) -> String? {
        var n: SCNNode? = node
        while let cur = n {
            if let name = cur.name {
                for prefix in ["edge:", "arrow:", "lbl:", "plate:", "pkt:"] {
                    if name.hasPrefix(prefix) {
                        return String(name.dropFirst(prefix.count))
                    }
                }
            }
            n = cur.parent
        }
        return nil
    }

    /// Parse add-pad hits: `plus-menu:<gid>` (choice menu) or legacy peer/sub pads.
    private func plusHit(from hits: [SCNHitTestResult]) -> (gid: String, kind: String)? {
        for hit in hits {
            var n: SCNNode? = hit.node
            while let cur = n {
                if let name = cur.name {
                    if name.hasPrefix("plus-menu:") {
                        return (String(name.dropFirst("plus-menu:".count)), "menu")
                    }
                    if name.hasPrefix("plus-peer:") {
                        return (String(name.dropFirst("plus-peer:".count)), "peer")
                    }
                    if name.hasPrefix("plus-sub:") {
                        return (String(name.dropFirst("plus-sub:".count)), "sub")
                    }
                    if name.hasPrefix("plus:") {
                        return (String(name.dropFirst(5)), "menu")
                    }
                }
                n = cur.parent
            }
        }
        return nil
    }

    /// Redesign: + opens a small menu — Add agent · Add flow link.
    private func showPlusMenu(for s: Seat3D, at point: NSPoint, kind: String) {
        let menu = NSMenu(title: "Add")
        let agent = NSMenuItem(title: "Add agent", action: #selector(plusMenuAddAgent(_:)), keyEquivalent: "")
        agent.target = self
        agent.representedObject = s.globalId
        agent.image = plusMenuIcon(kind: "agent")
        menu.addItem(agent)

        if s.role == "worker" || s.role == "subagent" {
            let sub = NSMenuItem(
                title: s.role == "subagent" ? "Add sub-agent (same level)" : "Add sub-agent",
                action: #selector(plusMenuAddSub(_:)), keyEquivalent: "")
            sub.target = self
            // For subagent +, attach under the same parent (or this sub as parent)
            sub.representedObject = s.globalId
            sub.image = plusMenuIcon(kind: "sub")
            menu.addItem(sub)
        }

        menu.addItem(NSMenuItem.separator())
        let flow = NSMenuItem(title: "Add flow link", action: #selector(plusMenuAddFlow(_:)), keyEquivalent: "")
        flow.target = self
        flow.representedObject = s.globalId
        flow.image = plusMenuIcon(kind: "flow")
        menu.addItem(flow)

        let cron = NSMenuItem(title: "Add cron job…", action: #selector(plusMenuAddCron(_:)), keyEquivalent: "")
        cron.target = self
        cron.representedObject = s.globalId
        cron.image = plusMenuIcon(kind: "cron")
        menu.addItem(cron)

        // Present as context-style popover near the click
        menu.popUp(positioning: nil, at: point, in: self)
        _ = kind
    }

    private func plusMenuIcon(kind: String) -> NSImage {
        let img = NSImage(size: NSSize(width: 14, height: 14))
        img.lockFocus()
        NSColor(calibratedWhite: 0.75, alpha: 1).setStroke()
        let p = NSBezierPath()
        p.lineWidth = 1.4
        switch kind {
        case "flow":
            p.move(to: NSPoint(x: 2, y: 7)); p.line(to: NSPoint(x: 12, y: 7))
            p.move(to: NSPoint(x: 9, y: 4)); p.line(to: NSPoint(x: 12, y: 7)); p.line(to: NSPoint(x: 9, y: 10))
            p.move(to: NSPoint(x: 5, y: 4)); p.line(to: NSPoint(x: 2, y: 7)); p.line(to: NSPoint(x: 5, y: 10))
        case "cron":
            p.appendOval(in: NSRect(x: 2, y: 2, width: 10, height: 10))
            p.move(to: NSPoint(x: 7, y: 7)); p.line(to: NSPoint(x: 7, y: 4))
            p.move(to: NSPoint(x: 7, y: 7)); p.line(to: NSPoint(x: 10, y: 7))
        case "sub":
            p.appendRect(NSRect(x: 3, y: 3, width: 8, height: 8))
            p.move(to: NSPoint(x: 7, y: 5)); p.line(to: NSPoint(x: 7, y: 9))
            p.move(to: NSPoint(x: 5, y: 7)); p.line(to: NSPoint(x: 9, y: 7))
        default:
            p.appendRect(NSRect(x: 3, y: 3, width: 8, height: 8))
        }
        p.stroke()
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    @objc private func plusMenuAddAgent(_ item: NSMenuItem) {
        guard let gid = item.representedObject as? String,
              let s = seats.first(where: { $0.globalId == gid }) else { return }
        onPlus?(s)
    }

    @objc private func plusMenuAddSub(_ item: NSMenuItem) {
        guard let gid = item.representedObject as? String,
              let s = seats.first(where: { $0.globalId == gid }) else { return }
        // Sub-agent + → nest under this seat (or its parent if already a sub)
        if s.role == "subagent", let pid = s.parentId,
           let parent = seats.first(where: { $0.session == s.session && $0.id == pid }) {
            onAddSub?(parent)
        } else {
            onAddSub?(s)
        }
    }

    @objc private func plusMenuAddFlow(_ item: NSMenuItem) {
        // Topology lives in Architecture sheet (wizard-style), not map Flow mode
        openFlowDesign()
        _ = item
    }

    @objc private func plusMenuAddCron(_ item: NSMenuItem) {
        guard let gid = item.representedObject as? String,
              let s = seats.first(where: { $0.globalId == gid }) else { return }
        CronManagerSheet.shared.addJobForOwner(
            session: s.session,
            ownerId: s.id,
            seats: seats,
            onDone: { [weak self] in
                self?.rulerDirty = true
                self?.reloadCronTimeline()
            }
        )
    }

    /// Session that owns an edge id (pairs may share bare ids in multi-team).
    /// Visual edge ids are `session|flowId` — strip for pairs.json / FlowGraph.
    private func parseEdgeKey(_ key: String) -> (session: String, flowId: String)? {
        if let bar = key.firstIndex(of: "|") {
            let s = String(key[..<bar])
            let f = String(key[key.index(after: bar)...])
            if !s.isEmpty, !f.isEmpty { return (s, f) }
        }
        // Legacy unscoped id
        if let sess = seats.first?.session { return (sess, key) }
        return nil
    }

    private func linkSession(for edgeId: String) -> String? {
        if let p = parseEdgeKey(edgeId) { return p.session }
        for s in seats where s.role != "human" {
            let edges = FlowGraph.load(from: PairState.loadPairsDb()[s.session] as? [String: Any] ?? [:])
            if edges.contains(where: { $0.id == edgeId }) { return s.session }
        }
        return seats.first(where: { $0.role != "human" })?.session
    }

    private func openLinkEditor(session: String, edgeId: String) {
        let flowId = parseEdgeKey(edgeId)?.flowId ?? edgeId
        let entry = PairState.loadPairsDb()[session] as? [String: Any] ?? [:]
        let edges = FlowGraph.load(from: entry)
        guard let edge = edges.first(where: { $0.id == flowId }) else { return }
        FlowLinkEditSheet.shared.show(
            session: session, edge: edge,
            seats: seats.filter { $0.session == session && $0.role != "human" }
        ) { [weak self] in
            self?.onGraphChanged?()
            guard let self else { return }
            self.reload(seats: self.seats, multiTeam: self.multiTeam)
        }
    }

    private func showHover(_ gid: String) {
        guard let s = seats.first(where: { $0.globalId == gid }) else { return }
        hoverTitle.stringValue = s.title
        let roleName: String = {
            switch s.role {
            case "conductor": return "ORCHESTRATOR"
            case "subagent": return "SUBAGENT"
            case "human": return "YOU · HUMAN"
            default: return s.resolvedMission.title.uppercased()
            }
        }()
        let sk = PongTheme.statusKind(s.status)
        hoverStatus.stringValue = "\(roleName)  ·  \(sk.label)  ·  \(s.id.uppercased())"
        hoverStatus.textColor = roleColor(s)
        if s.role == "human" {
            hoverBody.stringValue = s.status.lowercased().contains("human")
                ? "Needs your input · click to open human console"
                : "Click to send prompts / answer asks (no Terminal)"
        } else {
            hoverBody.stringValue = s.detail.isEmpty
                ? "\(s.subtitle)\nClick → card · side pad +agent · under pad +sub"
                : "\(s.subtitle)\n\(s.detail)"
        }
        hoverHUD.isHidden = false
    }

    private func scaleHighlight(_ gid: String, on: Bool) {
        guard let n = seatNodes[gid] else { return }
        let t: CGFloat = on ? 1.12 : 1.0
        n.runAction(SCNAction.scale(to: t, duration: 0.12))
    }

    // MARK: - Gestures

    @objc private func handleClick(_ g: NSClickGestureRecognizer) {
        guard g.state == .ended else { return }
        if mapMode == .move { return } // pan gesture owns move mode
        let p = g.location(in: scnView)
        let hits = interactiveHits(at: p)

        // Cron ruler pin/dot → open manager with that job preselected
        if let cron = hits.compactMap({ cronJobHit(from: $0.node) }).first {
            presentCronManager(preselectJobId: cron.jobId)
            hintLabel.stringValue = "Cron · edit job"
            return
        }

        // + pad → choose Add agent or Add flow link
        if let hit = plusHit(from: hits),
           let s = seats.first(where: { $0.globalId == hit.gid }) {
            showPlusMenu(for: s, at: g.location(in: self), kind: hit.kind)
            return
        }

        // Seat cubes (prefer over edges when both under cursor)
        if let gid = hits.compactMap({ seatGlobalId(from: $0.node) }).first,
           let s = seats.first(where: { $0.globalId == gid }) {
            // fall through to seat handling below via rebinding
            handleSeatClick(s, at: g.location(in: self))
            return
        }

        // Click a link → edit sheet (direction, kind, label). Option-click deletes.
        if let edgeKey = hits.compactMap({ edgeId(from: $0.node) }).first {
            let session = linkSession(for: edgeKey)
                ?? seats.first(where: { $0.role != "human" })?.session
            let flowId = parseEdgeKey(edgeKey)?.flowId ?? edgeKey
            if let session {
                if NSEvent.modifierFlags.contains(.option) {
                    FlowGraph.removeEdge(pair: session, id: flowId)
                    hintLabel.stringValue = "Flow link removed"
                    onGraphChanged?()
                    reload(seats: seats, multiTeam: multiTeam)
                } else {
                    openLinkEditor(session: session, edgeId: edgeKey)
                }
            }
            return
        }

        dismissModuleCard()
        linkSourceGid = nil
    }

    private func handleSeatClick(_ s: Seat3D, at point: NSPoint) {
        let gid = s.globalId

        // Human / YOU seat → docked chat under TRACKING
        if s.role == "human" {
            flashSelect(gid)
            openHumanDock(session: s.session)
            onHuman?(s)
            return
        }

        flashSelect(gid)
        showModuleCard(for: s, near: point)
    }

    /// Drag seats (Move mode) or scroll cron ruler (Orbit mode).
    @objc private func handlePan(_ g: NSPanGestureRecognizer) {
        let p = g.location(in: scnView)
        if mapMode == .navigate {
            if g.state == .began || g.state == .changed { markUserInteracting() }
            handleRulerDrag(at: p, state: g.state)
            return
        }
        guard mapMode == .move else {
            applyCameraMode()
            return
        }
        switch g.state {
        case .began:
            markUserInteracting()
            // Prefer seat body over add-pads so pads don’t steal the drag
            guard let gid = hitTestSeatId(at: p),
                  let sn = seatNodes[gid],
                  let s = seats.first(where: { $0.globalId == gid }) else {
                dragGid = nil
                return
            }
            // Lock to this seat’s deck height for the whole gesture
            dragGid = gid
            dragPlaneY = deckY(for: s.role)
            // Snap cube onto its deck immediately
            sn.position = SCNVector3(sn.position.x, dragPlaneY, sn.position.z)
            scnView.allowsCameraControl = false
            hintLabel.stringValue = "Moving \(s.title) · stay on deck · release to save"
        case .changed:
            guard let gid = dragGid, let sn = seatNodes[gid] else { return }
            if let world = projectToPlaneY(point: p, y: dragPlaneY) {
                let lim: CGFloat = 18
                let x = max(-lim, min(lim, world.x))
                let z = max(-lim, min(lim, world.z))
                // Never change Y mid-drag
                sn.position = SCNVector3(x, dragPlaneY, z)
                // Keep flow lines glued to the moving seat (do not wait for mouse-up)
                rebuildFlowEdgesOnly()
            }
        case .ended, .cancelled:
            if let gid = dragGid, let sn = seatNodes[gid],
               let s = seats.first(where: { $0.globalId == gid }) {
                // Final Y snap to deck
                let y = deckY(for: s.role)
                sn.position = SCNVector3(sn.position.x, y, sn.position.z)
                Map3DLayout.save(session: s.session, nodeId: s.id,
                                 x: Float(sn.position.x), z: Float(sn.position.z))
                // Ring follows the seat
                syncPlaneRing(for: s, at: sn.position, active: isSeatActive(s), color: roleColor(s))
                hintLabel.stringValue = "Saved position · Move mode still on"
            }
            dragGid = nil
            applyCameraMode()
            // Must rebuild edges: reload() early-outs when seat status signature is unchanged
            rebuildFlowEdgesOnly()
            requestMapRender()
        default: break
        }
    }

    /// Deck height for each role (Move mode never leaves this plane).
    private func deckY(for role: String) -> CGFloat {
        switch role {
        case "conductor": return CGFloat(yConductor)
        case "human": return CGFloat(yHuman)
        case "subagent": return CGFloat(ySub)
        default: return CGFloat(yWorker)
        }
    }

    private func projectToPlaneY(point: NSPoint, y: CGFloat) -> SCNVector3? {
        let near = scnView.unprojectPoint(SCNVector3(point.x, point.y, 0))
        let far = scnView.unprojectPoint(SCNVector3(point.x, point.y, 1))
        let dx = far.x - near.x
        let dy = far.y - near.y
        let dz = far.z - near.z
        if abs(dy) < 1e-5 { return nil }
        let t = (y - near.y) / dy
        let wx = near.x + dx * t
        let wz = near.z + dz * t
        return SCNVector3(wx, y, wz)
    }

    /// Floating 2D module (classic canvas card). Open button / double-click → terminal.
    private func showModuleCard(for s: Seat3D, near point: NSPoint) {
        dismissModuleCard()
        moduleSeat = s
        let role = s.role == "subagent" ? "worker" : s.role
        // Orchestrator: show team display name over the seat (not seat id)
        let teamLab: String = {
            if s.role == "conductor" { return teamDisplayName(for: s.session) }
            return multiTeam ? teamDisplayName(for: s.session) : ""
        }()
        let model = AgentNodeModel(
            session: s.session, id: s.id, role: role,
            title: s.title, subtitle: s.subtitle, detail: s.detail,
            status: s.status, teamLabel: teamLab,
            accent: roleColor(s), origin: .zero
        )
        let card = AgentNodeView(model: model)
        // Expanded map-click card (readable task detail)
        card.setFrameSize(AgentNodeView.moduleSize)
        card.onFront = { [weak self] _ in
            guard let self, let seat = self.moduleSeat else { return }
            self.onOpen?(seat)
        }
        card.onFocus = { [weak self] _ in
            guard let self, let seat = self.moduleSeat else { return }
            self.onFocus?(seat)
        }
        card.onRename = { [weak self] _ in
            guard let self, let seat = self.moduleSeat else { return }
            self.onRename?(seat)
        }
        card.onKill = { [weak self] _ in
            guard let self, let seat = self.moduleSeat else { return }
            self.dismissModuleCard()
            self.onKill?(seat)
        }
        card.onOptions = { [weak self] _ in
            guard let self, let seat = self.moduleSeat else { return }
            self.onOptions?(seat)
        }
        card.onPerms = { [weak self] _ in
            guard let self, let seat = self.moduleSeat else { return }
            self.onPerms?(seat)
        }
        card.onChangeModel = { [weak self] _ in
            guard let self, let seat = self.moduleSeat else { return }
            self.onChangeModel?(seat)
        }
        // Host with thin chrome + close
        let pad: CGFloat = 12
        let host = NSView(frame: NSRect(
            x: 0, y: 0,
            width: AgentNodeView.moduleSize.width + pad * 2,
            height: AgentNodeView.moduleSize.height + pad * 2 + 24
        ))
        host.wantsLayer = true
        host.layer?.backgroundColor = PongTheme.bgElevated.cgColor
        host.layer?.cornerRadius = 6
        host.layer?.borderWidth = 1
        host.layer?.borderColor = PongSheetChrome.lime.withAlphaComponent(0.4).cgColor
        host.layer?.shadowColor = NSColor.black.cgColor
        host.layer?.shadowOpacity = 0.55
        host.layer?.shadowRadius = 18
        host.layer?.shadowOffset = .zero

        let cap = NSTextField(labelWithString: "MODULE  ·  Pencil renames  ·  Open → terminal only")
        cap.font = PongTheme.labelFont(9)
        cap.textColor = PongSheetChrome.limeDim
        cap.frame = NSRect(x: pad, y: host.bounds.height - 18, width: 260, height: 14)
        host.addSubview(cap)

        let close = NSButton(frame: NSRect(x: host.bounds.width - 28, y: host.bounds.height - 22, width: 22, height: 18))
        close.title = "✕"
        close.bezelStyle = .inline
        close.isBordered = false
        close.font = PongTheme.font(11)
        close.contentTintColor = PongTheme.textSecondary
        close.target = self
        close.action = #selector(dismissModuleCard)
        host.addSubview(close)

        card.setFrameOrigin(NSPoint(x: pad, y: pad))
        host.addSubview(card)

        // Position near click, clamped
        var origin = NSPoint(x: point.x + 12, y: point.y - host.bounds.height - 8)
        origin.x = min(max(12, origin.x), max(12, bounds.width - host.bounds.width - 12))
        origin.y = min(max(40, origin.y), max(40, bounds.height - host.bounds.height - 12))
        host.setFrameOrigin(origin)
        addSubview(host)
        moduleHost = host
        moduleCard = card
    }

    @objc private func dismissModuleCard() {
        moduleHost?.removeFromSuperview()
        moduleHost = nil
        moduleCard = nil
        moduleSeat = nil
    }

    @objc private func handleRightClick(_ g: NSClickGestureRecognizer) {
        guard g.state == .ended else { return }
        let p = g.location(in: scnView)
        let hits = scnView.hitTest(p, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue])
        guard let node = hits.first?.node,
              let gid = seatGlobalId(from: node),
              let s = seats.first(where: { $0.globalId == gid }) else { return }
        let menu = NSMenu()
        if s.role == "human" {
            menu.addItem(withTitle: "Open human console…", action: #selector(ctxHuman(_:)), keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "Open terminal", action: #selector(ctxOpen(_:)), keyEquivalent: "")
            // Task detail lives in TASKS panel under YOU; keep full intel via menu only if needed
            menu.addItem(withTitle: "Team terminals…", action: #selector(ctxFocus(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Rename…", action: #selector(ctxRename(_:)), keyEquivalent: "")
            if s.role == "conductor" || s.role == "worker" {
                menu.addItem(withTitle: "Add agent (same plane)…", action: #selector(ctxPlus(_:)), keyEquivalent: "")
            }
            if s.role == "subagent" {
                menu.addItem(withTitle: "Add subagent (same level)…", action: #selector(ctxPlus(_:)), keyEquivalent: "")
            }
            if s.role == "worker" {
                menu.addItem(withTitle: "Add subagent (under)…", action: #selector(ctxAddSub(_:)), keyEquivalent: "")
            }
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: s.role == "conductor" ? "Kill team" : "Remove seat",
                         action: #selector(ctxKill(_:)), keyEquivalent: "")
        }
        for item in menu.items {
            item.target = self
            item.representedObject = s.globalId
        }
        NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent ?? NSEvent(), for: scnView)
    }

    @objc private func ctxPlus(_ item: NSMenuItem) {
        guard let gid = item.representedObject as? String,
              let s = seats.first(where: { $0.globalId == gid }) else { return }
        onPlus?(s)
    }

    @objc private func ctxAddSub(_ item: NSMenuItem) {
        guard let gid = item.representedObject as? String,
              let s = seats.first(where: { $0.globalId == gid }) else { return }
        onAddSub?(s)
    }

    @objc private func ctxHuman(_ item: NSMenuItem) {
        guard let gid = item.representedObject as? String,
              let s = seats.first(where: { $0.globalId == gid }) else { return }
        onHuman?(s)
    }

    @objc private func ctxOpen(_ item: NSMenuItem) {
        guard let gid = item.representedObject as? String,
              let s = seats.first(where: { $0.globalId == gid }) else { return }
        onOpen?(s)
    }
    @objc private func ctxFocus(_ item: NSMenuItem) {
        guard let gid = item.representedObject as? String,
              let s = seats.first(where: { $0.globalId == gid }) else { return }
        onFocus?(s)
    }
    @objc private func ctxRename(_ item: NSMenuItem) {
        guard let gid = item.representedObject as? String,
              let s = seats.first(where: { $0.globalId == gid }) else { return }
        onRename?(s)
    }
    @objc private func ctxKill(_ item: NSMenuItem) {
        guard let gid = item.representedObject as? String,
              let s = seats.first(where: { $0.globalId == gid }) else { return }
        onKill?(s)
    }

    private func flashSelect(_ gid: String) {
        guard let n = seatNodes[gid] else { return }
        let up = SCNAction.scale(to: 1.35, duration: 0.08)
        let down = SCNAction.scale(to: 1.0, duration: 0.2)
        n.runAction(SCNAction.sequence([up, down]))
    }

    // MARK: - Data reload

    func reload(seats: [Seat3D], multiTeam: Bool) {
        // Include ephemeral ids so spawn/vanish always rebuilds layout
        var sig = seats.map {
            "\($0.globalId)|\($0.status)|\($0.openJobs)|\($0.title)|\($0.flowHint.prefix(12))|\($0.ephemeral ? "E" : "P")"
        }.joined(separator: ";") + (multiTeam ? "|M" : "|S")
        // Edge identity is NOT captured by the seat fields above. Without this,
        // editing/adding/deleting a flow link leaves the seats unchanged, the
        // signature matches, and the early-out below skips layoutSeats() so the
        // edges never repaint until a seat changes or the app relaunches. Fold a
        // per-session edge signature in so any link mutation invalidates the cache.
        let db = PairState.loadPairsDb()
        for session in Array(Set(seats.filter { $0.role != "human" }.map(\.session))).sorted() {
            let entry = db[session] as? [String: Any] ?? [:]
            let edges = FlowGraph.load(from: entry)
                .map { "\($0.from)>\($0.to):\($0.kind)" }
                .sorted()
            sig += "#\(session):" + edges.joined(separator: ",")
        }
        self.seats = seats
        self.multiTeam = multiTeam
        // Keep open module card in sync (rename / status) without forcing reopen
        syncModuleCard(with: seats)
        // Poll path: skip full graph rebuild when nothing meaningful changed
        sceneLock.lock()
        defer { sceneLock.unlock() }
        if sig == lastSeatsSig, !seatNodes.isEmpty {
            for s in seats {
                if let n = seatNodes[s.globalId] {
                    updateBlobMaterial(n, seat: s)
                }
            }
            reevaluateMapPlaying()
            return
        }
        lastSeatsSig = sig
        layoutSeats()
        requestMapRender()
        reevaluateMapPlaying()
    }

    /// Instant title/detail refresh on the floating kill/open card after rename.
    private func syncModuleCard(with seats: [Seat3D]) {
        guard let seat = moduleSeat, let card = moduleCard else { return }
        guard let fresh = seats.first(where: { $0.globalId == seat.globalId }) else {
            // Seat gone — close card
            dismissModuleCard()
            return
        }
        moduleSeat = fresh
        let role = fresh.role == "subagent" ? "worker" : fresh.role
        let teamLab = fresh.role == "conductor" || multiTeam
            ? teamDisplayName(for: fresh.session) : ""
        let model = AgentNodeModel(
            session: fresh.session, id: fresh.id, role: role,
            title: fresh.title, subtitle: fresh.subtitle, detail: fresh.detail,
            status: fresh.status, teamLabel: teamLab,
            accent: roleColor(fresh), origin: .zero
        )
        card.apply(model)
    }

    /// Optimistic rename — module card + 3D face title update without reopen.
    func applySeatTitle(globalId: String, title: String) {
        guard let i = seats.firstIndex(where: { $0.globalId == globalId }) else { return }
        let prev = seats[i]
        let s = Seat3D(
            session: prev.session, id: prev.id, role: prev.role,
            title: title, subtitle: prev.subtitle, detail: prev.detail,
            status: prev.status, parentId: prev.parentId,
            openJobs: prev.openJobs, flowHint: prev.flowHint,
            missionRole: prev.missionRole, ephemeral: prev.ephemeral,
            accent: prev.accent
        )
        seats[i] = s
        if let n = seatNodes[globalId] {
            // Force face texture rebuild (title is in seatFaceContentKey)
            n.setValue(nil as String?, forKey: "lastFaceKey")
            updateBlobMaterial(n, seat: s)
        }
        if moduleSeat?.globalId == globalId {
            moduleSeat = s
            let role = s.role == "subagent" ? "worker" : s.role
            let teamLab = s.role == "conductor" || multiTeam
                ? teamDisplayName(for: s.session) : ""
            moduleCard?.apply(AgentNodeModel(
                session: s.session, id: s.id, role: role,
                title: title, subtitle: s.subtitle, detail: s.detail,
                status: s.status, teamLabel: teamLab,
                accent: roleColor(s), origin: .zero
            ))
        }
        lastSeatsSig = ""
        requestMapRender()
    }

    /// Call from camera/pan gestures — defers poll work until idle.
    func markUserInteracting() {
        isUserInteracting = true
        requestMapRender()
        interactionIdleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.isUserInteracting = false
        }
        interactionIdleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func layoutSeats() {
        let keep = Set(seats.map(\.globalId))
        for (id, n) in seatNodes where !keep.contains(id) {
            n.removeFromSuperviewHierarchy()
            n.removeFromParentNode()
            seatNodes[id] = nil
            removePlaneRing(for: id)
        }
        // Diff edges below — do NOT tear down all packets every 2.5s (that froze flow motion).

        // Only team seats for clustering (exclude the single shared YOU)
        let teamSeats = seats.filter { $0.role != "human" }
        let sessions = Array(Set(teamSeats.map(\.session))).sorted()
        var allLinks: [FlowLink3D] = []
        var desiredSigs: [String: String] = [:]
        /// Pending connect jobs after all seats are placed (so positions are final).
        var pendingEdges: [(from: SCNNode, to: SCNNode, link: FlowLink3D, pi: Int, pc: Int, sig: String)] = []

        for (ti, session) in sessions.enumerated() {
            let team = teamSeats.filter { $0.session == session }
            let ox = multiTeam ? Float(ti) * 10.0 - Float(max(0, sessions.count - 1)) * 5.0 : 0
            let conds = team.filter { $0.role == "conductor" }
            let workers = team.filter { $0.role == "worker" }
            let subs = team.filter { $0.role == "subagent" }

            for (i, s) in conds.enumerated() {
                var pos = SCNVector3(ox + Float(i) * 2.2, yConductor, 0)
                if let p = Map3DLayout.load(session: s.session, nodeId: s.id) {
                    pos = SCNVector3(p.x, yConductor, p.z)
                }
                placeBlob(s, at: pos)
            }
            for (i, s) in workers.enumerated() {
                let angle = Float(i) / Float(max(1, workers.count)) * Float.pi * 2 - Float.pi / 2
                let r: Float = 3.2 + Float(workers.count) * 0.15
                var pos = SCNVector3(ox + cos(angle) * r, yWorker, sin(angle) * r)
                if let p = Map3DLayout.load(session: s.session, nodeId: s.id) {
                    pos = SCNVector3(p.x, yWorker, p.z)
                }
                placeBlob(s, at: pos)
            }
            // Group subs by parent so siblings fan out (not one global angle)
            var subByParent: [String: [Seat3D]] = [:]
            for s in subs {
                let key = s.parentId ?? "_orphan"
                subByParent[key, default: []].append(s)
            }
            for (parentKey, group) in subByParent {
                let parent = parentKey == "_orphan"
                    ? nil
                    : seatNodes["\(session)::\(parentKey)"]
                let base = parent?.position ?? SCNVector3(ox, yWorker, 0)
                let bx = Float(base.x), bz = Float(base.z)
                for (i, s) in group.enumerated() {
                    let angle = Float(i) / Float(max(1, group.count)) * Float.pi * 1.4 - 0.7
                    let radius: Float = s.ephemeral ? 1.55 : 1.4
                    var px = bx + cos(angle) * radius
                    var pz = bz + sin(angle) * radius
                    // Ephemeral seats never load sticky layout — they orbit the parent
                    if !s.ephemeral, let p = Map3DLayout.load(session: s.session, nodeId: s.id) {
                        px = p.x; pz = p.z
                    }
                    placeBlob(s, at: SCNVector3(px, ySub, pz))
                }
            }

            // Topology for THIS session only — endpoints use current seat node positions
            appendSessionEdges(
                session: session, team: team, subs: subs,
                allLinks: &allLinks, desiredSigs: &desiredSigs, pendingEdges: &pendingEdges
            )
        }

        // Single YOU cube — parked on the orchestrator the human console is wired to
        // (dropdown / humanSession), not a guessed “primary” team.
        if let human = seats.first(where: { $0.role == "human" }) {
            let homeSession = linkedHumanOrchSession(fallbackSeatSession: human.session)
            // Keep console state in sync without clobbering a valid dropdown choice
            if humanSession.isEmpty, !homeSession.isEmpty {
                humanSession = homeSession
            }
            let orch = seats.first(where: { $0.session == homeSession && $0.role == "conductor" })
                ?? seats.first(where: { $0.role == "conductor" })
            let orchNode = orch.flatMap { seatNodes[$0.globalId] }
            let baseX: Float = orchNode.map { Float($0.position.x) } ?? 0
            let baseZ: Float = orchNode.map { Float($0.position.z) } ?? 0
            var pos = SCNVector3(baseX, yHuman, baseZ)
            // Layout key is global YOU — not per-team (one human for all teams)
            if let p = Map3DLayout.load(session: homeSession, nodeId: human.id) {
                let dx = p.x - baseX, dz = p.z - baseZ
                // Only honor saved offset when it still sits near this orch; otherwise snap home
                if dx * dx + dz * dz < 16 {
                    pos = SCNVector3(p.x, yHuman, p.z)
                }
            }
            placeBlob(human, at: pos)
            if let orch, let from = seatNodes[human.globalId], let to = seatNodes[orch.globalId] {
                let edgeKey = "you>\(orch.session)|\(orch.id)"
                // Packets only when *this* linked team needs you (or post-Send linger)
                let need = sessionNeedsHuman(orch.session)
                let flowing = linkFlowing(id: edgeKey, liveNow: need)
                let link = FlowLink3D(
                    id: edgeKey,
                    fromGid: human.globalId, toGid: orch.globalId,
                    label: need ? "NEEDS YOU" : "YOU",
                    kind: .claim, active: flowing, human: true,
                    fromRole: "human"
                )
                allLinks.append(link)
                let sig = edgeSignature(link: link, from: from, to: to, parallelIndex: 0, parallelCount: 1)
                desiredSigs[link.id] = sig
                pendingEdges.append((from, to, link, 0, 1, sig))
            }
            // Do NOT set humanSession = human.session here — that overwrote the console
            // dropdown and rewired YOU to the wrong orchestrator every poll.
        }

        commitPendingEdges(desiredSigs: desiredSigs, pendingEdges: pendingEdges)
        lastLinks = allLinks
        refreshTrackingList()
        reloadHumanOrchPicker()
        if humanExpanded { reloadHumanInbox() }
        reloadTaskRecap()
        reloadCronTimeline()
    }

    /// Rebuild flow lines from **current** seat node positions without re-placing seats.
    /// Used while dragging so links stay glued to the moved agent.
    private func rebuildFlowEdgesOnly() {
        var allLinks: [FlowLink3D] = []
        var desiredSigs: [String: String] = [:]
        var pendingEdges: [(from: SCNNode, to: SCNNode, link: FlowLink3D, pi: Int, pc: Int, sig: String)] = []
        let teamSeats = seats.filter { $0.role != "human" }
        let sessions = Array(Set(teamSeats.map(\.session))).sorted()
        for session in sessions {
            let team = teamSeats.filter { $0.session == session }
            let subs = team.filter { $0.role == "subagent" }
            appendSessionEdges(
                session: session, team: team, subs: subs,
                allLinks: &allLinks, desiredSigs: &desiredSigs, pendingEdges: &pendingEdges
            )
        }
        // YOU ↔ orch
        if let human = seats.first(where: { $0.role == "human" }),
           let from = seatNodes[human.globalId] {
            let homeSession = linkedHumanOrchSession(fallbackSeatSession: human.session)
            let orch = seats.first(where: { $0.session == homeSession && $0.role == "conductor" })
                ?? seats.first(where: { $0.role == "conductor" })
            if let orch, let to = seatNodes[orch.globalId] {
                let edgeKey = "you>\(orch.session)|\(orch.id)"
                let need = sessionNeedsHuman(orch.session)
                let flowing = linkFlowing(id: edgeKey, liveNow: need)
                let link = FlowLink3D(
                    id: edgeKey, fromGid: human.globalId, toGid: orch.globalId,
                    label: need ? "NEEDS YOU" : "YOU",
                    kind: .claim, active: flowing, human: true, fromRole: "human"
                )
                allLinks.append(link)
                let sig = edgeSignature(link: link, from: from, to: to, parallelIndex: 0, parallelCount: 1)
                desiredSigs[link.id] = sig
                pendingEdges.append((from, to, link, 0, 1, sig))
            }
        }
        commitPendingEdges(desiredSigs: desiredSigs, pendingEdges: pendingEdges)
        lastLinks = allLinks
        requestMapRender()
    }

    private func appendSessionEdges(
        session: String,
        team: [Seat3D],
        subs: [Seat3D],
        allLinks: inout [FlowLink3D],
        desiredSigs: inout [String: String],
        pendingEdges: inout [(from: SCNNode, to: SCNNode, link: FlowLink3D, pi: Int, pc: Int, sig: String)]
    ) {
        let seatIds = Set(team.map(\.id))
        let entry = PairState.loadPairsDb()[session] as? [String: Any] ?? [:]
        let graphEdges = FlowGraph.load(from: entry).filter {
            seatIds.contains($0.from) && seatIds.contains($0.to)
        }
        var pairBuckets: [String: Int] = [:]
        func pairKey(_ a: String, _ b: String) -> String {
            [a, b].sorted().joined(separator: "|")
        }
        for ge in graphEdges {
            guard let fromSeat = team.first(where: { $0.id == ge.from }),
                  let toSeat = team.first(where: { $0.id == ge.to }),
                  let fn = seatNodes[fromSeat.globalId],
                  let tn = seatNodes[toSeat.globalId] else { continue }
            let human = toSeat.status.lowercased().contains("human")
                || fromSeat.status.lowercased().contains("human")
            let liveNow = linkHasLiveData(from: fromSeat, to: toSeat)
            let edgeKey = "\(session)|\(ge.id)"
            let flowing = linkFlowing(id: edgeKey, liveNow: liveNow)
            var label = ge.label
            if human && ge.kind == "claim" { label = "NEEDS YOU" }
            else if flowing, !toSeat.flowHint.isEmpty, ge.kind == "delegate" {
                label = "\(ge.kind.uppercased()) · \(String(toSeat.flowHint.prefix(18)).uppercased())"
            }
            let kind: FlowLink3D.Kind = {
                switch ge.kind {
                case "peer": return .peer
                case "sub": return .sub
                case "claim", "reply": return .claim
                default: return .delegate
                }
            }()
            let link = FlowLink3D(
                id: edgeKey, fromGid: fromSeat.globalId, toGid: toSeat.globalId,
                label: label, kind: kind, active: flowing, human: human,
                fromRole: fromSeat.role
            )
            allLinks.append(link)
            let pk = pairKey(ge.from, ge.to)
            let idx = pairBuckets[pk] ?? 0
            pairBuckets[pk] = idx + 1
            let total = graphEdges.filter { pairKey($0.from, $0.to) == pk }.count
            let sig = edgeSignature(link: link, from: fn, to: tn, parallelIndex: idx, parallelCount: max(1, total))
            desiredSigs[edgeKey] = sig
            pendingEdges.append((fn, tn, link, idx, max(1, total), sig))
        }
        for s in subs where s.ephemeral {
            guard let pid = s.parentId,
                  let fromSeat = team.first(where: { $0.id == pid })
                    ?? seats.first(where: { $0.session == session && $0.id == pid }),
                  let fn = seatNodes[fromSeat.globalId],
                  let tn = seatNodes[s.globalId] else { continue }
            let edgeKey = "\(session)|eph-sub:\(pid)>\(s.id)"
            let hint = s.flowHint.isEmpty
                ? "SUB · SPAWN"
                : "SUB · \(String(s.flowHint.prefix(16)).uppercased())"
            let liveNow = linkHasLiveData(from: fromSeat, to: s)
            let flowing = linkFlowing(id: edgeKey, liveNow: liveNow)
            let link = FlowLink3D(
                id: edgeKey, fromGid: fromSeat.globalId, toGid: s.globalId,
                label: hint, kind: .sub, active: flowing, human: false,
                fromRole: fromSeat.role
            )
            allLinks.append(link)
            let pk = pairKey(pid, s.id)
            let idx = pairBuckets[pk] ?? 0
            pairBuckets[pk] = idx + 1
            let sig = edgeSignature(link: link, from: fn, to: tn, parallelIndex: idx, parallelCount: idx + 1)
            desiredSigs[edgeKey] = sig
            pendingEdges.append((fn, tn, link, idx, max(1, idx + 1), sig))
        }
    }

    private func commitPendingEdges(
        desiredSigs: [String: String],
        pendingEdges: [(from: SCNNode, to: SCNNode, link: FlowLink3D, pi: Int, pc: Int, sig: String)]
    ) {
        let desiredIds = Set(desiredSigs.keys)
        for oldId in Array(edgeSigs.keys) where !desiredIds.contains(oldId) {
            removeEdgeNodes(for: oldId)
            edgeSigs[oldId] = nil
            edgeFlowExpire[oldId] = nil
        }
        for job in pendingEdges {
            if edgeSigs[job.link.id] == job.sig, edgeNodes[job.link.id] != nil {
                continue
            }
            removeEdgeNodes(for: job.link.id)
            connect(from: job.from, to: job.to, link: job.link,
                    parallelIndex: job.pi, parallelCount: job.pc)
            edgeSigs[job.link.id] = job.sig
        }
    }

    /// Stable signature so reload can leave unchanged edges (and their packet actions) intact.
    private func edgeSignature(link: FlowLink3D, from: SCNNode, to: SCNNode,
                               parallelIndex: Int, parallelCount: Int) -> String {
        func q(_ v: CGFloat) -> Int { Int((Float(v) * 20).rounded()) }
        let a = from.position, b = to.position
        return [
            link.id, link.label, link.kind.rawValue,
            link.active ? "1" : "0", link.human ? "1" : "0", link.fromRole,
            "\(q(a.x)),\(q(a.y)),\(q(a.z))",
            "\(q(b.x)),\(q(b.y)),\(q(b.z))",
            "\(parallelIndex)/\(parallelCount)",
        ].joined(separator: "|")
    }

    private func removeEdgeNodes(for linkId: String) {
        let suffixes = ["", ":arr", ":plate", ":lbl", ":pkt", ":pkt1", ":pkt2"]
        for s in suffixes {
            let key = s.isEmpty ? linkId : linkId + s
            edgeNodes[key]?.removeFromParentNode()
            edgeNodes[key] = nil
        }
        // Any extra packet keys
        for k in edgeNodes.keys where k.hasPrefix(linkId + ":pkt") {
            edgeNodes[k]?.removeFromParentNode()
            edgeNodes[k] = nil
        }
        edgeBaseRadius[linkId] = nil
    }

    /// Redesign markers: hex orch · cube agent · tri sub · octa human.
    /// v23: **one** info path for every seat — SCNPlane card on +Z, upright bake, no geometry UV.
    private func placeBlob(_ s: Seat3D, at pos: SCNVector3) {
        let shapeKey: String = {
            // v24: per-primitive info-card fit (hex/tri/cube face-inset, no bleed)
            switch s.role {
            case "conductor": return "hex-v24"
            case "subagent": return s.ephemeral ? "tri-eph-v24" : "tri-v24"
            case "human": return "octa-v24"
            default: return "cube-v24"
            }
        }()
        if let existing = seatNodes[s.globalId] {
            let hasMenu = existing.childNode(withName: "plus-menu:\(s.globalId)", recursively: true) != nil
            let shapeOK = (existing.value(forKey: "mapShape") as? String) == shapeKey
            if shapeOK, (s.role == "human" || hasMenu) {
                let yaw = existing.eulerAngles.y
                existing.position.x = pos.x
                existing.position.z = pos.z
                existing.eulerAngles.y = yaw
                existing.setValue(Float(pos.y), forKey: "baseY")
                updateBlobMaterial(existing, seat: s)
                syncPlaneRing(for: s, at: pos, active: isSeatActive(s), color: roleColor(s))
                return
            }
            existing.removeFromParentNode()
            seatNodes[s.globalId] = nil
            removePlaneRing(for: s.globalId)
        }
        let root = SCNNode()
        root.name = "seat:\(s.globalId)"
        root.position = pos
        root.categoryBitMask = Self.hitInteractive
        root.setValue(shapeKey, forKey: "mapShape")

        let isHuman = s.role == "human"
        let active = isSeatActive(s)
        let full = roleColor(s)
        let bodyCol = PongTheme.mapNodeBody.withAlphaComponent(1.0)
        let height: Float
        let plusX: Float
        let body: SCNNode
        let shell: SCNNode

        // Info card: sized to each primitive’s actual front face (inset), never larger than the wall.
        // Primitive body size is unchanged — only the card plane fits inside the silhouette.
        let faceW: CGFloat
        let faceH: CGFloat
        let faceZ: Float
        let faceY: Float
        // Shared inset: leave edge line visible around the card
        let cardInset: CGFloat = 0.90

        switch s.role {
        case "conductor":
            height = 2.0; plusX = 1.55
            let radius: Float = 1.4
            let sides = 6
            // Regular N-gon: front wall width = chord between adjacent verts = 2 R sin(π/N)
            // Hex (N=6): chord = R. Never use > chord or the plane bleeds past the wire.
            let chord = 2 * radius * sin(.pi / Float(sides))
            let apothem = radius * cos(.pi / Float(sides))
            faceW = CGFloat(chord) * cardInset
            faceH = CGFloat(height) * cardInset
            faceZ = apothem + 0.045
            faceY = height * 0.5
            let g = regularPrism(sides: sides, radius: radius, height: height, frontFace: nil, bodyColor: bodyCol)
            body = SCNNode(geometry: g)
            body.name = "body"
            body.position = SCNVector3(0, height * 0.5, 0)
            shell = SCNNode(geometry: prismEdgeLines(sides: sides, radius: radius + 0.02, height: height + 0.02))
            shell.position = body.position
            shell.geometry?.materials = [unlitEdge(full, active: active)]
        case "subagent":
            let ephScale: Float = s.ephemeral ? 0.78 : 1.0
            height = 1.5 * ephScale; plusX = 1.4 * ephScale
            let radius: Float = 1.25 * ephScale
            let sides = 3
            // Triangle wall is wide (chord = R√3); still inset so edges read
            let chord = 2 * radius * sin(.pi / Float(sides))
            let apothem = radius * cos(.pi / Float(sides))
            faceW = CGFloat(chord) * 0.82   // tri is pointy — more horizontal inset
            faceH = CGFloat(height) * cardInset
            faceZ = apothem + 0.055
            faceY = height * 0.5
            let g = regularPrism(sides: sides, radius: radius, height: height, frontFace: nil, bodyColor: bodyCol)
            body = SCNNode(geometry: g)
            body.name = "body"
            body.position = SCNVector3(0, height * 0.5, 0)
            shell = SCNNode(geometry: prismEdgeLines(sides: sides, radius: radius + 0.03, height: height + 0.02))
            shell.position = body.position
            shell.geometry?.materials = [unlitEdge(full, active: active || s.ephemeral)]
        case "human":
            height = 1.1; plusX = 0
            let r: Float = 1.1
            let g = octahedronBody(radius: r, bodyColor: bodyCol)
            body = SCNNode(geometry: g)
            body.name = "body"
            body.position = SCNVector3(0, 0, 0)
            shell = SCNNode(geometry: octahedronEdgeLines(radius: r + 0.02))
            shell.position = body.position
            shell.geometry?.materials = [unlitEdge(full, active: false)]
            addYouRadialGlow(to: root, color: full)
            faceW = 0; faceH = 0; faceZ = 0; faceY = 0
        default:
            // Cube: full front square, slight inset
            height = 1.9; plusX = 1.15
            let side: Float = 1.9
            faceW = CGFloat(side) * cardInset
            faceH = CGFloat(side) * cardInset
            faceZ = side * 0.5 + 0.035
            faceY = height * 0.5
            let box = SCNBox(width: CGFloat(side), height: CGFloat(side), length: CGFloat(side), chamferRadius: 0)
            let sideMat = unlitBody(bodyCol)
            box.materials = [sideMat, sideMat, sideMat, sideMat, sideMat, sideMat]
            body = SCNNode(geometry: box)
            body.name = "body"
            body.position = SCNVector3(0, height * 0.5, 0)
            shell = SCNNode(geometry: boxEdgeLines(half: side * 0.5 + 0.02))
            shell.position = body.position
            shell.geometry?.materials = [unlitEdge(full, active: active)]
        }

        body.categoryBitMask = Self.hitInteractive
        shell.name = "shell"
        shell.categoryBitMask = Self.hitInteractive
        body.renderingOrder = 0
        shell.renderingOrder = 1
        root.addChildNode(body)
        root.addChildNode(shell)

        // ONE info card path: SCNPlane on +Z for orch / agent / sub
        if !isHuman, faceW > 0.1, faceH > 0.1 {
            let faceImg = seatFaceImage(for: s, faceW: faceW, faceH: faceH)
            let card = makeInfoCardPlane(image: faceImg, width: faceW, height: faceH)
            card.position = SCNVector3(0, faceY, faceZ)
            root.addChildNode(card)
            root.setValue(Float(faceH), forKey: "faceBaseH")
            root.setValue(Float(faceW), forKey: "faceBaseW")
            root.setValue(false, forKey: "faceOnBody")
        }

        if isHuman {
            let label = makeHumanTitleNode()
            label.position = SCNVector3(0, 1.35, 0)
            label.constraints = [SCNBillboardConstraint()]
            root.addChildNode(label)
        }
        // Floating team display name above each orchestrator (always visible, billboarded)
        if s.role == "conductor" {
            attachTeamTitle(to: root, seat: s, color: full)
        }
        root.setValue(s.role, forKey: "seatRole")

        // Drop line to plane (short)
        let drop = SCNBox(width: 0.025, height: CGFloat(0.08), length: 0.025, chamferRadius: 0)
        drop.materials = [unlitBody(full.withAlphaComponent(0.55))]
        let dropN = SCNNode(geometry: drop)
        dropN.position = SCNVector3(0, 0.04, 0)
        dropN.categoryBitMask = Self.hitDecor
        root.addChildNode(dropN)

        // Active ground ring on the deck plane (sibling of seat, does not bob)
        syncPlaneRing(for: s, at: pos, active: active, color: full)

        // Small floating + pad (beside solid, camera-facing) — all seats except human
        if !isHuman {
            let plus = makePlusDisc(name: "plus-menu:\(s.globalId)")
            plus.position = SCNVector3(plusX + 0.45, Float(body.position.y) * 0.55, 0.15)
            plus.constraints = [SCNBillboardConstraint()]
            root.addChildNode(plus)
        }

        root.setValue(active, forKey: "pulsing")
        root.setValue(isHuman, forKey: "human")
        root.setValue(full, forKey: "roleColor")
        root.setValue(Float(pos.y), forKey: "baseY")
        root.setValue(s.globalId, forKey: "gid")
        // Flow-line surface stop (outer extent of this primitive)
        let surfR: Float
        let surfHH: Float
        let bodyCY: Float
        switch s.role {
        case "conductor":
            surfR = 1.32; surfHH = 1.0; bodyCY = Float(pos.y) + 1.0
        case "subagent":
            surfR = 1.05; surfHH = 0.72; bodyCY = Float(pos.y) + 0.75
        case "human":
            surfR = 0.95; surfHH = 0.95; bodyCY = Float(pos.y)
        default:
            surfR = 0.96; surfHH = 0.96; bodyCY = Float(pos.y) + 0.95
        }
        root.setValue(surfR, forKey: "surfR")
        root.setValue(surfHH, forKey: "surfHH")
        root.setValue(bodyCY, forKey: "bodyCenterY")

        rootNode.addChildNode(root)
        seatNodes[s.globalId] = root
        updateBlobMaterial(root, seat: s)
    }

    /// Soft amber radial glow under YOU — horizontal rings (looks correct while octa spins).
    private func addYouRadialGlow(to root: SCNNode, color: NSColor) {
        // Concentric soft rings = design “light behind / around”, not a spinning plane
        let rings: [(CGFloat, CGFloat, CGFloat)] = [
            (0.15, 1.0, 0.28),
            (1.0, 2.0, 0.14),
            (2.0, 3.2, 0.06),
        ]
        for (i, ring) in rings.enumerated() {
            let tube = SCNTube(innerRadius: ring.0, outerRadius: ring.1, height: 0.015)
            let m = SCNMaterial()
            m.diffuse.contents = color.withAlphaComponent(ring.2 * 0.7)
            m.emission.contents = color.withAlphaComponent(ring.2)
            m.lightingModel = .constant
            m.isDoubleSided = true
            m.writesToDepthBuffer = false
            m.transparency = 0.55
            tube.materials = [m]
            let n = SCNNode(geometry: tube)
            n.name = i == 0 ? "youHalo" : "youHalo-\(i)"
            n.position = SCNVector3(0, -0.55, 0)
            n.renderingOrder = -5
            n.categoryBitMask = Self.hitDecor
            root.addChildNode(n)
        }
    }

    // MARK: - Plane-locked active rings (do not bob with the solid)

    private func removePlaneRing(for gid: String) {
        planeRings[gid]?.removeFromParentNode()
        planeRings[gid] = nil
    }

    private func syncPlaneRing(for s: Seat3D, at pos: SCNVector3, active: Bool, color: NSColor) {
        let gid = s.globalId
        if !active {
            removePlaneRing(for: gid)
            return
        }
        // Ring sits on the layer plane under the seat (base Y), never follows bob.
        let planeY = pos.y + 0.03
        if let ring = planeRings[gid] {
            ring.position = SCNVector3(pos.x, planeY, pos.z)
            if let mat = ring.geometry?.firstMaterial {
                mat.diffuse.contents = color.withAlphaComponent(0.45)
            }
            return
        }
        let tube = SCNTube(innerRadius: 2.1, outerRadius: 2.32, height: 0.02)
        let rm = SCNMaterial()
        rm.diffuse.contents = color.withAlphaComponent(0.45)
        rm.emission.contents = color.withAlphaComponent(0.55) // bloom on active ring
        rm.lightingModel = .constant
        rm.isDoubleSided = true
        rm.writesToDepthBuffer = false
        tube.materials = [rm]
        let rn = SCNNode(geometry: tube)
        rn.name = "workRing:\(gid)"
        rn.position = SCNVector3(pos.x, planeY, pos.z)
        rn.categoryBitMask = Self.hitDecor
        rootNode.addChildNode(rn)
        planeRings[gid] = rn
    }

    private func unlitBody(_ c: NSColor, doubleSided: Bool = false) -> SCNMaterial {
        let m = SCNMaterial()
        // SceneKit: transparency 0 = invisible, 1 = opaque (opposite of "alpha").
        // Slight glass: ~12% see-through (SceneKit transparency 1=opaque)
        m.diffuse.contents = c.withAlphaComponent(0.92)
        m.emission.contents = NSColor.black
        m.lightingModel = .constant
        m.isDoubleSided = doubleSided
        m.writesToDepthBuffer = true
        m.readsFromDepthBuffer = true
        m.transparency = 0.90
        return m
    }
    /// Face material for the single SCNPlane card path (v23).
    /// Art is drawn in Quartz Y-up (name bottom, glyph top). SCNPlane UVs match that
    /// with identity transform — no V-flip games.
    private func unlitFace(_ img: NSImage) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = img
        m.diffuse.contentsTransform = SCNMatrix4Identity
        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .clamp
        m.diffuse.magnificationFilter = .linear
        m.diffuse.minificationFilter = .linear
        m.emission.contents = NSColor.black
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = true
        m.transparency = 1.0
        m.cullMode = .back
        return m
    }

    /// Front info card: full face rect, coplanar with solid (+Z). Parent yaws to camera.
    private func makeInfoCardPlane(image: NSImage, width: CGFloat, height: CGFloat) -> SCNNode {
        let plane = SCNPlane(width: max(0.25, width), height: max(0.25, height))
        plane.materials = [unlitFace(image)]
        let n = SCNNode(geometry: plane)
        n.name = "face"
        n.eulerAngles = SCNVector3(0, 0, 0)
        n.scale = SCNVector3(1, 1, 1)
        n.renderingOrder = 25
        n.categoryBitMask = Self.hitInteractive
        n.setValue(Float(height), forKey: "faceBaseH")
        n.setValue(Float(width), forKey: "faceBaseW")
        n.constraints = nil
        return n
    }

    /// Floating "HUMAN" title above the octahedron (billboarded).
    private func makeHumanTitleNode() -> SCNNode {
        let img = NSImage(size: NSSize(width: 220, height: 48))
        img.lockFocusFlipped(true)
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 220, height: 48).fill()
        let s = "HUMAN" as NSString
        let attr: [NSAttributedString.Key: Any] = [
            .font: PongTheme.mono(22, weight: .bold),
            .foregroundColor: PongTheme.amber,
            .kern: 3.0,
        ]
        let sz = s.size(withAttributes: attr)
        s.draw(at: NSPoint(x: (220 - sz.width) / 2, y: (48 - sz.height) / 2), withAttributes: attr)
        img.unlockFocus()
        let plane = SCNPlane(width: 1.4, height: 0.32)
        let m = SCNMaterial()
        m.diffuse.contents = img
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        plane.materials = [m]
        let n = SCNNode(geometry: plane)
        n.name = "human-title"
        n.renderingOrder = 30
        return n
    }

    /// Truncate team labels for floating orch titles (~18–24 chars).
    private func truncateTeamLabel(_ raw: String, maxChars: Int = 22) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "Team" }
        if t.count <= maxChars { return t }
        return String(t.prefix(max(4, maxChars - 1))) + "…"
    }

    private func teamTitleContentKey(for s: Seat3D) -> String {
        let name = teamDisplayName(for: s.session)
        // Theme + seat accent hash so rename / light-dark / neon flip refresh the pill
        let accentTag = s.accent.map { String(describing: $0) } ?? "role"
        return "team|\(s.session)|\(name)|\(mapIsDark)|\(accentTag)"
    }

    /// Attach or refresh the billboarded team name above a conductor hex.
    private func attachTeamTitle(to root: SCNNode, seat: Seat3D, color: NSColor) {
        let key = teamTitleContentKey(for: seat)
        if (root.value(forKey: "lastTeamTitleKey") as? String) == key,
           root.childNode(withName: "team-title", recursively: false) != nil {
            return
        }
        root.childNode(withName: "team-title", recursively: false)?.removeFromParentNode()
        let name = truncateTeamLabel(teamDisplayName(for: seat.session))
        let label = makeTeamTitleNode(name: name, color: color)
        // Hex body top ≈ local y 2.0 — float just above, not occluding the face
        label.position = SCNVector3(0, 2.52, 0)
        label.constraints = [SCNBillboardConstraint()]
        root.addChildNode(label)
        root.setValue(key, forKey: "lastTeamTitleKey")
    }

    /// Elegant pill + kerned mono team name (dark/light readable).
    /// Integer plane sizes + retina bitmap; hide when camera is far (see updateDecorLabelVisibility).
    private func makeTeamTitleNode(name: String, color: NSColor) -> SCNNode {
        let img = teamTitleImage(name: name, color: color)
        // Snap world size to 0.05 steps — avoid fractional shimmer
        let rawW = min(3.0, max(1.55, CGFloat(name.count) * 0.105 + 0.55))
        let planeW = (rawW * 20).rounded() / 20
        let planeH: CGFloat = 0.35
        let plane = SCNPlane(width: planeW, height: planeH)
        let m = SCNMaterial()
        m.diffuse.contents = img
        m.emission.contents = img
        m.emission.intensity = 0.28
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        m.diffuse.magnificationFilter = .linear
        m.diffuse.minificationFilter = .linear
        m.diffuse.mipFilter = .none
        m.emission.magnificationFilter = .linear
        m.emission.minificationFilter = .linear
        m.emission.mipFilter = .none
        plane.materials = [m]
        let n = SCNNode(geometry: plane)
        n.name = "team-title"
        n.renderingOrder = 32
        n.categoryBitMask = Self.hitDecor
        n.setValue(Float(planeH), forKey: "labelWorldH")
        return n
    }

    private func teamTitleImage(name: String, color: NSColor) -> NSImage {
        let attr: [NSAttributedString.Key: Any] = [
            .font: PongTheme.mono(20, weight: .semibold),
            .foregroundColor: color,
            .kern: 1.6,
        ]
        let text = name as NSString
        let textSz = text.size(withAttributes: attr)
        let padX: CGFloat = 18
        let w = max(120, ceil(textSz.width) + padX * 2)
        let h: CGFloat = 44
        return rasterLabelImage(pointSize: NSSize(width: w, height: h)) { _ in
            NSColor.clear.setFill()
            NSRect(x: 0, y: 0, width: w, height: h).fill()
            let pill = NSRect(x: 2, y: 4, width: w - 4, height: h - 8)
            let path = NSBezierPath(roundedRect: pill, xRadius: 10, yRadius: 10)
            if mapIsDark {
                NSColor(calibratedWhite: 0.04, alpha: 0.82).setFill()
            } else {
                NSColor(calibratedWhite: 1.0, alpha: 0.90).setFill()
            }
            path.fill()
            color.withAlphaComponent(mapIsDark ? 0.55 : 0.45).setStroke()
            path.lineWidth = 1
            path.stroke()
            let tx = floor((w - textSz.width) / 2)
            let ty = floor((h - textSz.height) / 2)
            text.draw(at: NSPoint(x: tx, y: ty), withAttributes: attr)
        }
    }

    /// 2× retina bitmap at integer pixel sizes so SCNPlane text stays sharp.
    private func rasterLabelImage(pointSize: NSSize, draw: (CGFloat) -> Void) -> NSImage {
        let scale: CGFloat = 2
        let pw = max(2, Int(ceil(pointSize.width * scale)))
        let ph = max(2, Int(ceil(pointSize.height * scale)))
        let ptW = CGFloat(pw) / scale
        let ptH = CGFloat(ph) / scale
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pw,
            pixelsHigh: ph,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(size: NSSize(width: ptW, height: ptH))
        }
        rep.size = NSSize(width: ptW, height: ptH)
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            ctx.imageInterpolation = .high
            draw(scale)
        }
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: NSSize(width: ptW, height: ptH))
        img.addRepresentation(rep)
        return img
    }

    /// YOU card: triangle coplanar with the upper-front octahedron facet (inclined diamond face).
    /// Parent this node to the **body** so it spins/tilts with the solid.
    private func makeTriangularHumanCard(image: NSImage, radius: Float) -> SCNNode {
        let r = radius
        // Upper-front facet of regular octahedron: top · +X · +Z (inclined)
        let top = SIMD3<Float>(0, r, 0)
        let px = SIMD3<Float>(r, 0, 0)
        let pz = SIMD3<Float>(0, 0, r)
        let center = (top + px + pz) / 3
        var nrm = simd_normalize(simd_cross(px - top, pz - top))
        if nrm.z < 0 { nrm = -nrm }  // outward toward +Z hemisphere
        // Inset toward face center, then float slightly along normal so it never z-fights
        let inset: Float = 0.14
        let pop: Float = 0.05
        func corner(_ v: SIMD3<Float>) -> SCNVector3 {
            let p = v + (center - v) * inset + nrm * pop
            return SCNVector3(CGFloat(p.x), CGFloat(p.y), CGFloat(p.z))
        }
        // Winding: top → +X → +Z for outward normal
        let verts: [SCNVector3] = [corner(top), corner(px), corner(pz)]
        // UV: apex (top) = top-center of image; +X = bottom-right; +Z = bottom-left
        // (swap L/R if text mirrors — apex-up upright for YOU/HUMAN/IDLE)
        let uvs: [SIMD2<Float>] = [
            SIMD2(0.5, 1.0),  // top / apex
            SIMD2(1.0, 0.0),  // +X base R
            SIMD2(0.0, 0.0),  // +Z base L
        ]
        let indices: [Int32] = [0, 1, 2]
        let posSrc = SCNGeometrySource(vertices: verts)
        let uvData = uvs.withUnsafeBufferPointer { Data(buffer: $0) }
        let uvSrc = SCNGeometrySource(
            data: uvData,
            semantic: .texcoord,
            vectorCount: uvs.count,
            usesFloatComponents: true,
            componentsPerVector: 2,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD2<Float>>.stride
        )
        let elem = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geo = SCNGeometry(sources: [posSrc, uvSrc], elements: [elem])
        let triImg = triangularFaceImage(from: image)
        geo.materials = [unlitFace(triImg)]
        let n = SCNNode(geometry: geo)
        n.name = "face"
        n.renderingOrder = 20
        n.categoryBitMask = Self.hitInteractive
        // Approx face height for min-screen-size scaling
        let faceH = simd_length(top - (px + pz) * 0.5) * (1 - inset)
        n.setValue(faceH, forKey: "faceBaseH")
        n.setValue(faceH, forKey: "faceBaseW")
        return n
    }

    /// Clip face texture to an upright triangle (apex up) so the mesh edge matches content.
    private func triangularFaceImage(from img: NSImage) -> NSImage {
        let size = img.size
        let w = max(1, Int(size.width.rounded()))
        let h = max(1, Int(size.height.rounded()))
        let out = NSImage(size: NSSize(width: w, height: h))
        out.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: CGFloat(w) * 0.5, y: CGFloat(h) - 2))
        path.line(to: NSPoint(x: 2, y: 2))
        path.line(to: NSPoint(x: CGFloat(w) - 2, y: 2))
        path.close()
        path.addClip()
        // Soft dark plate behind content so card reads against the void
        NSColor(calibratedRed: 0.027, green: 0.043, blue: 0.059, alpha: 0.92).setFill()
        path.fill()
        img.draw(
            in: NSRect(x: 0, y: 0, width: w, height: h),
            from: NSRect(origin: .zero, size: size),
            operation: .sourceOver,
            fraction: 1.0
        )
        out.unlockFocus()
        return out
    }

    /// Far-zoom face: big role icon only (no status/name text).
    private func faceIconOnlyImage(for s: Seat3D, size: CGFloat = 256) -> NSImage {
        let key = "icon|\(seatFaceContentKey(s, size: size))"
        if let c = faceImageCache[key] { return c }
        let w = size, h = size
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        NSColor(calibratedRed: 0.027, green: 0.043, blue: 0.059, alpha: 0.92).setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        let full = roleColor(s)
        full.setFill()
        NSRect(x: 0, y: 0, width: 6, height: h).fill()
        // Large centered glyph
        let ink = NSColor(calibratedRed: 0.933, green: 0.957, blue: 0.969, alpha: 1)
        ink.setStroke()
        let gPath = NSBezierPath()
        gPath.lineWidth = max(4, w * 0.03)
        gPath.lineCapStyle = .round
        gPath.lineJoinStyle = .round
        let cx = w * 0.5, cy = h * 0.5
        if s.role == "human" {
            gPath.appendOval(in: NSRect(x: cx - 18, y: cy + 8, width: 36, height: 36))
            gPath.move(to: NSPoint(x: cx - 36, y: cy - 28))
            gPath.curve(to: NSPoint(x: cx + 36, y: cy - 28),
                        controlPoint1: NSPoint(x: cx - 24, y: cy + 4),
                        controlPoint2: NSPoint(x: cx + 24, y: cy + 4))
            gPath.stroke()
        } else if s.role == "conductor" {
            gPath.appendOval(in: NSRect(x: cx - 40, y: cy - 40, width: 80, height: 80))
            gPath.appendOval(in: NSRect(x: cx - 18, y: cy - 18, width: 36, height: 36))
            gPath.stroke()
        } else if s.role == "subagent" {
            // small triangle
            gPath.move(to: NSPoint(x: cx, y: cy + 42))
            gPath.line(to: NSPoint(x: cx - 40, y: cy - 36))
            gPath.line(to: NSPoint(x: cx + 40, y: cy - 36))
            gPath.close()
            gPath.stroke()
        } else {
            ("{  }" as NSString).draw(at: NSPoint(x: cx - 48, y: cy - 28), withAttributes: [
                .font: PongTheme.mono(w * 0.22, weight: .bold),
                .foregroundColor: ink,
            ])
        }
        img.unlockFocus()
        faceImageCache[key] = img
        return img
    }

    /// Solid octahedron body only — no face material slots (card is a separate SCNPlane).
    private func octahedronBody(radius: Float, bodyColor: NSColor) -> SCNGeometry {
        let r = radius
        let verts: [SCNVector3] = [
            SCNVector3(0, r, 0), SCNVector3(0, -r, 0),
            SCNVector3(r, 0, 0), SCNVector3(-r, 0, 0),
            SCNVector3(0, 0, r), SCNVector3(0, 0, -r),
        ]
        // 8 triangular faces, outward-ish winding
        let indices: [Int32] = [
            0, 2, 4,  0, 4, 3,  0, 3, 5,  0, 5, 2,
            1, 4, 2,  1, 3, 4,  1, 5, 3,  1, 2, 5,
        ]
        let posSrc = SCNGeometrySource(vertices: verts)
        let elem = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geo = SCNGeometry(sources: [posSrc], elements: [elem])
        geo.materials = [unlitBody(bodyColor, doubleSided: true)]
        return geo
    }
    private func unlitEdge(_ c: NSColor, active: Bool) -> SCNMaterial {
        let m = SCNMaterial()
        // Edges are the main color carrier (prototype idle ~0.8, active full + glow)
        if active {
            m.diffuse.contents = c.withAlphaComponent(0.85)
            m.emission.contents = c.withAlphaComponent(0.50)
        } else {
            m.diffuse.contents = c.withAlphaComponent(0.60)
            m.emission.contents = c.withAlphaComponent(0.08)
        }
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = true
        return m
    }

    /// One draw call for plane dots (replaces hundreds of SCNSphere nodes).
    private func pointCloudGeometry(vertices: [SCNVector3], pointSize: CGFloat) -> SCNGeometry {
        let vertexSource = SCNGeometrySource(vertices: vertices)
        var indices = [Int32](0..<Int32(vertices.count))
        let indexData = Data(bytes: &indices, count: indices.count * MemoryLayout<Int32>.size)
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .point,
            primitiveCount: vertices.count,
            bytesPerIndex: MemoryLayout<Int32>.size
        )
        element.pointSize = pointSize
        element.minimumPointScreenSpaceRadius = 1
        element.maximumPointScreenSpaceRadius = pointSize
        return SCNGeometry(sources: [vertexSource], elements: [element])
    }

    /// Line segments as true `.line` primitives — silhouette only, no face diagonals.
    private func lineGeometry(segments: [(SCNVector3, SCNVector3)]) -> SCNGeometry {
        var positions: [SCNVector3] = []
        var indices: [Int32] = []
        for (a, b) in segments {
            let i = Int32(positions.count)
            positions.append(a)
            positions.append(b)
            indices.append(contentsOf: [i, i + 1])
        }
        let src = SCNGeometrySource(vertices: positions)
        let elem = SCNGeometryElement(indices: indices, primitiveType: .line)
        return SCNGeometry(sources: [src], elements: [elem])
    }

    private func boxEdgeLines(half: Float) -> SCNGeometry {
        let h = half
        let c: [SCNVector3] = [
            SCNVector3(-h, -h, -h), SCNVector3(h, -h, -h), SCNVector3(h, -h, h), SCNVector3(-h, -h, h),
            SCNVector3(-h, h, -h), SCNVector3(h, h, -h), SCNVector3(h, h, h), SCNVector3(-h, h, h),
        ]
        let edges: [(Int, Int)] = [
            (0, 1), (1, 2), (2, 3), (3, 0),
            (4, 5), (5, 6), (6, 7), (7, 4),
            (0, 4), (1, 5), (2, 6), (3, 7),
        ]
        return lineGeometry(segments: edges.map { (c[$0.0], c[$0.1]) })
    }

    private func prismEdgeLines(sides: Int, radius: Float, height: Float) -> SCNGeometry {
        let h2 = height * 0.5
        let sideF = Float(sides)
        var bot: [SCNVector3] = []
        var top: [SCNVector3] = []
        // Same orientation as regularPrism — flat front on +Z
        for i in 0..<sides {
            let aa = Float(i) / sideF * Float.pi * 2 + Float.pi / 2 - Float.pi / sideF
            let x = cos(aa) * radius
            let z = sin(aa) * radius
            bot.append(SCNVector3(x, -h2, z))
            top.append(SCNVector3(x, h2, z))
        }
        var segs: [(SCNVector3, SCNVector3)] = []
        for i in 0..<sides {
            let j = (i + 1) % sides
            segs.append((bot[i], bot[j]))
            segs.append((top[i], top[j]))
            segs.append((bot[i], top[i]))
        }
        return lineGeometry(segments: segs)
    }

    private func octahedronEdgeLines(radius: Float) -> SCNGeometry {
        let r = radius
        let top = SCNVector3(0, r, 0)
        let bot = SCNVector3(0, -r, 0)
        let px = SCNVector3(r, 0, 0)
        let nx = SCNVector3(-r, 0, 0)
        let pz = SCNVector3(0, 0, r)
        let nz = SCNVector3(0, 0, -r)
        // 12 outer edges only (no face diagonals — octahedron faces are already triangles)
        let segs: [(SCNVector3, SCNVector3)] = [
            (top, px), (top, nx), (top, pz), (top, nz),
            (bot, px), (bot, nx), (bot, pz), (bot, nz),
            (px, pz), (pz, nx), (nx, nz), (nz, px),
        ]
        return lineGeometry(segments: segs)
    }

    /// Regular octahedron with two front facets (+Z upper/lower) carrying the info texture.
    private func octahedronWithFrontFace(radius: Float, faceImage: NSImage, bodyColor: NSColor) -> SCNGeometry {
        let r = radius
        // 0 top · 1 bot · 2 +x · 3 -x · 4 +z · 5 -z
        let verts: [SCNVector3] = [
            SCNVector3(0, r, 0), SCNVector3(0, -r, 0),
            SCNVector3(r, 0, 0), SCNVector3(-r, 0, 0),
            SCNVector3(0, 0, r), SCNVector3(0, 0, -r),
        ]
        // Body: all faces except the single largest upper-front diamond (E1/D3)
        let bodyOnly: [Int32] = [
            0, 3, 5,  0, 5, 2,   // upper back
            1, 5, 3,  1, 2, 5,   // lower back
            1, 4, 2,  1, 3, 4,   // lower front
        ]
        // UV: flip U so text reads correctly (was mirrored on the solid)
        func uv(_ v: SCNVector3) -> SIMD2<Float> {
            SIMD2(1 - (Float(v.x) / r + 1) * 0.5, (1 - Float(v.y) / r) * 0.5)
        }
        let frontCorners: [[Int]] = [
            [0, 2, 4], [0, 4, 3], // upper front only
        ]
        var frontPositions: [SCNVector3] = []
        var frontUVs: [SIMD2<Float>] = []
        for tri in frontCorners {
            for vi in tri {
                frontPositions.append(verts[vi])
                frontUVs.append(uv(verts[vi]))
            }
        }
        var merged = verts
        let frontBase = Int32(merged.count)
        merged.append(contentsOf: frontPositions)
        var mergedUV = [SIMD2<Float>](repeating: .zero, count: verts.count)
        mergedUV.append(contentsOf: frontUVs)
        let frontMergedIdx = (0..<frontPositions.count).map { frontBase + Int32($0) }

        let posSrc = SCNGeometrySource(vertices: merged)
        let uvData = mergedUV.withUnsafeBufferPointer { Data(buffer: $0) }
        let uvSrc = SCNGeometrySource(
            data: uvData,
            semantic: .texcoord,
            vectorCount: mergedUV.count,
            usesFloatComponents: true,
            componentsPerVector: 2,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD2<Float>>.stride
        )
        let faceElem = SCNGeometryElement(indices: frontMergedIdx, primitiveType: .triangles)
        let restElem = SCNGeometryElement(indices: bodyOnly, primitiveType: .triangles)
        let geo = SCNGeometry(sources: [posSrc, uvSrc], elements: [faceElem, restElem])
        let faceMat = unlitFace(faceImage)
        faceMat.isDoubleSided = false
        geo.materials = [faceMat, unlitBody(bodyColor, doubleSided: true)]
        return geo
    }

    /// Regular N-gon prism (hex orch · tri sub). Optional frontFace kept for legacy; v23 uses SCNPlane.
    private func regularPrism(sides: Int, radius: Float, height: Float,
                              frontFace: NSImage? = nil, bodyColor: NSColor = .black) -> SCNGeometry {
        var positions: [SCNVector3] = []
        var uvs: [SIMD2<Float>] = []
        let h2 = height * 0.5
        let sideF = Float(sides)
        // Orient so face 0 (between vert 0 and 1) has outward normal +Z
        for i in 0..<sides {
            let aa = Float(i) / sideF * Float.pi * 2 + Float.pi / 2 - Float.pi / sideF
            let x = cos(aa) * radius
            let z = sin(aa) * radius
            positions.append(SCNVector3(x, -h2, z))
            uvs.append(.zero)
        }
        for i in 0..<sides {
            let aa = Float(i) / sideF * Float.pi * 2 + Float.pi / 2 - Float.pi / sideF
            let x = cos(aa) * radius
            let z = sin(aa) * radius
            positions.append(SCNVector3(x, h2, z))
            uvs.append(.zero)
        }

        // Front face UVs: panel on wall 0, inset ~8%, slightly extruded +Z so card is visible
        var b0 = positions[0], b1 = positions[1]
        var t0v = positions[sides], t1v = positions[sides + 1]
        let midx = (b0.x + b1.x + t0v.x + t1v.x) * 0.25
        let midy = (b0.y + b1.y + t0v.y + t1v.y) * 0.25
        let midz = (b0.z + b1.z + t0v.z + t1v.z) * 0.25
        let amt: CGFloat = 0.08
        let zPop: CGFloat = 0.04
        func insetCorner(_ v: SCNVector3) -> SCNVector3 {
            let x = v.x + (midx - v.x) * amt
            let y = v.y + (midy - v.y) * amt
            let z = v.z + (midz - v.z) * amt + zPop
            return SCNVector3(x, y, z)
        }
        b0 = insetCorner(b0); b1 = insetCorner(b1); t0v = insetCorner(t0v); t1v = insetCorner(t1v)
        let fBase = Int32(positions.count)
        // Outward winding for +Z wall. UVs: (0,0)=bottom-left → (1,1)=top-right of face art
        // (contentsTransform flips V for CGImage top-left)
        positions.append(contentsOf: [b0, b1, t1v, t0v])
        uvs.append(contentsOf: [
            SIMD2(0, 0), // b0 bottom-left
            SIMD2(1, 0), // b1 bottom-right
            SIMD2(1, 1), // t1 top-right
            SIMD2(0, 1), // t0 top-left
        ])
        let frontIdx: [Int32] = [fBase, fBase + 1, fBase + 2, fBase, fBase + 2, fBase + 3]

        var bodyIdx: [Int32] = []
        // Side walls: CCW when viewed from outside (outward normals). Skip side 0 (front strip).
        for i in 1..<sides {
            let bb0 = Int32(i)
            let bb1 = Int32((i + 1) % sides)
            let tt0 = Int32(i + sides)
            let tt1 = Int32((i + 1) % sides + sides)
            // bottom→top winding: bb0, bb1, tt1 / bb0, tt1, tt0
            bodyIdx.append(contentsOf: [bb0, bb1, tt1, bb0, tt1, tt0])
        }
        let base = Int32(sides)
        // Caps: bottom facing -Y, top facing +Y
        for i in 1..<(sides - 1) {
            bodyIdx.append(contentsOf: [0, Int32(i + 1), Int32(i)]) // bottom, flip for -Y
            bodyIdx.append(contentsOf: [base, base + Int32(i), base + Int32(i + 1)]) // top +Y
        }

        let posSrc = SCNGeometrySource(vertices: positions)
        let uvData = uvs.withUnsafeBufferPointer { Data(buffer: $0) }
        let uvSrc = SCNGeometrySource(
            data: uvData,
            semantic: .texcoord,
            vectorCount: uvs.count,
            usesFloatComponents: true,
            componentsPerVector: 2,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD2<Float>>.stride
        )
        let faceElem = SCNGeometryElement(indices: frontIdx, primitiveType: .triangles)
        let restElem = SCNGeometryElement(indices: bodyIdx, primitiveType: .triangles)
        let geo = SCNGeometry(sources: [posSrc, uvSrc], elements: [faceElem, restElem])
        if let frontFace {
            let fm = unlitFace(frontFace)
            fm.isDoubleSided = false
            geo.materials = [fm, unlitBody(bodyColor, doubleSided: true)]
        } else {
            // Both elements solid body — info card is a separate SCNPlane (v23)
            let m = unlitBody(bodyColor, doubleSided: true)
            geo.materials = [m, m]
        }
        return geo
    }

    /// Neutral + disc — design: ~21px-feel disc, bg rgba(9,13,17,0.72), border, + #c3ced4.
    private func makePlusDisc(name: String) -> SCNNode {
        let root = SCNNode()
        root.name = name
        root.categoryBitMask = Self.hitInteractive
        let r: CGFloat = 0.20  // smaller floating pad (designer D4)

        let disc = SCNCylinder(radius: r, height: 0.04)
        let dm = SCNMaterial()
        dm.diffuse.contents = NSColor(calibratedRed: 0.035, green: 0.051, blue: 0.067, alpha: 0.92)
        dm.emission.contents = NSColor.black
        dm.lightingModel = .constant
        disc.materials = [dm]
        let dn = SCNNode(geometry: disc)
        dn.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        dn.name = name
        dn.categoryBitMask = Self.hitInteractive
        root.addChildNode(dn)

        let rim = SCNTube(innerRadius: r - 0.015, outerRadius: r, height: 0.03)
        let rm = SCNMaterial()
        rm.diffuse.contents = NSColor(calibratedRed: 0.63, green: 0.69, blue: 0.73, alpha: 0.45)
        rm.emission.contents = NSColor.black
        rm.lightingModel = .constant
        rim.materials = [rm]
        let rn = SCNNode(geometry: rim)
        rn.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        rn.name = name
        rn.categoryBitMask = Self.hitInteractive
        root.addChildNode(rn)

        let img = plusGlyphImage()
        let pl = SCNPlane(width: r * 1.1, height: r * 1.1)
        let pm = SCNMaterial()
        pm.diffuse.contents = img
        pm.emission.contents = NSColor.black
        pm.lightingModel = .constant
        pm.isDoubleSided = true
        pl.materials = [pm]
        let pn = SCNNode(geometry: pl)
        pn.position = SCNVector3(0, 0, 0.03)
        pn.name = name
        pn.categoryBitMask = Self.hitInteractive
        root.addChildNode(pn)
        return root
    }

    private func plusGlyphImage() -> NSImage {
        let s: CGFloat = 64
        let img = NSImage(size: NSSize(width: s, height: s))
        img.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: s, height: s).fill()
        // stroke #c3ced4
        NSColor(calibratedRed: 0.765, green: 0.808, blue: 0.831, alpha: 1).setStroke()
        let p = NSBezierPath()
        p.lineWidth = 4
        p.lineCapStyle = .round
        p.move(to: NSPoint(x: s * 0.5, y: s * 0.22))
        p.line(to: NSPoint(x: s * 0.5, y: s * 0.78))
        p.move(to: NSPoint(x: s * 0.22, y: s * 0.5))
        p.line(to: NSPoint(x: s * 0.78, y: s * 0.5))
        p.stroke()
        img.unlockFocus()
        return img
    }

    private func addPadLabelImage(title: String, subtitle: String, tint: NSColor, size: CGFloat) -> NSImage {
        let h = size * 0.58
        let img = NSImage(size: NSSize(width: size, height: h))
        img.lockFocus()
        if mapIsDark {
            NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        } else {
            NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
        }
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: h), xRadius: 8, yRadius: 8).fill()
        tint.withAlphaComponent(0.35).setStroke()
        let border = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1.5, width: size - 3, height: h - 3), xRadius: 7, yRadius: 7)
        border.lineWidth = 1.5
        border.stroke()
        let tAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size * 0.16, weight: .semibold),
            .foregroundColor: mapIsDark
                ? NSColor(calibratedWhite: 0.78, alpha: 1)
                : NSColor(calibratedWhite: 0.2, alpha: 1),
        ]
        let sAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size * 0.09, weight: .medium),
            .foregroundColor: mapIsDark
                ? NSColor(calibratedWhite: 0.48, alpha: 1)
                : NSColor(calibratedWhite: 0.42, alpha: 1),
        ]
        let tw = (title as NSString).size(withAttributes: tAttr)
        let sw = (subtitle as NSString).size(withAttributes: sAttr)
        (title as NSString).draw(at: NSPoint(x: (size - tw.width) / 2, y: h * 0.48), withAttributes: tAttr)
        (subtitle as NSString).draw(at: NSPoint(x: (size - sw.width) / 2, y: h * 0.14), withAttributes: sAttr)
        img.unlockFocus()
        return img
    }

    /// Seat glow / bob / face “ACTIVE” / plane ring pulse.
    /// Same bar as floor dots: only real in-flight work — not queued/sticky “busy”.
    /// When jobs finish (idle), primitives go calm immediately.
    private func isSeatActive(_ s: Seat3D) -> Bool {
        seatIsActivelyWorking(s)
    }

    /// True when a seat is mid-handoff (data actually moving), not merely queued/busy.
    /// Shared with 2D canvas glow via `SeatActivity`.
    private func seatIsActivelyWorking(_ s: Seat3D) -> Bool {
        SeatActivity.isActivelyWorking(status: s.status, role: s.role)
    }

    /// True when this directed link should show traveling packets *now*.
    private func linkHasLiveData(from: Seat3D, to: Seat3D) -> Bool {
        SeatActivity.linkHasLiveData(
            fromStatus: from.status, fromRole: from.role,
            toStatus: to.status, toRole: to.role
        )
    }

    /// Apply linger so a short handoff isn’t a one-frame blip.
    private func linkFlowing(id: String, liveNow: Bool) -> Bool {
        let now = Date().timeIntervalSince1970
        if liveNow {
            edgeFlowExpire[id] = now + flowLingerSec
            return true
        }
        return (edgeFlowExpire[id] ?? 0) > now
    }

    /// Seat accent (neon catalog when set) else role default — use with idle mute.
    private func roleColor(_ s: Seat3D) -> NSColor {
        if s.role == "human" { return PongTheme.amber }
        if s.status.lowercased().contains("human") { return PongTheme.amber }
        if let accent = s.accent { return accent }
        switch s.role {
        case "conductor": return PongTheme.blue
        case "subagent": return PongTheme.violet
        default: return PongTheme.magenta
        }
    }

    /// Idle = grey · Active = full role color.
    private func displayColor(for s: Seat3D) -> NSColor {
        let full = roleColor(s)
        if isSeatActive(s) { return full }
        return mapIsDark
            ? NSColor(calibratedWhite: 0.42, alpha: 1)
            : NSColor(calibratedWhite: 0.48, alpha: 1)
    }

    /// Content key for face image + material early-out (same string for both).
    private func seatFaceContentKey(_ s: Seat3D, size: CGFloat = 256) -> String {
        let active = isSeatActive(s)
        let missionKey = s.role == "human" ? "" : s.missionRole
        return "\(s.globalId)|\(s.role)|\(s.status)|\(s.title)|\(missionKey)|\(active)|\(s.openJobs)|\(String(s.flowHint.prefix(24)))|\(Int(size))"
    }

    /// Role-shaped face texture — aspect matches the primitive face, not a cramped 256×200 strip.
    private func seatFaceImage(for s: Seat3D, faceW: CGFloat, faceH: CGFloat) -> NSImage {
        // Pixel size scales with face aspect (hex tall, cube square, tri medium)
        let maxPx: CGFloat = 320
        let aspect = max(0.35, faceH / max(faceW, 0.01))
        let w: CGFloat
        let h: CGFloat
        if aspect >= 1 {
            h = maxPx
            w = max(160, maxPx / aspect)
        } else {
            w = maxPx
            h = max(160, maxPx * aspect)
        }
        return cubeFaceImage(for: s, pixelW: w, pixelH: h)
    }

    /// Info face layout tuned to the canvas size (orch tall / agent square / sub medium).
    private func cubeFaceImage(for s: Seat3D, size: CGFloat = 256) -> NSImage {
        cubeFaceImage(for: s, pixelW: size, pixelH: size * 200 / 256)
    }

    private func cubeFaceImage(for s: Seat3D, pixelW: CGFloat, pixelH: CGFloat) -> NSImage {
        let active = isSeatActive(s)
        // v23: Quartz Y-up bake for SCNPlane (identity UV)
        let cacheKey = "v23|" + seatFaceContentKey(s, size: pixelW) + "|\(Int(pixelH))"
        if let cached = faceImageCache[cacheKey] { return cached }
        let w = pixelW
        let h = pixelH
        let img = NSImage(size: NSSize(width: w, height: h))
        // Default lockFocus: origin bottom-left, Y up — same as SCNPlane UV
        img.lockFocus()

        NSColor(calibratedRed: 0.027, green: 0.043, blue: 0.059, alpha: 0.96).setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()

        let full = roleColor(s)
        let spineW = max(4, w * 0.028)
        full.setFill()
        NSRect(x: 0, y: 0, width: spineW, height: h).fill()

        let mission = s.role == "human" ? nil : Optional(s.resolvedMission)
        let sk = PongTheme.statusKind(s.status)
        let statusLabel: String = {
            if s.role == "human" {
                return s.status.lowercased().contains("human") ? "LIVE" : "IDLE"
            }
            if active { return "ACTIVE" }
            return "IDLE"
        }()
        _ = sk

        // Y-up layout: high Y = top of face, low Y = bottom (matches SCNPlane)
        // Top → bottom visually: glyph · status · divider · role · name
        let pad = max(10, w * 0.05)
        let ink = NSColor(calibratedRed: 0.933, green: 0.957, blue: 0.969, alpha: 1)
        let stCol = active ? full : NSColor(calibratedRed: 0.435, green: 0.490, blue: 0.522, alpha: 1)

        let stFont = max(11, min(16, w * 0.048))
        let stAttr: [NSAttributedString.Key: Any] = [
            .font: PongTheme.mono(stFont, weight: .semibold),
            .foregroundColor: active ? NSColor(calibratedRed: 0.90, green: 0.93, blue: 0.95, alpha: 1) : stCol,
        ]
        let stSz = (statusLabel as NSString).size(withAttributes: stAttr)
        let stY = h - pad - stSz.height
        let stX = w - pad - stSz.width
        let dotR = max(5, w * 0.022)
        stCol.setFill()
        NSBezierPath(ovalIn: NSRect(x: stX - dotR - 6, y: stY + (stSz.height - dotR) * 0.5,
                                    width: dotR, height: dotR)).fill()
        (statusLabel as NSString).draw(at: NSPoint(x: stX, y: stY), withAttributes: stAttr)

        let gScale = min(w, h) * 0.11
        let cx = pad + spineW + gScale * 1.6
        let cy = h - pad - gScale * 1.6
        ink.setStroke()
        let gPath = NSBezierPath()
        gPath.lineWidth = max(2.5, w * 0.014)
        gPath.lineCapStyle = .round
        gPath.lineJoinStyle = .round
        if s.role == "conductor" || mission == .orchestrator {
            gPath.appendOval(in: NSRect(x: cx - gScale, y: cy - gScale, width: gScale * 2, height: gScale * 2))
            gPath.appendOval(in: NSRect(x: cx - gScale * 0.45, y: cy - gScale * 0.45,
                                        width: gScale * 0.9, height: gScale * 0.9))
            gPath.stroke()
        } else {
            switch mission {
            case .researcher:
                gPath.appendOval(in: NSRect(x: cx - gScale * 0.7, y: cy - gScale * 0.5,
                                            width: gScale * 1.2, height: gScale * 1.2))
                gPath.move(to: NSPoint(x: cx + gScale * 0.35, y: cy - gScale * 0.5))
                gPath.line(to: NSPoint(x: cx + gScale * 0.9, y: cy - gScale))
                gPath.stroke()
            case .reviewer:
                gPath.appendOval(in: NSRect(x: cx - gScale, y: cy - gScale, width: gScale * 2, height: gScale * 2))
                gPath.move(to: NSPoint(x: cx - gScale * 0.45, y: cy))
                gPath.line(to: NSPoint(x: cx - gScale * 0.1, y: cy - gScale * 0.4))
                gPath.line(to: NSPoint(x: cx + gScale * 0.55, y: cy + gScale * 0.35))
                gPath.stroke()
            case .operator:
                gPath.move(to: NSPoint(x: cx, y: cy + gScale * 0.7))
                gPath.line(to: NSPoint(x: cx, y: cy))
                gPath.line(to: NSPoint(x: cx - gScale * 0.65, y: cy - gScale * 0.7))
                gPath.move(to: NSPoint(x: cx, y: cy))
                gPath.line(to: NSPoint(x: cx + gScale * 0.65, y: cy - gScale * 0.7))
                gPath.stroke()
            case .taskRunner:
                // Checklist / discrete job mark
                gPath.appendRoundedRect(
                    NSRect(x: cx - gScale * 0.85, y: cy - gScale * 0.75,
                           width: gScale * 1.7, height: gScale * 1.5),
                    xRadius: gScale * 0.15, yRadius: gScale * 0.15)
                gPath.move(to: NSPoint(x: cx - gScale * 0.45, y: cy + gScale * 0.25))
                gPath.line(to: NSPoint(x: cx - gScale * 0.15, y: cy - gScale * 0.1))
                gPath.line(to: NSPoint(x: cx + gScale * 0.5, y: cy + gScale * 0.45))
                gPath.move(to: NSPoint(x: cx - gScale * 0.45, y: cy - gScale * 0.35))
                gPath.line(to: NSPoint(x: cx + gScale * 0.45, y: cy - gScale * 0.35))
                gPath.stroke()
            default:
                let brace = "{  }" as NSString
                brace.draw(at: NSPoint(x: cx - gScale * 1.1, y: cy - gScale * 0.55), withAttributes: [
                    .font: PongTheme.mono(max(14, w * 0.11), weight: .bold),
                    .foregroundColor: ink,
                ])
            }
        }

        let left = pad + spineW + 6
        let roleLine = s.role == "conductor" ? "ORCHESTRATOR"
            : (mission?.title.uppercased() ?? "AGENT")
        let name = String(s.title.prefix(s.role == "conductor" ? 22 : 18))
        let roleFont = max(10, min(15, w * 0.045))
        let nameFont = max(14, min(28, w * 0.095))
        let rAttr: [NSAttributedString.Key: Any] = [
            .font: PongTheme.mono(roleFont, weight: .semibold),
            .foregroundColor: full,
            .kern: 2.0,
        ]
        let nAttr: [NSAttributedString.Key: Any] = [
            .font: PongTheme.font(nameFont, weight: .bold),
            .foregroundColor: NSColor(calibratedRed: 0.949, green: 0.965, blue: 0.973, alpha: 1),
        ]
        let nameSz = (name as NSString).size(withAttributes: nAttr)
        let roleSz = (roleLine as NSString).size(withAttributes: rAttr)

        // Name at bottom (low Y); role above name; divider above role
        let nameY = pad + max(6, h * 0.03)
        let roleY = nameY + nameSz.height + max(4, h * 0.02)
        let divY = roleY + roleSz.height + max(6, h * 0.025)
        NSColor(calibratedRed: 0.51, green: 0.59, blue: 0.60, alpha: 0.22).setFill()
        NSRect(x: left, y: divY, width: w - left - pad, height: 1).fill()
        (roleLine as NSString).draw(at: NSPoint(x: left, y: roleY), withAttributes: rAttr)
        (name as NSString).draw(at: NSPoint(x: left, y: nameY), withAttributes: nAttr)

        if s.role == "conductor" || h > w * 1.05 {
            let hint = String(s.flowHint.prefix(36))
            if !hint.isEmpty, active {
                let hAttr: [NSAttributedString.Key: Any] = [
                    .font: PongTheme.mono(max(9, w * 0.035), weight: .medium),
                    .foregroundColor: NSColor(calibratedWhite: 0.55, alpha: 1),
                ]
                let hy = divY + 8
                if hy + 14 < cy - gScale {
                    (hint as NSString).draw(at: NSPoint(x: left, y: hy), withAttributes: hAttr)
                }
            }
        }

        img.unlockFocus()
        if faceImageCache.count > 64 {
            faceImageCache.removeAll(keepingCapacity: true)
        }
        faceImageCache[cacheKey] = img
        return img
    }

    private func updateBlobMaterial(_ root: SCNNode, seat: Seat3D) {
        let full = roleColor(seat)
        let active = isSeatActive(seat)
        let human = seat.role == "human" || seat.status.lowercased().contains("human")
        let contentKey = seatFaceContentKey(seat)
        let baseY = (root.value(forKey: "baseY") as? Float) ?? Float(root.position.y)
        let pos = SCNVector3(root.position.x, CGFloat(baseY), root.position.z)

        // Team floating title always tracks display_name / theme (even if face early-outs)
        if seat.role == "conductor" {
            attachTeamTitle(to: root, seat: seat, color: full)
        } else {
            root.childNode(withName: "team-title", recursively: false)?.removeFromParentNode()
            root.setValue(nil as String?, forKey: "lastTeamTitleKey")
        }

        let far = (root.value(forKey: "faceLODFar") as? Bool) ?? false
        let faceKey = "v23|" + contentKey + (far ? "|F" : "|N")
        if (root.value(forKey: "lastFaceKey") as? String) == faceKey {
            syncPlaneRing(for: seat, at: pos, active: active, color: full)
            root.setValue(active, forKey: "pulsing")
            root.setValue(human, forKey: "human")
            root.setValue(full, forKey: "roleColor")
            return
        }

        // v23: refresh the single front SCNPlane card
        if seat.role != "human" {
            let fw = CGFloat((root.value(forKey: "faceBaseW") as? Float) ?? 1.8)
            let fh = CGFloat((root.value(forKey: "faceBaseH") as? Float) ?? 1.8)
            let img = far
                ? faceIconOnlyImage(for: seat)
                : seatFaceImage(for: seat, faceW: fw, faceH: fh)
            if let face = root.childNode(withName: "face", recursively: false),
               let geo = face.geometry as? SCNPlane {
                geo.materials = [unlitFace(img)]
            } else if let face = root.childNode(withName: "face", recursively: true),
                      let geo = face.geometry as? SCNPlane {
                geo.materials = [unlitFace(img)]
            }
        }
        if let shell = root.childNode(withName: "shell", recursively: false),
           let mat = shell.geometry?.firstMaterial {
            if active {
                mat.diffuse.contents = full.withAlphaComponent(0.85)
                mat.emission.contents = full.withAlphaComponent(0.50)
            } else {
                mat.diffuse.contents = full.withAlphaComponent(0.60)
                mat.emission.contents = full.withAlphaComponent(0.08)
            }
        }
        syncPlaneRing(for: seat, at: pos, active: active, color: full)
        root.childNode(withName: "workRing", recursively: false)?.removeFromParentNode()
        root.setValue(active, forKey: "pulsing")
        root.setValue(human, forKey: "human")
        root.setValue(full, forKey: "roleColor")
        root.setValue(faceKey, forKey: "lastFaceKey")
    }

    /// Single texture: chip + label (theme-aware). Integer size + 2× raster.
    private func linkLabelImage(text: String, color: NSColor) -> NSImage {
        let w: CGFloat = max(120, ceil(CGFloat(text.count) * 11 + 28))
        let h: CGFloat = 36
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: color.withAlphaComponent(0.9),
        ]
        let sz = (text as NSString).size(withAttributes: attrs)
        return rasterLabelImage(pointSize: NSSize(width: w, height: h)) { _ in
            if mapIsDark {
                NSColor(calibratedWhite: 0.06, alpha: 0.88).setFill()
            } else {
                NSColor(calibratedWhite: 0.98, alpha: 0.94).setFill()
            }
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: h), xRadius: 5, yRadius: 5).fill()
            (mapIsDark
                ? NSColor(calibratedWhite: 0.35, alpha: 0.5)
                : NSColor(calibratedWhite: 0.2, alpha: 0.35)).setStroke()
            let border = NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: w - 2, height: h - 2), xRadius: 5, yRadius: 5)
            border.lineWidth = 1
            border.stroke()
            let tx = floor((w - sz.width) / 2)
            let ty = floor((h - sz.height) / 2)
            (text as NSString).draw(at: NSPoint(x: tx, y: ty), withAttributes: attrs)
        }
    }

    /// Exit point on the outer surface of a primitive (ellipsoid from body center).
    private func surfaceExit(of root: SCNNode, toward other: SCNVector3) -> SCNVector3 {
        let cx = Float(root.position.x)
        let cz = Float(root.position.z)
        let cy = (root.value(forKey: "bodyCenterY") as? Float) ?? Float(root.position.y)
        let r = (root.value(forKey: "surfR") as? Float) ?? 0.95
        let hh = (root.value(forKey: "surfHH") as? Float) ?? 0.95
        var dx = Float(other.x) - cx
        var dy = Float(other.y) - cy
        var dz = Float(other.z) - cz
        let len = sqrt(dx * dx + dy * dy + dz * dz)
        guard len > 0.01 else { return SCNVector3(cx, cy, cz) }
        dx /= len; dy /= len; dz /= len
        // Ellipsoid (x/r)² + (z/r)² + (y/hh)² = 1 — stops at outer shell
        let invR2 = 1 / max(r * r, 0.01)
        let invH2 = 1 / max(hh * hh, 0.01)
        let a = dx * dx * invR2 + dz * dz * invR2 + dy * dy * invH2
        guard a > 1e-8 else { return SCNVector3(cx, cy, cz) }
        let t = 0.97 / sqrt(a) // just inside the surface so lines don't clip into solid
        return SCNVector3(cx + dx * t, cy + dy * t, cz + dz * t)
    }

    /// Quiet directed lines. parallelIndex offsets loops so A→B and B→A don't stack.
    private func connect(from a: SCNNode, to b: SCNNode, link: FlowLink3D,
                         parallelIndex: Int = 0, parallelCount: Int = 1) {
        // Stop at outer face of each primitive (not deep in the solid)
        var p0 = surfaceExit(of: a, toward: b.position)
        var p1 = surfaceExit(of: b, toward: a.position)
        var dx = p1.x - p0.x, dy = p1.y - p0.y, dz = p1.z - p0.z
        let dist0 = sqrt(dx * dx + dy * dy + dz * dz)
        guard dist0 > 0.01 else { return }

        // Lateral + vertical offset so parallel links never merge when zoomed out.
        // Always apply a small stagger when parallelCount > 1; not too spread (design).
        if parallelCount > 1 {
            let spread: Float = 0.40   // was 0.28 — enough gap after min-width thicken
            let tOff = Float(parallelIndex) - Float(parallelCount - 1) * 0.5
            let fdx = Float(dx), fdz = Float(dz)
            let inv = 1 / Float(dist0)
            let px = (-fdz) * inv * tOff * spread
            let pz = fdx * inv * tOff * spread
            let py = tOff * 0.16
            p0 = SCNVector3(Float(p0.x) + px, Float(p0.y) + py, Float(p0.z) + pz)
            p1 = SCNVector3(Float(p1.x) + px, Float(p1.y) + py, Float(p1.z) + pz)
            dx = p1.x - p0.x; dy = p1.y - p0.y; dz = p1.z - p0.z
        }
        let dist = sqrt(dx * dx + dy * dy + dz * dz)
        guard dist > 0.01 else { return }

        let active = link.active
        let human = link.human
        let isPeer = link.kind == .peer

        // Color from originator: orch blue · agent magenta · human amber
        let originCol: NSColor = {
            switch link.fromRole {
            case "conductor": return PongTheme.blue
            case "human": return PongTheme.amber
            case "subagent": return PongTheme.violet
            default: return PongTheme.magenta
            }
        }()
        // Slimmer base; min projected width enforced per-frame (not sub-pixel, not fat rods).
        let radius: CGFloat = human ? 0.0065 : (active ? 0.0065 : (isPeer ? 0.005 : 0.0055))
        let cyl = SCNCylinder(radius: radius, height: CGFloat(dist))
        let m = SCNMaterial()
        let lineCol: NSColor = {
            if human || link.fromRole == "human" {
                return PongTheme.amber.withAlphaComponent(active ? 0.85 : 0.40)
            }
            // Prototype idle 0.32 / active 0.85 + traveling pulse
            return originCol.withAlphaComponent(active ? 0.85 : 0.32)
        }()
        m.diffuse.contents = lineCol
        m.emission.contents = NSColor.black
        m.lightingModel = .constant
        cyl.materials = [m]

        let n = SCNNode(geometry: cyl)
        n.position = SCNVector3((p0.x + p1.x) / 2, (p0.y + p1.y) / 2, (p0.z + p1.z) / 2)
        let fromV = SIMD3<Float>(0, 1, 0)
        let toV = simd_normalize(SIMD3<Float>(Float(dx), Float(dy), Float(dz)))
        n.simdOrientation = simd_quatf(from: fromV, to: toV)
        n.name = "edge:\(link.id)"
        n.categoryBitMask = Self.hitInteractive
        edgeBaseRadius[link.id] = Float(radius)
        rootNode.addChildNode(n)
        edgeNodes[link.id] = n

        // Prototype has no arrowheads — plain line + traveling pulse only

        // Baked label chip (bg + text one plane) — no floating plate below the words
        let midx = (Float(p0.x) + Float(p1.x)) * 0.5
        let midy = (Float(p0.y) + Float(p1.y)) * 0.5 + 0.16
        let midz = (Float(p0.z) + Float(p1.z)) * 0.5
        let chipImg = linkLabelImage(
            text: link.label,
            color: human || link.fromRole == "human"
                ? PongTheme.amber
                : (active ? originCol : originCol.withAlphaComponent(0.55))
        )
        let rawChipW = max(0.7, CGFloat(link.label.count) * 0.07 + 0.35)
        let chipW = (rawChipW * 20).rounded() / 20
        let chipH: CGFloat = 0.20
        let plate = SCNPlane(width: chipW, height: chipH)
        let plm = SCNMaterial()
        plm.diffuse.contents = chipImg
        plm.emission.contents = NSColor.black
        plm.lightingModel = .constant
        plm.isDoubleSided = true
        plm.diffuse.magnificationFilter = .linear
        plm.diffuse.minificationFilter = .linear
        plm.diffuse.mipFilter = .none
        plate.materials = [plm]
        let plateN = SCNNode(geometry: plate)
        plateN.position = SCNVector3(midx, midy, midz)
        plateN.constraints = [SCNBillboardConstraint()]
        plateN.name = "plate:\(link.id)"
        plateN.setValue(Float(chipH), forKey: "labelWorldH")
        plateN.categoryBitMask = Self.hitInteractive
        // Also name as lbl so click-to-edit still resolves
        let lblProxy = SCNNode()
        lblProxy.name = "lbl:\(link.id)"
        lblProxy.categoryBitMask = Self.hitInteractive
        plateN.addChildNode(lblProxy)
        rootNode.addChildNode(plateN)
        edgeNodes[link.id + ":plate"] = plateN
        edgeNodes[link.id + ":lbl"] = plateN

        // Packets ONLY when the link is live (`link.active`).
        // `human` is styling only (amber line) — never force dots on idle YOU↔orch.
        guard active else { return }
        let pc = (human || link.fromRole == "human") ? PongTheme.amber : originCol
        let ballR: CGFloat = 0.055
        let travel: TimeInterval = human ? 2.6 : 3.0
        let count = 2
        for i in 0..<count {
            let packet = SCNSphere(radius: ballR)
            let pmat = SCNMaterial()
            pmat.diffuse.contents = pc.withAlphaComponent(0.95)
            pmat.emission.contents = pc.withAlphaComponent(0.35)
            pmat.lightingModel = .constant
            packet.materials = [pmat]
            let pn = SCNNode(geometry: packet)
            pn.position = p0
            pn.name = "pkt:\(link.id)"
            pn.opacity = 0.9
            rootNode.addChildNode(pn)
            let move = SCNAction.sequence([
                SCNAction.move(to: p1, duration: travel),
                SCNAction.fadeOut(duration: 0.08),
                SCNAction.move(to: p0, duration: 0.001),
                SCNAction.fadeOpacity(to: 0.9, duration: 0.08),
            ])
            let delay = SCNAction.wait(duration: Double(i) * (travel * 0.45))
            pn.runAction(SCNAction.sequence([delay, SCNAction.repeatForever(move)]))
            edgeNodes[link.id + (i == 0 ? ":pkt" : ":pkt\(i)")] = pn
        }
    }

    // MARK: - Pulse / render-on-demand (designer A1 + A2)

    private var lastPulseTime: TimeInterval = 0
    private var mapNeedsRender = false
    private var lastCronHUDAt: TimeInterval = 0

    /// Call when animation or interaction starts — keeps SceneKit rendering.
    func requestMapRender() {
        mapNeedsRender = true
        if !scnView.isHidden, !isLiveResizing {
            scnView.isPlaying = true
        }
    }

    private func reevaluateMapPlaying() {
        if isLiveResizing || scnView.isHidden {
            scnView.isPlaying = false
            return
        }
        let anyActive = seats.contains { isSeatActive($0) }
        let animating = anyActive || mapNeedsRender || rulerDirty
        scnView.isPlaying = animating
        if !animating { mapNeedsRender = false }
    }

    private func startPulse() {
        // Motion runs in renderer(_:updateAtTime:) — no Timer (A2).
        lastPulseTime = 0
        requestMapRender()
    }

    private func stopPulse() {
        scnView.isPlaying = false
        mapNeedsRender = false
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard window != nil, !scnView.isHidden else { return }
        if isLiveResizing || window?.inLiveResize == true { return }

        if lastPulseTime <= 0 { lastPulseTime = time }
        let dt = min(0.05, max(0, time - lastPulseTime))
        lastPulseTime = time
        // Calm bob rate (design ~1.7 rad/s feel)
        pulsePhase += CGFloat(dt * 1.7)

        // Never block the render queue on a main-thread rebuild — skip a frame instead.
        guard sceneLock.try() else { return }
        advancePulse(now: time)
        if let cam = scnView.pointOfView {
            updateDecorLabelVisibility(camera: cam)
        }
        sceneLock.unlock()
        // Always keep horizon level while user orbits/pans
        keepCameraHorizontal()

        // Drop to 0 fps when nothing animates (A1)
        let anyActive = seats.contains { isSeatActive($0) }
        if !anyActive && !rulerDirty && !mapNeedsRender {
            // Keep a couple frames after gesture end, then sleep
            scnView.isPlaying = false
        }
    }

    /// Hide team titles / link chips when projected height is below ~11–12 screen px
    /// or camera is far — never show blurry subpixel mush.
    private func updateDecorLabelVisibility(camera cam: SCNNode) {
        let camPos = SIMD3<Float>(Float(cam.position.x), Float(cam.position.y), Float(cam.position.z))
        let viewH = max(1, scnView.bounds.height)
        let fovY = Float((cam.camera?.fieldOfView ?? 60) * .pi / 180)
        let tanHalf = tan(fovY * 0.5)
        let minScreenPx: Float = 11.5
        let maxDist: Float = 28

        func screenHeight(worldH: Float, dist: Float) -> Float {
            guard dist > 0.05, tanHalf > 0.01 else { return 999 }
            return (worldH / dist) * Float(viewH) / (2 * tanHalf)
        }

        for root in seatNodes.values {
            guard let title = root.childNode(withName: "team-title", recursively: false) else { continue }
            let wp = title.worldPosition
            let p = SIMD3<Float>(Float(wp.x), Float(wp.y), Float(wp.z))
            let dist = simd_length(p - camPos)
            let worldH = (title.value(forKey: "labelWorldH") as? Float) ?? 0.35
            let px = screenHeight(worldH: worldH, dist: dist)
            title.isHidden = dist > maxDist || px < minScreenPx
        }
        for (key, node) in edgeNodes where key.hasSuffix(":plate") {
            let wp = node.worldPosition
            let p = SIMD3<Float>(Float(wp.x), Float(wp.y), Float(wp.z))
            let dist = simd_length(p - camPos)
            let worldH = (node.value(forKey: "labelWorldH") as? Float) ?? 0.20
            let px = screenHeight(worldH: worldH, dist: dist)
            node.isHidden = dist > maxDist * 0.9 || px < minScreenPx
        }
    }

    private func advancePulse(now time: TimeInterval) {
        let phaseT = Double(pulsePhase)
        let cam = scnView.pointOfView
        let camXZ: (Float, Float)? = cam.map { (Float($0.position.x), Float($0.position.z)) }
        let camMoved: Bool = {
            guard let camXZ, let last = lastCamXZ else { return true }
            let dx = camXZ.0 - last.0, dz = camXZ.1 - last.1
            return dx * dx + dz * dz > 0.0004
        }()
        if let camXZ { lastCamXZ = camXZ }

        // Snapshot values — never mutate the dictionary while iterating if main can rebuild.
        let roots = Array(seatNodes.values)
        for root in roots {
            // Node may have been removed between snapshot and use
            guard root.parent != nil else { continue }
            let pulsing = (root.value(forKey: "pulsing") as? Bool) ?? false
            let isHuman = (root.value(forKey: "human") as? Bool) ?? false
            let phase = Float(root.position.x + root.position.z) * 0.3
            let baseY = (root.value(forKey: "baseY") as? Float) ?? Float(root.position.y)

            // Agents: yaw the solid toward camera (Y-only). Face is coplanar +Z — upright with camera horizon lock.
            if !isHuman, camMoved, let cam {
                let dx = Float(cam.position.x) - Float(root.position.x)
                let dz = Float(cam.position.z) - Float(root.position.z)
                let yaw = atan2(dx, dz)
                root.eulerAngles.y = CGFloat(yaw)
            }

            // Bob argument shared with ring pulse (E4: glow on descent)
            let bobArg = phaseT * 1.7 + Double(phase)
            if pulsing {
                let bob = sin(bobArg) * 0.32
                root.position.y = CGFloat(baseY) + CGFloat(bob)
            } else if !isHuman {
                root.position.y = CGFloat(baseY)
            }

            if isHuman {
                // Spin body (and coplanar face child) + shell
                let spin = CGFloat(phaseT * 0.35)
                root.childNode(withName: "body", recursively: false)?.eulerAngles.y = spin
                root.childNode(withName: "shell", recursively: false)?.eulerAngles.y = spin
                let bob = sin(phaseT * 1.1) * 0.18
                root.position.y = CGFloat(yHuman) + CGFloat(bob)
            }

            if let gid = root.value(forKey: "gid") as? String,
               let ring = planeRings[gid],
               ring.parent != nil,
               let mat = ring.geometry?.firstMaterial,
               let col = root.value(forKey: "roleColor") as? NSColor {
                ring.position.x = root.position.x
                ring.position.z = root.position.z
                ring.position.y = CGFloat(baseY) + 0.03
                if pulsing {
                    let descending = max(0, -cos(bobArg))
                    let a = 0.12 + 0.6 * descending
                    mat.diffuse.contents = col.withAlphaComponent(CGFloat(a))
                    mat.emission.contents = col.withAlphaComponent(CGFloat(a))
                } else {
                    // Work done → settle ring (no leftover “active” glow)
                    mat.diffuse.contents = col.withAlphaComponent(0.08)
                    mat.emission.contents = col.withAlphaComponent(0.02)
                }
            }
            if let shell = root.childNode(withName: "shell", recursively: false),
               let sm = shell.geometry?.firstMaterial,
               let col = root.value(forKey: "roleColor") as? NSColor {
                if pulsing {
                    let a = 0.40 + 0.15 * sin(phaseT * 2.0 + Double(phase))
                    sm.emission.contents = col.withAlphaComponent(CGFloat(a))
                } else if !isHuman {
                    // Calm edge when idle / queued only
                    sm.emission.contents = col.withAlphaComponent(0.06)
                }
            }
        }

        // Flow lines + text LOD (min screen size / icon mode / cron hide)
        scaleFlowLinesForCamera(cam: cam)
        applyMapTextLOD(cam: cam)

        // Expire packet flows without waiting for the next poll
        let now = Date().timeIntervalSince1970
        var expired = false
        for (id, exp) in edgeFlowExpire where exp <= now {
            edgeFlowExpire[id] = nil
            expired = true
        }
        if expired {
            // Next seat reload will rebuild edges without packets; nudge if idle
            lastSeatsSig = ""
            requestMapRender()
        }

        // Structural rebuilds (ruler, materials) only on main — never on render queue.
        if rulerDirty {
            rulerDirty = false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.sceneLock.lock()
                self.rebuildCronRuler()
                self.sceneLock.unlock()
                self.requestMapRender()
            }
        }
        if time - lastCronHUDAt > 8 {
            lastCronHUDAt = time
            DispatchQueue.main.async { [weak self] in
                self?.reloadCronTimeline()
            }
        }
        if !pendingFaceLOD.isEmpty {
            let pending = pendingFaceLOD
            pendingFaceLOD.removeAll(keepingCapacity: true)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.sceneLock.lock()
                defer { self.sceneLock.unlock() }
                for (gid, far) in pending {
                    guard let root = self.seatNodes[gid],
                          let seat = self.seats.first(where: { $0.globalId == gid }) else { continue }
                    root.setValue(far, forKey: "faceLODFar")
                    root.setValue("", forKey: "lastFaceKey")
                    self.updateBlobMaterial(root, seat: seat)
                }
            }
        }
    }

    /// Camera-distance LOD:
    /// - Far: info cards keep **natural size**, texture becomes **icon only** (no text, no grow).
    /// - Near: full card with names; optional mild min-size so text stays readable.
    /// - Cron job labels: hide when far, reappear when closer (dots stay).
    private func applyMapTextLOD(cam: SCNNode?) {
        guard let cam else { return }
        let fovDeg = Float(cam.camera?.fieldOfView ?? 42)
        let fov = max(0.05, fovDeg * .pi / 180)
        let scale = Float(scnView.window?.backingScaleFactor
                          ?? scnView.layer?.contentsScale
                          ?? 2)
        let vh = Float(max(scnView.bounds.height, 1)) * max(scale, 1)
        let halfTan = tan(fov * 0.5)
        let cwx = Float(cam.worldPosition.x)
        let cwy = Float(cam.worldPosition.y)
        let cwz = Float(cam.worldPosition.z)

        func distTo(_ n: SCNNode) -> Float {
            let wp = n.worldPosition
            let dx = Float(wp.x) - cwx, dy = Float(wp.y) - cwy, dz = Float(wp.z) - cwz
            return max(0.2, sqrt(dx * dx + dy * dy + dz * dz))
        }
        func pxWorld(at dist: Float) -> Float {
            (2 * dist * halfTan) / vh
        }

        // Beyond this distance: icon-only face texture (text off).
        let lodFarWorld: Float = 32
        for (gid, root) in seatNodes {
            if (root.value(forKey: "seatRole") as? String) == "human" { continue }
            guard root.childNode(withName: "face", recursively: true) != nil
                    || root.childNode(withName: "body", recursively: false) != nil else { continue }
            let d = distTo(root)
            let far = d > lodFarWorld
            let wasFar = (root.value(forKey: "faceLODFar") as? Bool) ?? false
            if far != wasFar {
                pendingFaceLOD[gid] = far
            }
        }

        // Cron job labels: keep visible longer when zooming out; hide only when truly far.
        // Use distance to the ruler spine (not world origin) so side-on views stay labeled.
        let dxR = cwx - rulerX, dzR = cwz  // ruler along Z at x=rulerX
        let distToRuler = max(0.2, sqrt(dxR * dxR + cwy * cwy + dzR * dzR))
        let showCronText = distToRuler < 78  // was ~40 — allow more zoom-out before fade
        for n in rulerDyn.childNodes {
            if (n.value(forKey: "cronJobLabel") as? Bool) == true {
                n.isHidden = !showCronText
                if showCronText {
                    // Do NOT scale labels up — stacking was measured at scale 1; growth causes overlaps
                    n.scale = SCNVector3(1, 1, 1)
                }
            }
        }

        // Deck labels + link chips: mild min size only (never huge)
        for n in decorRoot.childNodes where (n.name ?? "").hasPrefix("deck-label-") {
            let d = distTo(n)
            let needH = 12 * pxWorld(at: d)
            let s = min(1.9, max(1.0, needH / 0.95))
            n.scale = SCNVector3(CGFloat(s), CGFloat(s), CGFloat(s))
        }
        for (key, n) in edgeNodes where key.hasSuffix(":plate") {
            let d = distTo(n)
            let needH = 11 * pxWorld(at: d)
            let s = min(2.0, max(1.0, needH / 0.22))
            n.scale = SCNVector3(CGFloat(s), CGFloat(s), CGFloat(s))
        }
    }

    /// Per-frame: scale each flow-line cylinder so projected diameter ≥ ~1.6 device pixels.
    /// Soft cap so medium-distance links don't look like rods.
    private func scaleFlowLinesForCamera(cam: SCNNode?) {
        guard let cam else { return }
        let fovDeg = Float(cam.camera?.fieldOfView ?? 42)
        let fov = max(0.05, fovDeg * .pi / 180)
        // Device pixels (retina) — bounds are points; multiply by backing scale
        let scale = Float(scnView.window?.backingScaleFactor
                          ?? scnView.layer?.contentsScale
                          ?? 2)
        let vh = Float(max(scnView.bounds.height, 1)) * max(scale, 1)
        let halfTan = tan(fov * 0.5)
        let minPx: Float = 1.6
        let maxScale: Float = 3.2   // prevent "fat rods" when zoomed far out
        let cwx = Float(cam.worldPosition.x)
        let cwy = Float(cam.worldPosition.y)
        let cwz = Float(cam.worldPosition.z)
        for (key, baseR) in edgeBaseRadius {
            guard baseR > 1e-6, let n = edgeNodes[key] else { continue }
            let wp = n.worldPosition
            let dx = Float(wp.x) - cwx
            let dy = Float(wp.y) - cwy
            let dz = Float(wp.z) - cwz
            let dist = max(0.2, sqrt(dx * dx + dy * dy + dz * dz))
            // world size of 1 device pixel at this distance
            let pxWorld = (2 * dist * halfTan) / vh
            let needR = minPx * pxWorld * 0.5
            let s = min(maxScale, max(1.0, needR / baseR))
            // Cylinder axis = local Y (length); scale XZ only to thicken without lengthening
            n.scale = SCNVector3(CGFloat(s), 1, CGFloat(s))
        }
    }

    func resetCamera() {
        guard let cam = scene.rootNode.childNode(withName: "camera", recursively: false) else { return }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.55
        cam.camera?.fieldOfView = 42
        cam.position = SCNVector3(27, 19, 35)
        cam.look(at: SCNVector3(0, 0.5, 0))
        scnView.pointOfView = cam
        if #available(macOS 10.13, *) {
            scnView.defaultCameraController.pointOfView = cam
            scnView.defaultCameraController.target = SCNVector3(0, 0.5, 0)
            scnView.defaultCameraController.clearRoll()
        }
        SCNTransaction.commit()
    }

    override func layout() {
        super.layout()
        // Hint strip is cheap — always pin under toolbar
        layoutHintStrip()
        // Splitter/HUD must stay above SceneKit after every layout pass
        if leftHUDScroll.superview === self {
            raiseLeftHUDChrome()
        }
        // During live resize, skip HUD reflow (cheap frames); full layout on end.
        if isLiveResizing || window?.inLiveResize == true { return }
        layoutRightHUD()
        // Keep module card on-screen after resize
        if let host = moduleHost {
            var o = host.frame.origin
            o.x = min(max(12, o.x), max(12, bounds.width - host.bounds.width - 12))
            o.y = min(max(40, o.y), max(40, bounds.height - host.bounds.height - 12))
            host.setFrameOrigin(o)
        }
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        isLiveResizing = true
        scnView.isPlaying = false
        if #available(macOS 10.13, *) {
            scnView.preferredFramesPerSecond = 15
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        isLiveResizing = false
        if #available(macOS 10.13, *) {
            scnView.preferredFramesPerSecond = 60
        }
        // Resume only if map canvas is the visible page
        if !scnView.isHidden {
            reevaluateMapPlaying()
        }
        layoutRightHUD()
    }
}

private extension SCNNode {
    func removeFromSuperviewHierarchy() {
        // no-op alias for clarity
    }
}
