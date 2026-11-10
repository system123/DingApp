import AppKit
import IOKit.pwr_mgt
import Carbon.HIToolbox
import ServiceManagement

let overlaySeconds = 6.0 // default for how long the reminder stays on screen

// "11:44 booth" -> next 11:44, "25m", "1h30m tea", "90s", "10" (= minutes). Text after the first space is the label.
func parse(_ input: String, now: Date = Date(), cal: Calendar = .current) -> (Date, String)? {
    let parts = input.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
    guard let spec = parts.first?.lowercased() else { return nil }
    let label = parts.count > 1 ? parts[1] : ""
    if spec.contains(":") {
        let hm = spec.split(separator: ":").compactMap { Int($0) }
        guard hm.count == 2, (0..<24).contains(hm[0]), (0..<60).contains(hm[1]),
              let d = cal.nextDate(after: now, matching: DateComponents(hour: hm[0], minute: hm[1], second: 0),
                                   matchingPolicy: .nextTime) else { return nil }
        return (d, label)
    }
    if let m = Double(spec), m > 0 { return (now + m * 60, label) }
    let units: [Character: Double] = ["h": 3600, "m": 60, "s": 1]
    var total = 0.0, num = ""
    for c in spec {
        if c.isNumber || c == "." { num.append(c); continue }
        guard let n = Double(num), let u = units[c] else { return nil }
        total += n * u; num = ""
    }
    guard num.isEmpty, total > 0 else { return nil }
    return (now + total, label)
}

// Borderless windows can't take keyboard focus by default; the break screen needs it for Esc.
final class KeyWindow: NSWindow { override var canBecomeKey: Bool { true } }

// Duration only ("25m", "90s", "1h30m"), in seconds; clock times are rejected.
func duration(_ s: String) -> Double? {
    let now = Date()
    guard !s.contains(":"), let (end, _) = parse(s, now: now) else { return nil }
    return end.timeIntervalSince(now)
}

