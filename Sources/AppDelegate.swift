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
        if ProcessInfo.processInfo.environment["CHIPBURNER_SMOKETEST"] != nil {
            let shot = ProcessInfo.processInfo.environment["CHIPBURNER_SCREENSHOT"]
            if shot != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { controller.prepareScreenshot() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if let path = shot { controller.saveScreenshot(to: path) }
                let ok = controller.smokeReport()
                fflush(stdout)
                exit(ok ? 0 : 1)
            }
            return
        }
        controller.checkProgrammer(nil)
        let mp = Minipro.shared
        DispatchQueue.global(qos: .utility).async {
            ChipDatabase.shared.load(infoic: mp.infoic, logicic: mp.logicic)
            DispatchQueue.main.async { controller.updateChipInfo() }
        }
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

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        let name = ProcessInfo.processInfo.processName

        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Load…", action: #selector(MainWindowController.openFile(_:)), keyEquivalent: "o")
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
        chipMenu.addItem(withTitle: "Check Programmer", action: #selector(MainWindowController.checkProgrammer(_:)), keyEquivalent: "k")
        chipMenu.addItem(withTitle: "Test Programmer (Self-Test)…", action: #selector(MainWindowController.testProgrammer(_:)), keyEquivalent: "")
        chipMenu.addItem(withTitle: "Search Chips…", action: #selector(MainWindowController.searchChips(_:)), keyEquivalent: "f")
        chipMenu.addItem(withTitle: "Ident EPROM…", action: #selector(MainWindowController.identifyChip(_:)), keyEquivalent: "i")
        chipMenu.addItem(withTitle: "Fuses, User ID & Lock Bits…", action: #selector(MainWindowController.openConfigWindow(_:)), keyEquivalent: "u")
        chipMenu.addItem(withTitle: "Chip Test (SRAM / EPROM health)…", action: #selector(MainWindowController.openChipTest(_:)), keyEquivalent: "")
        chipMenu.addItem(.separator())
        chipMenu.addItem(withTitle: "Read", action: #selector(MainWindowController.readChip(_:)), keyEquivalent: "r")
        chipMenu.addItem(withTitle: "Blank Check", action: #selector(MainWindowController.blankCheck(_:)), keyEquivalent: "b")
        chipMenu.addItem(withTitle: "Verify", action: #selector(MainWindowController.verifyChip(_:)), keyEquivalent: "")
        chipMenu.addItem(withTitle: "Program…", action: #selector(MainWindowController.programChip(_:)), keyEquivalent: "")
        chipMenu.addItem(withTitle: "Erase…", action: #selector(MainWindowController.eraseChip(_:)), keyEquivalent: "")
        chipMenu.addItem(withTitle: "Auto…", action: #selector(MainWindowController.autoBurn(_:)), keyEquivalent: "B")
        chipMenu.addItem(withTitle: "Logic Test", action: #selector(MainWindowController.logicTest(_:)), keyEquivalent: "t")
        chipMenu.addItem(withTitle: "Ident Logic…", action: #selector(MainWindowController.identifyLogic(_:)), keyEquivalent: "")
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
