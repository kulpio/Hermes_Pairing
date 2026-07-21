import AppKit

// MARK: - Mission roles (who does what on the team)

/// Who does what on a team. Stored as `mission_role` on seats.
/// "Operator" replaced the old "Actor" label (same job: run tools / deploy / browser).
/// "Task runner" is for discrete / scheduled jobs (cron, one-shots) — not a long product thread.
enum MissionRole: String, CaseIterable {
    case orchestrator
    case coder
    case reviewer
    case `operator` = "operator"
    case researcher
    /// Discrete jobs: cron ticks, one-shots, fire-and-claim — not a long product owner.
    case taskRunner = "task_runner"

    /// Parse wire value; accepts legacy `"actor"` and aliases for task runner.
    static func parse(_ raw: String?) -> MissionRole? {
        guard let raw = raw?.lowercased().replacingOccurrences(of: "-", with: "_"),
              !raw.isEmpty else { return nil }
        if raw == "actor" || raw == "ops" || raw == "runner" { return .operator }
        if raw == "orch" || raw == "conductor" { return .orchestrator }
        if raw == "tasks" || raw == "task" || raw == "cron" || raw == "job"
            || raw == "jobs" || raw == "scheduled" || raw == "taskrunner" {
            return .taskRunner
        }
        return MissionRole(rawValue: raw)
    }

    var title: String {
        switch self {
        case .orchestrator: return "Orchestrator"
        case .coder: return "Coder"
        case .reviewer: return "Reviewer"
        case .operator: return "Operator"
        case .researcher: return "Researcher"
        case .taskRunner: return "Task runner"
        }
    }

    /// Short mark for map badges — role language, not robot heads.
    var glyph: String {
        switch self {
        case .orchestrator: return "◎"   // hub / routing center
        case .coder: return "{}"         // code
        case .reviewer: return "✓"       // approve / reject
        case .operator: return "▶"       // run / act
        case .researcher: return "⌕"     // explore
        case .taskRunner: return "◷"     // scheduled / discrete work
        }
    }

    var symbolName: String {
        switch self {
        case .orchestrator: return "point.3.filled.connected.trianglepath.dotted"
        case .coder: return "chevron.left.forwardslash.chevron.right"
        case .reviewer: return "checkmark.seal"
        case .operator: return "play.circle"
        case .researcher: return "magnifyingglass"
        case .taskRunner: return "checklist"
        }
    }

    var blurb: String {
        switch self {
        case .orchestrator:
            return "Plans jobs, routes work, verifies claims. Does not implement product while BRIDGE_ON."
        case .coder:
            return "Implements code, tests, and refactors in the repo."
        case .reviewer:
            return "Reviews diffs and claims; rejects weak evidence."
        case .operator:
            return "Runs tools, deploys, browser, and ops actions within policy."
        case .researcher:
            return "Explores codebase, docs, and (if allowed) web research."
        case .taskRunner:
            return "Runs discrete jobs — cron ticks, one-shots, handoffs. Claim, finish, move on."
        }
    }

    var playbook: String {
        switch self {
        case .orchestrator:
            return "- Decompose the mission into jobs\n- Assign the right worker seat\n- Run acceptance and ledger verdicts"
        case .coder:
            return "- Read the job task + acceptance\n- Edit only what is required\n- Run tests listed in acceptance\n- Claim with evidence"
        case .reviewer:
            return "- Diff against acceptance\n- Flag security, tests, and scope creep\n- Prefer reject with concrete notes over soft accept"
        case .operator:
            return "- Prefer scripted, reversible actions\n- Log every external side effect\n- Stop on policy bans"
        case .researcher:
            return "- Map the codebase first\n- Cite paths and symbols\n- Do not invent APIs"
        case .taskRunner:
            return "- Read the job task only — no freelancing beyond scope\n- Prefer scripted, idempotent steps\n- Claim with evidence when done\n- Ready for the next tick (cron / queue) — do not hold product context"
        }
    }

    static func defaultForWorker(index: Int) -> MissionRole {
        switch index {
        case 0: return .coder
        case 1: return .reviewer
        case 2: return .operator
        case 3: return .taskRunner
        default: return .coder
        }
    }
}

// MARK: - Wizard plan (output)

struct TeamWizardPlan {
    var teamName: String
    var projectRoot: String
    var teamBrief: String
    var conductor: ConductorType
    var conductorLabel: String
    var workers: [WizardWorker]
    var permissions: [String: Any]
    var writeScaffold: Bool
    var installGlobalSkills: Bool
    /// Topology from architecture canvas (optional)
    var flowEdges: [FlowGraph.Edge] = []
    /// One-line mission the orchestrator owns
    var missionGoal: String = ""
    /// Who makes final go/no-go calls
    var decisionMode: String = "orch"   // orch | human | shared
    /// Notify human when agent tasks complete
    var pingOnDone: Bool = true
    /// Orchestrator focuses on goal / routing only (doesn't implement)
    var orchGoalOnly: Bool = true