struct Alarm: Codable { let fire: Date; let label: String; let showFor: Double }

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    // Saved on every change so alarms survive quitting and restarts.
    var alarms: [Alarm] = [] { didSet { UserDefaults.standard.set(try? JSONEncoder().encode(alarms), forKey: "alarms") } }
    var prompting = false
    var hotKey: EventHotKeyRef?
    var overlay: NSPanel?
    var lastShowFor = UserDefaults.standard.string(forKey: "lastShowFor") ?? "\(Int(overlaySeconds))s" {
        didSet { UserDefaults.standard.set(lastShowFor, forKey: "lastShowFor") }
    }
    var awake: IOPMAssertionID = 0 // non-zero while keeping the Mac awake (Caffeine-style)
    var awakeUntil: Date?          // nil while awake = indefinitely
    var awakeItem: NSMenuItem?
    var pomo: (work: Double, rest: Double)? // nil = pomodoro off
    var pomoEnd = Date()                     // end of the current focus or break phase
    var onBreak = false
    var pomoItem: NSMenuItem?
    var breakWindows: [NSWindow] = []
    var breakClocks: [NSTextField] = []
    var appBeforeBreak: NSRunningApplication?
    var lastPomo = (work: "25m", rest: "5m")
    let timeFmt: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; return f }()

    func applicationDidFinishLaunching(_ n: Notification) {
        let menu = NSMenu(); menu.delegate = self; item.menu = menu
        // Restore saved alarms; ones that went off while Ding wasn't running are dropped.
        if let data = UserDefaults.standard.data(forKey: "alarms"),
           let saved = try? JSONDecoder().decode([Alarm].self, from: data) {
            alarms = saved.filter { $0.fire > Date() }
        }
        registerHotKey()
        updateIcon()
        // Poll instead of one Timer per alarm: survives sleep/wake and clock changes.
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
    }

    // Alarm symbol, plus a coffee cup beside it while keep-awake is on.
    // Custom mark (icon.swift): solid while alarms are pending, with a mug while keep-awake is on.
    func updateIcon() {
        let img = dingMark(filled: !alarms.isEmpty, mug: awake != 0)
        img.isTemplate = true
        img.accessibilityDescription = awake != 0 ? "Ding, keeping awake" : "Ding"
        item.button?.image = img
        item.button?.imagePosition = .imageLeft
        updateTitle()
    }

    // Minutes left in the current pomodoro phase, next to the icon ("24m", "Break 4m").
    func updateTitle() {
        let t = pomo == nil ? "" : " " + (onBreak ? "Break " : "") + "\(max(1, Int(ceil(pomoEnd.timeIntervalSinceNow / 60))))m"
        guard item.button?.attributedTitle.string != t else { return }
        item.button?.attributedTitle = NSAttributedString(string: t, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .baselineOffset: 1])
    }

    // Prevents display (and so system) idle sleep, like Caffeine. nil seconds = indefinitely.
    func setAwake(_ on: Bool, for seconds: Double? = nil) {
        if awake != 0 { IOPMAssertionRelease(awake); awake = 0 }
        awakeUntil = nil
        if on, IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "Ding keep awake" as CFString, &awake) == kIOReturnSuccess {
            awakeUntil = seconds.map { Date() + $0 }
        }
        updateIcon()
        if let m = item.menu { menuNeedsUpdate(m) }
    }

    func awakeRight() -> String? {
        guard awake != 0 else { return nil }
        return awakeUntil.map { clock($0.timeIntervalSinceNow) + " left" } ?? "On"
    }

    @objc func toggleAwake() { setAwake(awake == 0) }
    @objc func awakeFor(_ sender: NSMenuItem) { setAwake(true, for: Double(sender.tag) * 60) }

    func tick() {
        let now = Date()
        let due = alarms.filter { $0.fire <= now }
        if !due.isEmpty {
            alarms.removeAll { $0.fire <= now }
            updateIcon()
            due.forEach { show($0.label.isEmpty ? "Ding!" : $0.label, timeFmt.string(from: $0.fire), for: $0.showFor) }
            if let m = item.menu { menuNeedsUpdate(m) }
        }
        if awake != 0, let u = awakeUntil, u <= now { setAwake(false) }
        awakeItem?.attributedTitle = row("Keep awake", awakeRight())
        if pomo != nil, pomoEnd <= now { onBreak ? skipBreak() : beginBreak() }
        let left = clock(pomoEnd.timeIntervalSinceNow)
        breakClocks.forEach { $0.stringValue = left }
        pomoItem?.attributedTitle = row(onBreak ? "On break" : "Focusing", left + " left")
        updateTitle()
        // Live countdown while the menu is open (timer runs in .common mode, so it ticks during menu tracking).
        for mi in item.menu?.items ?? [] where mi.action == #selector(cancel(_:)) && alarms.indices.contains(mi.tag) {
            mi.attributedTitle = row(alarms[mi.tag])
        }
    }

    func row(_ a: Alarm) -> NSAttributedString {
        let label = a.label.count > 26 ? a.label.prefix(25) + "…" : a.label
        return row([timeFmt.string(from: a.fire), label].filter { !$0.isEmpty }.joined(separator: "  "),
                   "in " + clock(a.fire.timeIntervalSinceNow))
    }

    // Menu row with an optional right-aligned, grey, fixed-width-digit detail (so countdowns don't jitter).
    func row(_ left: String, _ right: String?) -> NSAttributedString {
        let ps = NSMutableParagraphStyle()
        ps.tabStops = [NSTextTab(textAlignment: .right, location: 250)]
        let s = NSMutableAttributedString(string: left, attributes: [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: ps])
        if let right {
            s.append(NSAttributedString(string: "\t" + right, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: ps]))
        }
        return s
    }

    func clock(_ t: Double) -> String {
        let s = max(0, Int(ceil(t)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    func symbol(_ name: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: nil) }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        pomoItem = nil
        menu.addItem(.sectionHeader(title: "Alarms"))
        let add = menu.addItem(withTitle: "New alarm or timer…", action: #selector(promptAction), keyEquivalent: "d")
        add.keyEquivalentModifierMask = [.control, .option, .command] // shown for the global hotkey
        add.target = self; add.image = symbol("plus")
        let quick = NSMenu()
        for (name, mins) in [("5 minutes", 5), ("10 minutes", 10), ("15 minutes", 15), ("30 minutes", 30), ("1 hour", 60)] {
            let mi = quick.addItem(withTitle: name, action: #selector(remindIn(_:)), keyEquivalent: "")
            mi.target = self; mi.tag = mins
        }
        let quickItem = menu.addItem(withTitle: "Remind me in", action: nil, keyEquivalent: "")
        quickItem.submenu = quick; quickItem.image = symbol("clock.arrow.circlepath")
        for (i, a) in alarms.enumerated() {
            let mi = menu.addItem(withTitle: "", action: #selector(cancel(_:)), keyEquivalent: "")
            mi.attributedTitle = row(a); mi.image = symbol("bell")
            mi.target = self; mi.tag = i; mi.toolTip = "Click to cancel"
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Keep awake"))
        let ai = menu.addItem(withTitle: "", action: #selector(toggleAwake), keyEquivalent: "")
        ai.attributedTitle = row("Keep awake", awakeRight())
        ai.target = self; ai.image = symbol(awake != 0 ? "cup.and.saucer.fill" : "cup.and.saucer"); awakeItem = ai
        let sub = NSMenu()
        for (name, mins) in [("15 minutes", 15), ("30 minutes", 30), ("1 hour", 60), ("2 hours", 120), ("4 hours", 240), ("8 hours", 480)] {
            let mi = sub.addItem(withTitle: name, action: #selector(awakeFor(_:)), keyEquivalent: "")
            mi.target = self; mi.tag = mins
        }
        let forItem = menu.addItem(withTitle: "Keep awake for", action: nil, keyEquivalent: "")
        forItem.submenu = sub; forItem.image = symbol("timer")
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Pomodoro"))
        if pomo != nil {
            let pi = menu.addItem(withTitle: "", action: #selector(pomoNow), keyEquivalent: "")
            pi.attributedTitle = row(onBreak ? "On break" : "Focusing", clock(pomoEnd.timeIntervalSinceNow) + " left")
            pi.target = self; pi.image = symbol(onBreak ? "cup.and.saucer" : "brain.head.profile")
            pi.toolTip = onBreak ? "Click to skip the break" : "Click to take your break now"
            pomoItem = pi
            menu.addItem(withTitle: "Stop pomodoro", action: #selector(stopPomo), keyEquivalent: "").target = self
            menu.items.last?.image = symbol("stop.circle")
        } else {
            let sub = NSMenu()
            for (w, r) in [(25, 5), (50, 10), (90, 15)] {
                let mi = sub.addItem(withTitle: "\(w) min focus, \(r) min break", action: #selector(pomoPreset(_:)), keyEquivalent: "")
                mi.target = self; mi.representedObject = [Double(w * 60), Double(r * 60)]
            }
            sub.addItem(.separator())
            sub.addItem(withTitle: "Custom…", action: #selector(customPomoAction), keyEquivalent: "").target = self
            let si = menu.addItem(withTitle: "Start pomodoro", action: nil, keyEquivalent: "")
            si.submenu = sub; si.image = symbol("timer")
        }
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Open at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self; login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: "Quit Ding", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").image = symbol("power")
    }

    @objc func cancel(_ sender: NSMenuItem) {
        if alarms.indices.contains(sender.tag) { alarms.remove(at: sender.tag) }
        updateIcon()
    }

    // MARK: Pomodoro: focus for `work`, then a full-screen break screen for `rest`, repeat until stopped.

    func startPomo(_ work: Double, _ rest: Double) {
        hideBreak()
        pomo = (work, rest); onBreak = false; pomoEnd = Date() + work
        updateIcon()
        if let m = item.menu { menuNeedsUpdate(m) }
    }

    @objc func pomoPreset(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? [Double] else { return }
        startPomo(v[0], v[1])
    }

    @objc func stopPomo() {
        hideBreak()
        pomo = nil; onBreak = false
        updateIcon()
        if let m = item.menu { menuNeedsUpdate(m) }
    }

    // Clicking the countdown row: start the break now while focusing, or skip it while on break.
    @objc func pomoNow() { onBreak ? skipBreak() : (pomoEnd = Date()) }

    @objc func skipBreak() {
        guard let p = pomo else { return hideBreak() }
        hideBreak()
        onBreak = false; pomoEnd = Date() + p.work
        show("Back to focus", "Next break at " + timeFmt.string(from: pomoEnd), for: popupSeconds())
        if let m = item.menu { menuNeedsUpdate(m) }
    }

    func beginBreak() {
        guard let p = pomo else { return }
        onBreak = true; pomoEnd = Date() + p.rest
        showBreak()
        if let m = item.menu { menuNeedsUpdate(m) }
    }

    func showBreak() {
        appBeforeBreak = NSWorkspace.shared.frontmostApplication
        for screen in NSScreen.screens {
            let w = KeyWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.isOpaque = false; w.backgroundColor = .clear
            let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.frame.size))
            bg.material = .fullScreenUI; bg.state = .active; bg.blendingMode = .behindWindow
            bg.appearance = NSAppearance(named: .darkAqua)
            let icon = NSImageView(image: symbol("cup.and.saucer.fill")!.withSymbolConfiguration(.init(pointSize: 64, weight: .regular))!)
            icon.contentTintColor = .controlAccentColor
            let title = NSTextField(labelWithString: "Time for a break")
            title.font = .systemFont(ofSize: 44, weight: .bold)
            let clockL = NSTextField(labelWithString: clock(pomoEnd.timeIntervalSinceNow))
            clockL.font = .monospacedDigitSystemFont(ofSize: 80, weight: .light)
            let hint = NSTextField(labelWithString: "Stand up, stretch, look at something far away.")
            hint.font = .systemFont(ofSize: 17); hint.textColor = .secondaryLabelColor
            let skip = NSButton(title: "Skip break (esc)", target: self, action: #selector(skipBreak))
            skip.keyEquivalent = "\u{1b}"; skip.controlSize = .large
            let stack = NSStackView(views: [icon, title, clockL, hint, skip])
            stack.orientation = .vertical; stack.spacing = 16; stack.setCustomSpacing(40, after: hint)
            stack.translatesAutoresizingMaskIntoConstraints = false
            bg.addSubview(stack)
            NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
                                         stack.centerYAnchor.constraint(equalTo: bg.centerYAnchor)])
            w.contentView = bg
            w.alphaValue = 0
            w.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.6; w.animator().alphaValue = 1 }
            breakWindows.append(w); breakClocks.append(clockL)
        }
        NSApp.activate(ignoringOtherApps: true) // so Esc reaches the skip button
        breakWindows.first?.makeKey()
    }

    func hideBreak() {
        guard !breakWindows.isEmpty else { return }
        for w in breakWindows {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; w.animator().alphaValue = 0 }) { w.close() }
        }
        breakWindows = []; breakClocks = []
        appBeforeBreak?.activate(); appBeforeBreak = nil // hand focus back to what you were doing
    }

    @objc func customPomoAction() { customPomo(error: nil) }

    func customPomo(error: String?) {
        let a = NSAlert()
        a.messageText = "Custom pomodoro"
        a.informativeText = error ?? "How long to focus, and how long the break screen stays up."
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 58))
        func field(_ y: Double, _ caption: String, _ value: String) -> NSTextField {
            let c = NSTextField(labelWithString: caption)
            c.textColor = .secondaryLabelColor; c.frame = NSRect(x: 0, y: y + 3, width: 50, height: 18)
            let f = NSTextField(frame: NSRect(x: 54, y: y, width: 80, height: 24))
            f.stringValue = value
            box.addSubview(c); box.addSubview(f)
            return f
        }
        let w = field(34, "Focus", lastPomo.work), r = field(0, "Break", lastPomo.rest)
        w.nextKeyView = r; r.nextKeyView = w
        a.accessoryView = box
        a.addButton(withTitle: "Start"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = w
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        guard let ws = duration(w.stringValue), let rs = duration(r.stringValue) else {
            return customPomo(error: "Use durations like 25m, 5m or 1h30m.")
        }
        lastPomo = (w.stringValue, r.stringValue)
        startPomo(ws, rs)
    }

    func popupSeconds() -> Double { duration(lastShowFor) ?? overlaySeconds }

    // Quick timer with no label; popup length is whatever was last used in the dialog.
    @objc func remindIn(_ sender: NSMenuItem) {
        alarms.append(Alarm(fire: Date() + Double(sender.tag) * 60, label: "", showFor: popupSeconds()))
        alarms.sort { $0.fire < $1.fire }
        updateIcon()
    }

    @objc func toggleLogin() {
        let s = SMAppService.mainApp
        do { try s.status == .enabled ? s.unregister() : s.register() } catch { NSLog("Ding login item: \(error)") }
        if s.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    // ⌃⌥⌘D from any app opens the New alarm dialog. Carbon hotkeys need no Accessibility permission.
    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { (NSApp.delegate as? App)?.promptAction() }
            return noErr
        }, 1, &spec, nil, nil)
        RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(controlKey | optionKey | cmdKey),
                            EventHotKeyID(signature: OSType(0x44494E47), id: 1), GetApplicationEventTarget(), 0, &hotKey)
    }

    @objc func promptAction() {
        guard !prompting else { return NSApp.activate(ignoringOtherApps: true) } // already open: just bring it forward
        prompting = true; defer { prompting = false }
        prompt(error: nil)
    }

    func prompt(error: String?, text: String = "") {
        let a = NSAlert()
        a.messageText = "New alarm or timer"
        a.informativeText = error ?? "A time like 11:44, or a timer like 25m, 1h30m, 90s. Add a label after a space."
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 64))
        let f = NSTextField(frame: NSRect(x: 0, y: 34, width: 280, height: 28))
        f.font = .systemFont(ofSize: 15)
        f.placeholderString = "11:44 move to meeting booth"
        f.stringValue = text
        let caption = NSTextField(labelWithString: "Show popup for")
        caption.textColor = .secondaryLabelColor
        caption.frame = NSRect(x: 0, y: 4, width: 110, height: 18)
        let g = NSTextField(frame: NSRect(x: 112, y: 0, width: 64, height: 24))
        g.placeholderString = "10s"
        g.stringValue = lastShowFor
        f.nextKeyView = g; g.nextKeyView = f
        [f, caption, g].forEach(box.addSubview)
        a.accessoryView = box
        a.addButton(withTitle: "Set"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        guard let (d, l) = parse(f.stringValue) else {
            return prompt(error: "Couldn't read \"\(f.stringValue)\". Try 11:44, 25m, 1h30m or 90s.", text: f.stringValue)
        }
        let now = Date()
        guard !g.stringValue.contains(":"), let (end, _) = parse(g.stringValue, now: now) else {
            return prompt(error: "Couldn't read popup time \"\(g.stringValue)\". Try 5s, 10s or 1m.", text: f.stringValue)
        }
        lastShowFor = g.stringValue
        alarms.append(Alarm(fire: d, label: l, showFor: end.timeIntervalSince(now)))
        alarms.sort { $0.fire < $1.fire }
        updateIcon()
    }

    // Silent, click-through, non-activating banner at the top of the screen; a bar along the bottom
    // shrinks to show how long it will stay, then it fades out on its own.
    func show(_ title: String, _ subtitle: String, for seconds: Double) {
        overlay?.close()
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 20, weight: .semibold); t.lineBreakMode = .byTruncatingTail; t.sizeToFit()
        let s = NSTextField(labelWithString: subtitle)
        s.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium); s.textColor = .secondaryLabelColor; s.sizeToFit()
        let icon = NSImageView(image: symbol("bell.fill")!.withSymbolConfiguration(.init(pointSize: 26, weight: .semibold))!)
        icon.contentTintColor = .controlAccentColor

        let pad = 22.0, iconW = 34.0, gap = 14.0, h = 76.0
        let textW = min(520, max(t.frame.width, s.frame.width))
        let w = max(300, pad + iconW + gap + textW + pad)
        icon.frame = NSRect(x: pad, y: (h - iconW) / 2 + 1, width: iconW, height: iconW)
        t.frame = NSRect(x: pad + iconW + gap, y: h / 2 - 1, width: textW, height: t.frame.height)
        s.frame = NSRect(x: pad + iconW + gap, y: h / 2 - s.frame.height - 2, width: textW, height: s.frame.height)

        let vf = screen.visibleFrame
        let final = NSRect(x: vf.midX - w / 2, y: vf.maxY - h - 24, width: w, height: h)
        let p = NSPanel(contentRect: final.offsetBy(dx: 0, dy: 12), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false
        p.level = .screenSaver // above full-screen apps
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true; p.ignoresMouseEvents = true

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        bg.material = .popover; bg.state = .active // follows light/dark mode
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 20; bg.layer?.cornerCurve = .continuous; bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 0.5; bg.layer?.borderColor = NSColor.separatorColor.cgColor
        [icon, t, s].forEach(bg.addSubview)
        let bar = CALayer()
        bar.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        bar.anchorPoint = .zero
        bar.frame = CGRect(x: 0, y: 0, width: w, height: 3)
        bg.layer?.addSublayer(bar)
        p.contentView = bg

        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup {
            $0.duration = 0.35; $0.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
            p.animator().setFrame(final, display: true)
        }
        icon.addSymbolEffect(.bounce, options: .repeat(2))
        let shrink = CABasicAnimation(keyPath: "transform.scale.x")
        shrink.fromValue = 1; shrink.toValue = 0; shrink.duration = seconds
        shrink.fillMode = .forwards; shrink.isRemovedOnCompletion = false
        bar.add(shrink, forKey: nil)
        overlay = p
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.5; p.animator().alphaValue = 0 }) {
                p.close()
                if self?.overlay === p { self?.overlay = nil }
            }
        }
    }
}

