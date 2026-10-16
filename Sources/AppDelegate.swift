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
        fileMenu.addItem(withTitle: "Open…", action: #selector(MainWindowController.openFile(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Save as Binary…", action: #selector(MainWindowController.saveBinary(_:)), keyEquivalent: "s")
        let hexItem = fileMenu.addItem(withTitle: "Save as Intel Hex…", action: #selector(MainWindowController.saveIntelHex(_:)), keyEquivalent: "s")
        hexItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Decode JED to Equations…", action: #selector(MainWindowController.decodeJED(_:)), keyEquivalent: "e")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let chipItem = NSMenuItem(); main.addItem(chipItem)
        let chipMenu = NSMenu(title: "Chip")
        chipMenu.addItem(withTitle: "Check Programmer", action: #selector(MainWindowController.checkProgrammer(_:)), keyEquivalent: "k")
        chipMenu.addItem(withTitle: "Search Chips…", action: #selector(MainWindowController.searchChips(_:)), keyEquivalent: "f")
        chipMenu.addItem(withTitle: "Identify Chip…", action: #selector(MainWindowController.identifyChip(_:)), keyEquivalent: "i")
        chipMenu.addItem(.separator())
        chipMenu.addItem(withTitle: "Read", action: #selector(MainWindowController.readChip(_:)), keyEquivalent: "r")
        chipMenu.addItem(withTitle: "Blank Check", action: #selector(MainWindowController.blankCheck(_:)), keyEquivalent: "b")
        chipMenu.addItem(withTitle: "Verify", action: #selector(MainWindowController.verifyChip(_:)), keyEquivalent: "")
        chipMenu.addItem(withTitle: "Program…", action: #selector(MainWindowController.programChip(_:)), keyEquivalent: "")
        chipMenu.addItem(withTitle: "Logic Test", action: #selector(MainWindowController.logicTest(_:)), keyEquivalent: "t")
        chipMenu.addItem(withTitle: "Identify Logic Chip…", action: #selector(MainWindowController.identifyLogic(_:)), keyEquivalent: "")
        chipMenu.addItem(.separator())
        chipMenu.addItem(withTitle: "Stop", action: #selector(MainWindowController.stop(_:)), keyEquivalent: ".")
        chipItem.submenu = chipMenu

        let winItem = NSMenuItem(); main.addItem(winItem)
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "Log", action: #selector(MainWindowController.toggleLog(_:)), keyEquivalent: "l")
        winItem.submenu = winMenu
        NSApp.windowsMenu = winMenu
        return main
    }
}