    struct WizardWorker {
        var type: WorkerType
        var label: String
        var role: MissionRole
        var parentId: String? = nil
    }
}

// MARK: - Scaffold writer

enum TeamScaffold {
    static var bundleTemplates: String {
        if let r = Bundle.main.resourcePath {
            let p = r + "/team-scaffold/templates"
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        // Installed / dev checkouts — never stale ~/src/Agent-Pong
        let home = NSHomeDirectory()
        let candidates = [
            home + "/.pong/lib/team-scaffold/templates",
            home + "/Personal/Projects/HermesPong/share/team-scaffold/templates",
            Bundle.main.bundlePath + "/../../../share/team-scaffold/templates",
        ]
        for c in candidates where FileManager.default.fileExists(atPath: c) { return c }
        return home + "/.pong/lib/team-scaffold/templates"
    }

    static func write(plan: TeamWizardPlan, session: String) {
        let root = (plan.projectRoot as NSString).expandingTildeInPath
        let base = root.isEmpty
            ? (Pong.stateDir + "/teams/" + session)
            : (root + "/.pong")
        let fm = FileManager.default
        try? fm.createDirectory(atPath: base + "/seats", withIntermediateDirectories: true)

        let policyFlags = formatPolicyFlags(plan.permissions)
        let policyNote = (plan.permissions["custom_prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        let seatTable = seatTableMarkdown(plan: plan)
        let bridge: String = {
            switch plan.conductor.id {
            case "grok": return "grok-pong-bridge"
            case "hermes": return "hermes-pong-bridge"
            default: return "pong-bridge"
            }
        }()

        var vars: [String: String] = [
            "TEAM_NAME": plan.teamName.isEmpty ? session : plan.teamName,
            "SESSION": session,
            "PROJECT_ROOT": root.isEmpty ? "(not set)" : root,
            "TEAM_BRIEF": plan.teamBrief.isEmpty
                ? "Ship the mission with clear jobs, claims, and verdicts."
                : plan.teamBrief,
            "SEAT_TABLE": seatTable,
            "POLICY_FLAGS": policyFlags,
            "POLICY_NOTE": policyNote.isEmpty ? "_(none)_" : policyNote,
            "BRIDGE_SKILL": bridge,
        ]

        // TEAM + POLICY + CLI capability map (Claude/Grok/Hermes shortcuts)
        writeTemplate("TEAM.md", to: base + "/TEAM.md", vars: vars)
        writeTemplate("POLICY.md", to: base + "/POLICY.md", vars: vars)
        writeTemplate("CLI-CAPABILITIES.md", to: base + "/CLI-CAPABILITIES.md", vars: vars)

        // Conductor seat
        let cDir = base + "/seats/c1"
        try? fm.createDirectory(atPath: cDir, withIntermediateDirectories: true)
        vars["SEAT_ID"] = "c1"
        vars["SEAT_NAME"] = plan.conductorLabel
        vars["SEAT_TYPE"] = plan.conductor.id
        vars["MISSION_ROLE"] = MissionRole.orchestrator.title
        vars["MISSION_ROLE_BLURB"] = MissionRole.orchestrator.blurb
        vars["ROLE_PLAYBOOK"] = MissionRole.orchestrator.playbook
        vars["DONE_MARKER"] = ""
        writeTemplate("SOUL-conductor.md", to: cDir + "/SOUL.md", vars: vars)
        writeTemplate("SKILL-conductor.md", to: cDir + "/SKILL.md", vars: vars)

        // Workers
        for (i, w) in plan.workers.enumerated() {
            let id = "w\(i + 1)"
            let dir = base + "/seats/\(id)"
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            vars["SEAT_ID"] = id
            vars["SEAT_NAME"] = w.label
            vars["SEAT_TYPE"] = w.type.id
            vars["MISSION_ROLE"] = w.role.title
            vars["MISSION_ROLE_BLURB"] = w.role.blurb
            vars["ROLE_PLAYBOOK"] = w.role.playbook
            vars["DONE_MARKER"] = w.type.id == "claude" ? "##CLAUDE_DONE##" : "##WORKER_DONE##"
            writeTemplate("SOUL-worker.md", to: dir + "/SOUL.md", vars: vars)
            writeTemplate("SKILL-worker.md", to: dir + "/SKILL.md", vars: vars)
        }

        // Pointer for humans
        let readme = """
        # CyberPong team scaffold

        Session: \(session)
        Open TEAM.md for the charter. Seat souls live under seats/.

        Install global conductor skills (once per machine):
          bash scripts/install-skills.sh

        """
        try? readme.write(toFile: base + "/README.md", atomically: true, encoding: .utf8)
        Pong.log("scaffold wrote \(base) seats=\(plan.workers.count + 1)")
    }

    private static func seatTableMarkdown(plan: TeamWizardPlan) -> String {
        var lines: [String] = []
        lines.append("| c1 | \(plan.conductorLabel) | \(plan.conductor.id) | Orchestrator |")
        for (i, w) in plan.workers.enumerated() {
            lines.append("| w\(i + 1) | \(w.label) | \(w.type.id) | \(w.role.title) |")
        }
        return lines.joined(separator: "\n")
    }

    private static func formatPolicyFlags(_ p: [String: Any]) -> String {
        var bans: [String] = []
        if (p["ban_mcp"] as? Bool) == true { bans.append("- ban MCP tools") }
        if (p["ban_network"] as? Bool) == true { bans.append("- ban network / installs") }
        if (p["ban_root"] as? Bool) == true { bans.append("- ban root / sudo") }
        if (p["ban_system_paths"] as? Bool) == true { bans.append("- ban system paths") }
        if (p["repo_only"] as? Bool) == true { bans.append("- repo-only file access") }
        if (p["ask_each"] as? Bool) == true { bans.append("- ask before elevated actions") }
        if bans.isEmpty { return "- Full access for this session (no ban flags)" }
        return bans.joined(separator: "\n")
    }

    private static func writeTemplate(_ name: String, to path: String, vars: [String: String]) {
        let src = bundleTemplates + "/" + name
        var body = (try? String(contentsOfFile: src, encoding: .utf8)) ?? fallbackTemplate(name)
        for (k, v) in vars {
            body = body.replacingOccurrences(of: "{{\(k)}}", with: v)
        }
        try? body.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func fallbackTemplate(_ name: String) -> String {
        "# \(name)\n\n(Template missing — reinstall CyberPong skills / open repo share/team-scaffold.)\n"
    }

    static func installGlobalSkills() {
        let script = Bundle.main.resourcePath.map { $0 + "/../.." } // unused
        _ = script
        let home = NSHomeDirectory()
        let candidates = [
            home + "/Personal/Projects/HermesPong/scripts/install-skills.sh",
            Bundle.main.bundlePath + "/../../../scripts/install-skills.sh",
            home + "/.pong/lib/../scripts/install-skills.sh",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c)
            || FileManager.default.fileExists(atPath: c) {
            _ = Pong.sh("bash \"\(c)\" all 2>&1 | tail -20")
            Pong.log("install-skills via \(c)")
            return
        }
        // Minimal inline copy into ~/.grok/skills and ~/.hermes
        let shareRoots = [
            home + "/Personal/Projects/HermesPong/share",
            Bundle.main.resourcePath.map { $0 + "/share" } ?? "",
            Bundle.main.bundlePath + "/../../../share",
        ]
        for share in shareRoots where FileManager.default.fileExists(atPath: share + "/pong-bridge") {
            let grok = home + "/.grok/skills"
            try? FileManager.default.createDirectory(atPath: grok, withIntermediateDirectories: true)
            for skill in ["pong-bridge", "grok-pong-bridge"] {
                let src = share + "/" + skill
                let dst = grok + "/" + skill
                if FileManager.default.fileExists(atPath: src) {
                    try? FileManager.default.removeItem(atPath: dst)
                    try? FileManager.default.copyItem(atPath: src, toPath: dst)
                }
            }
            Pong.log("install-skills copied from \(share)")
            return
        }
        Pong.log("install-skills: no share tree found")
    }
}

// MARK: - Multi-step install wizard (optional)

/// Guided setup after types are chosen: names, roles, policy, scaffold files.
final class TeamInstallWizard: NSObject, NSWindowDelegate {
    static let shared = TeamInstallWizard()

    private var window: NSWindow?
    private var content: NSView!
    private var step = 0
    private let steps = ["Welcome", "Mission", "Names", "Architecture", "Roles", "Policy", "Review"]

    private var plan: TeamWizardPlan!
    private var onFinish: ((TeamWizardPlan) -> Void)?
    private var onCancel: (() -> Void)?

    // Controls retained for save
    private var teamNameField: NSTextField!
    private var projectField: NSTextField!
    private var briefView: NSTextView!
    private var condNameField: NSTextField!
    private var workerNameFields: [NSTextField] = []
    private var rolePopups: [NSPopUpButton] = []
    private var policyPreset: NSPopUpButton!
    private var writeScaffoldCheck: NSButton!
    private var installSkillsCheck: NSButton!
    private var statusLabel: NSTextField!
    private var archCanvas: TeamArchCanvas?
    private var missionGoalField: NSTextField!
    private var decisionPop: NSPopUpButton!
    private var pingOnDoneCheck: NSButton!
    private var orchGoalOnlyCheck: NSButton!

    private let W: CGFloat = 640
    private let H: CGFloat = 580

    /// Present wizard. Call after conductor + worker types are known.
    func run(conductor: ConductorType, workers: [WorkerType],
             onFinish: @escaping (TeamWizardPlan) -> Void,
             onCancel: (() -> Void)? = nil) {
        self.onFinish = onFinish
        self.onCancel = onCancel
        var wlist = workers
        if wlist.isEmpty { wlist = [WorkerType.resolved("claude")] }
        plan = TeamWizardPlan(
            teamName: "",
            projectRoot: "",
            teamBrief: "",
            conductor: conductor,
            conductorLabel: conductor.label.replacingOccurrences(of: " (recommended)", with: ""),
            workers: wlist.enumerated().map { i, t in
                TeamWizardPlan.WizardWorker(
                    type: t,
                    label: t.label,
                    role: MissionRole.defaultForWorker(index: i)
                )
            },
            permissions: PairState.defaultPermissions(),
            writeScaffold: true,
            installGlobalSkills: true
        )
        step = 0
        buildWindow()
        showStep()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        if window != nil { return }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: W, height: H),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        win.title = "Team setup wizard"
        win.isReleasedWhenClosed = false
        win.backgroundColor = PongTheme.bg
        win.delegate = self
        win.center()

        content = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        content.wantsLayer = true
        content.layer?.backgroundColor = PongTheme.bg.cgColor
        win.contentView = content
        window = win
    }

    func windowWillClose(_ notification: Notification) {
        if step < steps.count { onCancel?() }
    }

    private func clearBody() {
        content.subviews.forEach { $0.removeFromSuperview() }
    }

    private func showStep() {
        clearBody()
        // Header
        let title = NSTextField(labelWithString: steps[step])
        title.font = PongTheme.font(20, weight: .semibold)
        title.textColor = PongTheme.textPrimary
        title.frame = NSRect(x: 28, y: H - 56, width: 300, height: 28)
        content.addSubview(title)

        let prog = NSTextField(labelWithString: "Step \(step + 1) of \(steps.count)  ·  optional guided setup")
        prog.font = PongTheme.labelFont(11)
        prog.textColor = PongTheme.textTertiary
        prog.frame = NSRect(x: 28, y: H - 76, width: 400, height: 16)
        content.addSubview(prog)

        let rule = NSView(frame: NSRect(x: 28, y: H - 90, width: W - 56, height: 1))
        rule.wantsLayer = true
        rule.layer?.backgroundColor = PongTheme.lineSoft.cgColor
        content.addSubview(rule)

        switch step {
        case 0: pageWelcome()
        case 1: pageMission()
        case 2: pageNames()
        case 3: pageArchitecture()
        case 4: pageRoles()
        case 5: pagePolicy()
        default: pageReview()
        }

        // Nav buttons
        let back = pill("Back", #selector(backPressed))
        back.frame = NSRect(x: 28, y: 20, width: 80, height: 30)
        back.isEnabled = step > 0
        content.addSubview(back)

        let skip = pill("Skip wizard", #selector(skipPressed))
        skip.frame = NSRect(x: 120, y: 20, width: 110, height: 30)
        content.addSubview(skip)

        let nextTitle = step == steps.count - 1 ? "Create team" : "Continue"
        let next = accent(nextTitle, #selector(nextPressed))
        next.frame = NSRect(x: W - 148, y: 20, width: 120, height: 30)
        content.addSubview(next)
    }

    // MARK: Pages

    private func pageWelcome() {
        let body = wrap(
            "Build a team in a few taps — we write the SOUL/SKILL files for you.\n\n" +
            "You’ll set:\n" +
            "• The mission goal (what the orchestrator owns)\n" +
            "• Who decides / when to ping you\n" +
            "• Architecture (drag seats · pick models · SUB plane)\n" +
            "• Roles & session policy\n\n" +
            "Skip anytime for a plain launch with defaults.",
            frame: NSRect(x: 28, y: 80, width: W - 56, height: 300)
        )
        content.addSubview(body)

        let note = NSTextField(labelWithString: "Conductor: \(plan.conductor.label)  ·  \(plan.workers.count) worker seat(s)")
        note.font = PongTheme.labelFont(12)
        note.textColor = PongTheme.blue
        note.frame = NSRect(x: 28, y: 70, width: W - 56, height: 18)
        content.addSubview(note)
    }

    /// Mission / decision prefs — mostly choices, minimal free text.
    private func pageMission() {
        var y = H - 120
        content.addSubview(label("What is this team’s job?", x: 28, y: y))
        y -= 6
        let hint = wrap(
            "One line the orchestrator optimizes for. Leave blank to use a solid default.",
            frame: NSRect(x: 28, y: y - 28, width: W - 56, height: 28)
        )
        content.addSubview(hint)
        y -= 36
        missionGoalField = field(
            placeholder: "e.g. Ship the auth refactor with tests green",
            value: plan.missionGoal
        )
        missionGoalField.frame = NSRect(x: 28, y: y - 28, width: W - 56, height: 26)
        content.addSubview(missionGoalField)
        y -= 56

        content.addSubview(label("Who makes the final decision?", x: 28, y: y))
        y -= 8
        decisionPop = NSPopUpButton(frame: NSRect(x: 28, y: y - 28, width: 360, height: 28), pullsDown: false)
        decisionPop.addItem(withTitle: "Orchestrator decides (default)")
        decisionPop.lastItem?.representedObject = "orch"
        decisionPop.addItem(withTitle: "Always ask me (human)")
        decisionPop.lastItem?.representedObject = "human"
        decisionPop.addItem(withTitle: "Shared — orch proposes, I confirm risky steps")
        decisionPop.lastItem?.representedObject = "shared"
        switch plan.decisionMode {
        case "human": decisionPop.selectItem(at: 1)
        case "shared": decisionPop.selectItem(at: 2)
        default: decisionPop.selectItem(at: 0)
        }
        content.addSubview(decisionPop)
        y -= 56

        orchGoalOnlyCheck = NSButton(
            checkboxWithTitle: "Orchestrator focuses on goal & routing only (doesn’t implement product code)",
            target: nil, action: nil)
        orchGoalOnlyCheck.state = plan.orchGoalOnly ? .on : .off
        orchGoalOnlyCheck.frame = NSRect(x: 28, y: y, width: W - 56, height: 22)
        content.addSubview(orchGoalOnlyCheck)
        y -= 32

        pingOnDoneCheck = NSButton(
            checkboxWithTitle: "Ping me when agent tasks finish or need human input",
            target: nil, action: nil)
        pingOnDoneCheck.state = plan.pingOnDone ? .on : .off
        pingOnDoneCheck.frame = NSRect(x: 28, y: y, width: W - 56, height: 22)
        content.addSubview(pingOnDoneCheck)
        y -= 40

        let tip = wrap(
            "These choices are written into TEAM.md / SOUL files automatically — you don’t type policy prose.",
            frame: NSRect(x: 28, y: y - 40, width: W - 56, height: 40)
        )
        tip.textColor = PongTheme.textTertiary
        content.addSubview(tip)
    }

    private func pageNames() {
        var y = H - 120
        content.addSubview(label("Team display name", x: 28, y: y))
        teamNameField = field(placeholder: "e.g. Auth stack", value: plan.teamName)
        teamNameField.frame = NSRect(x: 28, y: y - 28, width: W - 56, height: 26)
        content.addSubview(teamNameField)
        y -= 70

        content.addSubview(label("Project root (optional)", x: 28, y: y))
        projectField = field(placeholder: "~/src/my-app", value: plan.projectRoot)
        projectField.frame = NSRect(x: 28, y: y - 28, width: W - 140, height: 26)
        content.addSubview(projectField)
        let browse = pill("Browse", #selector(browseRoot))
        browse.frame = NSRect(x: W - 100, y: y - 30, width: 72, height: 28)
        content.addSubview(browse)
        y -= 70

        content.addSubview(label("Orchestrator name", x: 28, y: y))
        condNameField = field(placeholder: "e.g. Grok Build", value: plan.conductorLabel)
        condNameField.frame = NSRect(x: 28, y: y - 28, width: W - 56, height: 26)
        content.addSubview(condNameField)
        y -= 60

        content.addSubview(label("Agent names", x: 28, y: y))
        y -= 8
        workerNameFields = []
        for (i, w) in plan.workers.enumerated() {
            y -= 30
            let tag = NSTextField(labelWithString: "w\(i + 1)")
            tag.font = PongTheme.mono(11, weight: .medium)
            tag.textColor = PongTheme.magenta
            tag.frame = NSRect(x: 28, y: y, width: 36, height: 22)
            content.addSubview(tag)
            let f = field(placeholder: w.type.label, value: w.label)
            f.frame = NSRect(x: 70, y: y, width: W - 100, height: 24)
            content.addSubview(f)
            workerNameFields.append(f)
        }
    }

    private func pageArchitecture() {
        let intro = wrap(
            "Drag seats · + / Link: source then destination (existing) · drag dotted ends to rewire · × or Delete removes agents · mid-arrow sets kind · drag into SUB to nest.",
            frame: NSRect(x: 28, y: H - 118, width: W - 200, height: 36)
        )
        content.addSubview(intro)

        let linkBtn = pill("Link seats…", #selector(toggleArchLinkMode))
        linkBtn.frame = NSRect(x: W - 150, y: H - 112, width: 120, height: 28)
        linkBtn.toolTip = "Click source, then destination seat — does not create a new agent"
        content.addSubview(linkBtn)

        let canvas = TeamArchCanvas(frame: NSRect(x: 28, y: 70, width: W - 56, height: H - 200))
        canvas.defaultModelId = plan.workers.first?.type.id ?? "claude"
        canvas.load(plan: plan)
        canvas.onChanged = { [weak self] in
            guard let self else { return }
            self.syncPlanFromCanvas(canvas)
        }
        content.addSubview(canvas)
        archCanvas = canvas
        plan.flowEdges = canvas.exportEdges()
    }

    @objc private func toggleArchLinkMode() {
        guard let canvas = archCanvas else { return }
        canvas.setLinkMode(!canvas.isLinkMode)
        window?.makeFirstResponder(canvas)
    }

    private func syncPlanFromCanvas(_ canvas: TeamArchCanvas) {
        plan.flowEdges = canvas.exportEdges()
        let exported = canvas.exportWorkers()
        plan.workers = exported.map { w in
            TeamWizardPlan.WizardWorker(
                type: WorkerType.resolved(w.modelId),
                label: w.title,
                role: MissionRole.parse(w.mission) ?? .coder,
                parentId: w.parentId
            )
        }
        if let c = canvas.nodes.first(where: { $0.id == "c1" }) {
            plan.conductorLabel = c.title
        }
    }

    private func pageRoles() {
        var y = H - 120
        let intro = wrap(
            "Who does what? Orchestrator plans and verifies. Pick Coder, Reviewer, Operator, Researcher, or Task runner (cron / one-shot jobs).",
            frame: NSRect(x: 28, y: y - 40, width: W - 56, height: 40)
        )
        content.addSubview(intro)
        y -= 60

        let orch = NSTextField(labelWithString: "c1  \(plan.conductorLabel)  →  Orchestrator (fixed)")
        orch.font = PongTheme.font(12, weight: .medium)
        orch.textColor = PongTheme.blue
        orch.frame = NSRect(x: 28, y: y, width: W - 56, height: 20)
        content.addSubview(orch)
        y -= 36

        rolePopups = []
        for (i, w) in plan.workers.enumerated() {
            let row = NSTextField(labelWithString: "w\(i + 1)  \(w.label)")
            row.font = PongTheme.font(12)
            row.textColor = PongTheme.textPrimary
            row.frame = NSRect(x: 28, y: y, width: 200, height: 22)
            content.addSubview(row)

            let pop = NSPopUpButton(frame: NSRect(x: 240, y: y - 2, width: 200, height: 26), pullsDown: false)
            for r in MissionRole.allCases where r != .orchestrator {
                pop.addItem(withTitle: r.title)
                pop.lastItem?.representedObject = r.rawValue
            }
            if let idx = MissionRole.allCases.filter({ $0 != .orchestrator }).firstIndex(of: w.role) {
                pop.selectItem(at: idx)
            }
            content.addSubview(pop)
            rolePopups.append(pop)

            let blurb = NSTextField(labelWithString: w.role.blurb)
            blurb.font = PongTheme.font(10)
            blurb.textColor = PongTheme.textTertiary
            blurb.frame = NSRect(x: 28, y: y - 18, width: W - 56, height: 14)
            content.addSubview(blurb)
            y -= 52
        }
    }

    private func pagePolicy() {
        var y = H - 120
        content.addSubview(label("Session access policy (live layer)", x: 28, y: y))
        y -= 8
        let info = wrap(
            "Bounds what seats may do this session — not standing OAuth grants. " +
            "You can refine later with Policy on each agent card.",
            frame: NSRect(x: 28, y: y - 48, width: W - 56, height: 48)
        )
        content.addSubview(info)
        y -= 70

        policyPreset = NSPopUpButton(frame: NSRect(x: 28, y: y, width: 280, height: 28), pullsDown: false)
        policyPreset.addItem(withTitle: "Full access")
        policyPreset.lastItem?.representedObject = "full"
        policyPreset.addItem(withTitle: "Ask each elevated action")
        policyPreset.lastItem?.representedObject = "ask"
        policyPreset.addItem(withTitle: "Repo-only + no network")
        policyPreset.lastItem?.representedObject = "tight"
        content.addSubview(policyPreset)
        y -= 50

        let bullets = wrap(
            "Full — no ban flags\n" +
            "Ask each — worker must ask before elevated tools / network / system paths\n" +
            "Tight — repo_only + ban_network (good default for untrusted scope)",
            frame: NSRect(x: 28, y: y - 90, width: W - 56, height: 90)
        )
        content.addSubview(bullets)
    }

    private func pageReview() {
        harvest()
        // Auto-compose brief from mission choices — user rarely needs free-form prose
        if plan.teamBrief.isEmpty {
            plan.teamBrief = composedBrief()
        }
        var y = H - 120
        content.addSubview(label("Ready to create", x: 28, y: y))
        y -= 8

        writeScaffoldCheck = NSButton(
            checkboxWithTitle: "Write SOUL / SKILL / TEAM.md (recommended)",
            target: self, action: nil)
        writeScaffoldCheck.state = plan.writeScaffold ? .on : .off
        writeScaffoldCheck.frame = NSRect(x: 28, y: y - 24, width: W - 56, height: 22)
        content.addSubview(writeScaffoldCheck)
        y -= 32

        installSkillsCheck = NSButton(
            checkboxWithTitle: "Install global conductor bridge skills",
            target: self, action: nil)
        installSkillsCheck.state = plan.installGlobalSkills ? .on : .off
        installSkillsCheck.frame = NSRect(x: 28, y: y - 24, width: W - 56, height: 22)
        content.addSubview(installSkillsCheck)
        y -= 40

        let lines = [
            "Team: \(plan.teamName.isEmpty ? "(unnamed)" : plan.teamName)",
            "Mission: \(plan.missionGoal.isEmpty ? "(default)" : plan.missionGoal)",
            "Decisions: \(plan.decisionMode) · ping-on-done: \(plan.pingOnDone ? "yes" : "no") · orch-goal-only: \(plan.orchGoalOnly ? "yes" : "no")",
            "Project: \(plan.projectRoot.isEmpty ? "(none)" : plan.projectRoot)",
            "Orchestrator: \(plan.conductorLabel) [\(plan.conductor.id)]",
        ] + plan.workers.enumerated().map { i, w in
            let sub = w.parentId.map { " under \($0)" } ?? ""
            return "w\(i + 1): \(w.label) · \(w.type.id) · \(w.role.title)\(sub)"
        } + [
            "",
            "Brief (auto):",
            plan.teamBrief,
        ]
        let body = wrap(lines.joined(separator: "\n"), frame: NSRect(x: 28, y: 58, width: W - 56, height: max(120, y - 70)))
        body.font = PongTheme.mono(11)
        content.addSubview(body)
    }

    private func composedBrief() -> String {
        let goal = plan.missionGoal.isEmpty
            ? "Ship reliable software with clear jobs, claims, and human override."
            : plan.missionGoal
        let decide: String = {
            switch plan.decisionMode {
            case "human": return "Human makes final decisions; orchestrator proposes."
            case "shared": return "Orchestrator proposes; human confirms risky or irreversible steps."
            default: return "Orchestrator decides day-to-day; escalate only on policy bans or reject streaks."
            }
        }()
        let focus = plan.orchGoalOnly
            ? "Orchestrator routes and verifies — does not implement product code while BRIDGE_ON."
            : "Orchestrator may assist with implementation when needed."
        let ping = plan.pingOnDone
            ? "Ping the human when tasks complete, fail, or need takeover."
            : "Do not ping on routine completions."
        return "\(goal)\n\(decide)\n\(focus)\n\(ping)"
    }

    // MARK: Nav

    @objc private func backPressed() {
        harvest()
        step = max(0, step - 1)
        showStep()
    }

    @objc private func skipPressed() {
        // Minimal plan — types only, no scaffold
        plan.writeScaffold = false
        plan.installGlobalSkills = false
        finish()
    }

    @objc private func nextPressed() {
        harvest()
        if step >= steps.count - 1 {
            finish()
            return
        }
        step += 1
        showStep()
    }

    private func harvest() {
        if teamNameField != nil { plan.teamName = teamNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        if projectField != nil { plan.projectRoot = projectField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        if condNameField != nil {
            let t = condNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { plan.conductorLabel = t }
        }
        if missionGoalField != nil {
            plan.missionGoal = missionGoalField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if decisionPop != nil {
            plan.decisionMode = (decisionPop.selectedItem?.representedObject as? String) ?? "orch"
        }
        if pingOnDoneCheck != nil { plan.pingOnDone = pingOnDoneCheck.state == .on }
        if orchGoalOnlyCheck != nil { plan.orchGoalOnly = orchGoalOnlyCheck.state == .on }
        if let canvas = archCanvas {
            syncPlanFromCanvas(canvas)
        }
        if !workerNameFields.isEmpty {
            for (i, f) in workerNameFields.enumerated() where i < plan.workers.count {
                let t = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { plan.workers[i].label = t }
            }
        }
        if !rolePopups.isEmpty {
            for (i, pop) in rolePopups.enumerated() where i < plan.workers.count {
                if let raw = pop.selectedItem?.representedObject as? String,
                   let r = MissionRole.parse(raw) {
                    plan.workers[i].role = r
                }
            }
        }
        // Always recompose brief from mission prefs (skip free-text burden)
        plan.teamBrief = composedBrief()
        if policyPreset != nil {
            let id = policyPreset.selectedItem?.representedObject as? String ?? "full"
            switch id {
            case "ask":
                plan.permissions = PairState.askEachPermissions()
            case "tight":
                var p = PairState.defaultPermissions()
                p["repo_only"] = true
                p["ban_network"] = true
                plan.permissions = p
            default:
                plan.permissions = PairState.fullAccessPermissions()
            }
        }
        if writeScaffoldCheck != nil { plan.writeScaffold = writeScaffoldCheck.state == .on }
        if installSkillsCheck != nil { plan.installGlobalSkills = installSkillsCheck.state == .on }
        // teamBrief always from composedBrief() above — no free-text override
    }

    private func finish() {
        harvest()
        let done = onFinish
        onFinish = nil
        onCancel = nil
        step = steps.count
        window?.orderOut(nil)
        done?(plan)
    }

    @objc private func browseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose project"
        if panel.runModal() == .OK, let url = panel.url {
            projectField?.stringValue = url.path
            plan.projectRoot = url.path
        }
    }

    // MARK: UI helpers

    private func label(_ t: String, x: CGFloat, y: CGFloat) -> NSTextField {
        let f = NSTextField(labelWithString: t)
        f.font = PongTheme.labelFont(11)
        f.textColor = PongTheme.textSecondary
        f.frame = NSRect(x: x, y: y, width: W - 56, height: 16)
        return f
    }

    private func field(placeholder: String, value: String) -> NSTextField {
        let f = NSTextField(frame: .zero)
        f.placeholderString = placeholder
        f.stringValue = value
        f.font = PongTheme.font(12)
        f.isBordered = true
        f.isBezeled = true
        f.bezelStyle = .roundedBezel
        f.backgroundColor = PongTheme.bgInput
        f.textColor = PongTheme.textPrimary
        return f
    }

    private func wrap(_ t: String, frame: NSRect) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: t)
        f.font = PongTheme.font(12)
        f.textColor = PongTheme.textSecondary
        f.frame = frame
        f.maximumNumberOfLines = 20
        return f
    }

    private func pill(_ title: String, _ sel: Selector) -> NSButton {
        let b = NSButton(frame: .zero)
        b.bezelStyle = .inline
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 4
        b.layer?.borderWidth = 1
        b.layer?.borderColor = PongTheme.line.cgColor
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: PongTheme.textPrimary,
            .font: PongTheme.labelFont(11),
        ])
        b.target = self
        b.action = sel
        return b
    }

    private func accent(_ title: String, _ sel: Selector) -> NSButton {
        let b = NSButton(frame: .zero)
        b.bezelStyle = .inline
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 4
        b.layer?.backgroundColor = PongTheme.ink.cgColor
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: PongTheme.bg,
            .font: PongTheme.labelFont(11),
        ])
        b.target = self
        b.action = sel
        return b
    }
}

// MARK: - Apply plan after Pairing.startFresh

enum TeamWizardApply {
    static func apply(_ plan: TeamWizardPlan, session: String) {
        if !plan.teamName.isEmpty || !plan.projectRoot.isEmpty || !plan.teamBrief.isEmpty {
            Workers.setTeamOptions(
                session,
                displayName: plan.teamName.isEmpty ? session : plan.teamName,
                projectRoot: plan.projectRoot,
                teamBrief: plan.teamBrief
            )
        }
        Workers.setConductorLabel(pair: session, label: plan.conductorLabel)
        for (i, w) in plan.workers.enumerated() {
            let id = "w\(i + 1)"
            Workers.setWorkerLabel(pair: session, workerId: id, label: w.label)
            // mission role + permissions on worker
            var db = PairState.loadPairsDb()
            var entry = db[session] as? [String: Any] ?? [:]
            var ws = Workers.list(from: entry)
            if let idx = ws.firstIndex(where: { ($0["id"] as? String) == id }) {
                ws[idx]["mission_role"] = w.role.rawValue
                ws[idx]["permissions"] = plan.permissions
                entry["workers"] = ws
                entry["permissions"] = plan.permissions
                entry["updated"] = Date().timeIntervalSince1970
                db[session] = entry
                Pong.writeJSON(PairState.pairsPath, db)
            }
        }
        // team-level permissions
        var db = PairState.loadPairsDb()
        if var entry = db[session] as? [String: Any] {
            entry["permissions"] = plan.permissions
            entry["wizard_completed"] = true
            db[session] = entry
            Pong.writeJSON(PairState.pairsPath, db)
        }
        if !plan.flowEdges.isEmpty {
            FlowGraph.save(pair: session, edges: plan.flowEdges)
        } else {
            // Ensure defaults written so 3D has graph
            let entry = PairState.loadPairsDb()[session] as? [String: Any] ?? [:]
            FlowGraph.save(pair: session, edges: FlowGraph.defaultEdges(entry: entry))
        }
        // parent_id from architecture canvas AND from sub edges (so SUB plane is correct)
        do {
            var db = PairState.loadPairsDb()
            var entry = db[session] as? [String: Any] ?? [:]
            var ws = Workers.list(from: entry)
            var dirty = false
            for (i, w) in plan.workers.enumerated() {
                let id = "w\(i + 1)"
                guard let idx = ws.firstIndex(where: { ($0["id"] as? String) == id }) else { continue }
                if let pid = w.parentId, !pid.isEmpty {
                    ws[idx]["parent_id"] = pid
                    dirty = true
                }
            }
            // Also honor sub edges: to-seat becomes sub under from-seat
            for e in plan.flowEdges where e.kind == "sub" {
                if let idx = ws.firstIndex(where: { ($0["id"] as? String) == e.to }) {
                    ws[idx]["parent_id"] = e.from
                    dirty = true
                }
            }
            if dirty {
                entry["workers"] = ws
                entry["updated"] = Date().timeIntervalSince1970
                db[session] = entry
                Pong.writeJSON(PairState.pairsPath, db)
                Pong.log("wizard parent_id applied session=\(session) workers=\(ws.map { "\($0["id"] ?? "?")->\($0["parent_id"] ?? "-")" })")
            }
        }
        if plan.installGlobalSkills {
            TeamScaffold.installGlobalSkills()
        }
        if plan.writeScaffold {
            TeamScaffold.write(plan: plan, session: session)
        }
        // Names land after Terminals open — repaint titles to Team · Agent (not pong-team · Grok Build)
        usleep(200_000)
        TerminalTheme.applyPair(session)
        Pong.log("wizard applied session=\(session) scaffold=\(plan.writeScaffold) edges=\(plan.flowEdges.count)")
    }
}