func selftest() {
    func check(_ ok: Bool, _ msg: String) { if !ok { print("FAIL:", msg); exit(1) } }
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    let now = Date(timeIntervalSince1970: 11 * 3600) // 11:00 UTC
    check(parse("11:44 move to booth", now: now, cal: cal)! == (now + 44 * 60, "move to booth"), "clock today")
    check(parse("10:30", now: now, cal: cal)! == (now + 23.5 * 3600, ""), "clock rolls to tomorrow")
    check(parse("25m", now: now)! == (now + 1500, ""), "minutes")
    check(parse("1h30m tea", now: now)! == (now + 5400, "tea"), "h+m with label")
    check(parse("90s", now: now)!.0 == now + 90, "seconds")
    check(parse("10", now: now)!.0 == now + 600, "bare number = minutes")
    for bad in ["", "abc", "25x", "25:00", "1h30", "0", "11:60"] { check(parse(bad, now: now, cal: cal) == nil, "reject \(bad)") }
    print("ok")
}

if CommandLine.arguments.contains("--selftest") { selftest(); exit(0) }
if let i = CommandLine.arguments.firstIndex(of: "--write-iconset"), i + 1 < CommandLine.arguments.count {
    try! writeIconset(CommandLine.arguments[i + 1]); exit(0)
}
if CommandLine.arguments.contains("--preview-break") { // 5s focus then a 10s break screen
    DispatchQueue.main.async { delegate.startPomo(5, 10) }
}
if CommandLine.arguments.contains("--preview") { // show a sample popup: open Ding.app --args --preview
    DispatchQueue.main.async { delegate.show("Move to the meeting booth", "11:45", for: 10) }
}
let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
