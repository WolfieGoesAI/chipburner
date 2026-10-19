import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
        let controller = MainWindowController()
        mainController = controller
        controller.showWindow(nil)
        controller.window?.center()
        NSApp.activate(ignoringOtherApps: true)
        let mp = Minipro.shared
        DispatchQueue.global(qos: .utility).async {
            ChipDatabase.shared.load(infoic: mp.infoic, logicic: mp.logicic)
            DispatchQueue.main.async { controller.updateChipInfo() }
        }
        if ProcessInfo.processInfo.environment["CHIPBURNER_SMOKETEST"] != nil {
            let shot = ProcessInfo.processInfo.environment["CHIPBURNER_SCREENSHOT"]
            if shot != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { controller.prepareScreenshot() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                if let path = shot {
                    controller.saveScreenshot(to: path)
                    controller.saveFuseScreenshot(to: (path as NSString).deletingPathExtension + "-fuses.png")
                    controller.saveToolScreenshots(base: (path as NSString).deletingPathExtension)
                }
                let ok = controller.smokeReport()
                fflush(stdout)
                exit(ok ? 0 : 1)
            }
            return
        }
        controller.checkProgrammer(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Lets Window ▸ Log work while the log window itself is in front.
    @objc func toggleLog(_ sender: Any?) { mainController?.toggleLog(sender) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let c = mainController, c.isBusy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A chip operation is still running."
        alert.informativeText = "Quitting now stops it, which can leave a chip partly programmed."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    /// About box: version and build number (the GitHub build), commit, build date, the bundled
    /// minipro and chip database, and credits.
    @objc func showAbout(_ sender: Any?) {
        let info = Bundle.main.infoDictionary ?? [:]
        func v(_ k: String) -> String { (info[k] as? String).flatMap { $0.hasPrefix("__") ? nil : $0 } ?? "unknown" }
        let version = v("CFBundleShortVersionString"), build = v("CFBundleVersion")
        var dbLine = ""
        if let url = Minipro.shared.infoic,
           let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber {
            dbLine = "Chip database: infoic.xml from minipro (\(size.intValue / 1_048_576) MB)\n"
        }
        let text = """
            Made by WolfieGoesAI
            Build \(build) · commit \(v("ChipBurnerCommit")) · built \(v("ChipBurnerBuildDate"))
            For the TL866A/CS, TL866II+, T48 and T56 programmers · macOS 10.14 and later

            minipro \(v("ChipBurnerMinipro")) – GNU GPL v3
            gitlab.com/DavidGriffith/minipro
            \(dbLine)libusb \(v("ChipBurnerLibusb")) – GNU LGPL 2.1
            GAL assembler based on Galette by Simon Frankau – MIT licence

            Source code: github.com/WolfieGoesAI/chipburner
            """
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let credits = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para,
        ])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: "\(version) (build \(build))",
            .credits: credits,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        let name = ProcessInfo.processInfo.processName

        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(name)", action: #selector(showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(MainWindowController.openFile(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Save…", action: #selector(MainWindowController.saveFile(_:)), keyEquivalent: "s")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let pasteIns = editMenu.addItem(withTitle: "Paste Inserting", action: Selector(("pasteInserting:")), keyEquivalent: "v")
        pasteIns.keyEquivalentModifierMask = [.command, .option]
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let chipItem = NSMenuItem(); main.addItem(chipItem)
        let chipMenu = NSMenu(title: "Chip")
        chipMenu.addItem(withTitle: "H/W Test…", action: #selector(MainWindowController.hwTest(_:)), keyEquivalent: "k")
        chipMenu.addItem(withTitle: "Search Chips…", action: #selector(MainWindowController.searchChips(_:)), keyEquivalent: "f")
        chipMenu.addItem(withTitle: "Chip Ident…", action: #selector(MainWindowController.identifyChip(_:)), keyEquivalent: "i")
        chipMenu.addItem(withTitle: "Fuses, User ID & Lock Bits…", action: #selector(MainWindowController.openConfigWindow(_:)), keyEquivalent: "u")
        chipMenu.addItem(withTitle: "Chip Test (SRAM / EPROM health)…", action: #selector(MainWindowController.openChipTest(_:)), keyEquivalent: "")
        chipMenu.addItem(withTitle: "Pinout…", action: #selector(MainWindowController.showPinout(_:)), keyEquivalent: "")
        chipMenu.addItem(.separator())
        chipMenu.addItem(withTitle: "Read", action: #selector(MainWindowController.readChip(_:)), keyEquivalent: "r")
        chipMenu.addItem(withTitle: "Blank Check", action: #selector(MainWindowController.blankCheck(_:)), keyEquivalent: "b")
        chipMenu.addItem(withTitle: "Erase…", action: #selector(MainWindowController.eraseChip(_:)), keyEquivalent: "")
        chipMenu.addItem(withTitle: "Program…", action: #selector(MainWindowController.programChip(_:)), keyEquivalent: "")
        chipMenu.addItem(withTitle: "Verify", action: #selector(MainWindowController.verifyChip(_:)), keyEquivalent: "")
        chipMenu.addItem(withTitle: "Logic Test (Standard)", action: #selector(MainWindowController.logicTest(_:)), keyEquivalent: "t")
        chipMenu.addItem(withTitle: "Logic Test (Extended)…", action: #selector(MainWindowController.extendedLogicTest(_:)), keyEquivalent: "T")
        chipMenu.addItem(withTitle: "Logic Ident…", action: #selector(MainWindowController.identifyLogic(_:)), keyEquivalent: "")
        chipMenu.addItem(.separator())
        chipMenu.addItem(withTitle: "Stop", action: #selector(MainWindowController.stop(_:)), keyEquivalent: ".")
        chipItem.submenu = chipMenu

        let pldItem = NSMenuItem(); main.addItem(pldItem)
        pldItem.submenu = MainWindowController.makePLDMenu()

        let bufItem = NSMenuItem(); main.addItem(bufItem)
        let bufMenu = NSMenu(title: "Buffer")
        bufMenu.addItem(withTitle: "New Buffer…", action: #selector(MainWindowController.newBuffer(_:)), keyEquivalent: "n")
        bufMenu.addItem(.separator())
        bufMenu.addItem(withTitle: "Go to Address…", action: #selector(MainWindowController.goToAddress(_:)), keyEquivalent: "j")
        let find = bufMenu.addItem(withTitle: "Find in Buffer…", action: #selector(MainWindowController.findInBuffer(_:)), keyEquivalent: "f")
        find.keyEquivalentModifierMask = [.command, .option]
        bufMenu.addItem(withTitle: "Find Next", action: #selector(MainWindowController.findNextInBuffer(_:)), keyEquivalent: "g")
        bufMenu.addItem(.separator())
        bufMenu.addItem(withTitle: "Insert Bytes…", action: #selector(MainWindowController.insertBytes(_:)), keyEquivalent: "")
        bufMenu.addItem(withTitle: "Fill Range…", action: #selector(MainWindowController.fillBufferRange(_:)), keyEquivalent: "")
        bufMenu.addItem(withTitle: "Checksum of Range…", action: #selector(MainWindowController.checksumBufferRange(_:)), keyEquivalent: "")
        bufMenu.addItem(withTitle: "Resize Buffer…", action: #selector(MainWindowController.resizeBuffer(_:)), keyEquivalent: "")
        bufMenu.addItem(.separator())
        bufMenu.addItem(withTitle: "Compare with File…", action: #selector(MainWindowController.compareWithFile(_:)), keyEquivalent: "")
        bufMenu.addItem(withTitle: "Compare with Chip", action: #selector(MainWindowController.compareWithChip(_:)), keyEquivalent: "")
        bufItem.submenu = bufMenu

        let winItem = NSMenuItem(); main.addItem(winItem)
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "Log", action: #selector(MainWindowController.toggleLog(_:)), keyEquivalent: "l")
        winItem.submenu = winMenu
        NSApp.windowsMenu = winMenu
        return main
    }
}
