import AppKit
import CloudreveDomainKit

/// AppKit builds the application's standard menus in the launch language. SwiftUI's locale
/// environment does not update those titles, so identify commands by selector or shortcut.
@MainActor
public enum AppMenuLocalization {
    public static func apply(to menu: NSMenu? = NSApp.mainMenu) {
        guard let menu else { return }
        for item in menu.items {
            guard let submenu = item.submenu else { continue }
            if submenu.items.contains(where: { $0.keyEquivalent == "q" || $0.keyEquivalent == "," }) {
                localizeApplicationMenu(submenu)
            } else if submenu === NSApp.windowsMenu {
                item.title = L10n.tr("Window")
            } else if submenu === NSApp.helpMenu {
                item.title = L10n.tr("Help")
            } else if contains(submenu, selector: "undo:") || contains(submenu, selector: "cut:") {
                item.title = L10n.tr("Edit")
            } else if contains(submenu, selector: "toggleFullScreen:") || contains(submenu, selector: "toggleTabBar:") {
                item.title = L10n.tr("View")
            } else if let key = standardMenuTitles[item.title] {
                item.title = L10n.text(key)
            }
            if submenu.title != item.title { submenu.title = item.title }
            localizeCommands(submenu)
        }
    }

    private static func contains(_ menu: NSMenu, selector: String) -> Bool {
        menu.items.contains { $0.action.map(NSStringFromSelector) == selector || $0.submenu.map { contains($0, selector: selector) } == true }
    }

    private static func localizeApplicationMenu(_ menu: NSMenu) {
        for (index, item) in menu.items.enumerated() where !item.isSeparatorItem {
            let action = item.action.map(NSStringFromSelector) ?? ""
            if index == 0 {
                item.title = L10n.tr("About \(AppIdentity.displayName)")
            } else if item.keyEquivalent == "," {
                item.title = L10n.tr("Settings…")
            } else if item.keyEquivalent == "q" || action == "terminate:" {
                item.title = L10n.tr("Quit \(AppIdentity.displayName)")
            } else if item.keyEquivalent == "h" {
                item.title = item.keyEquivalentModifierMask.contains(.option) ? L10n.tr("Hide Others") : L10n.tr("Hide \(AppIdentity.displayName)")
            } else if action == "unhideAllApplications:" {
                item.title = L10n.tr("Show All")
            } else if let submenu = item.submenu, submenu === NSApp.servicesMenu {
                item.title = L10n.tr("Services")
            }
            if let submenu = item.submenu, submenu.title != item.title { submenu.title = item.title }
        }
    }

    // Framework-created top-level menus have no public role identifier on older macOS.
    // This fallback recognizes only Apple's standard English/Chinese titles, never user data.
    private static let standardMenuTitles = [
        "Edit": "Edit", "编辑": "Edit", "View": "View", "显示": "View", "查看": "View",
        "Window": "Window", "窗口": "Window", "Help": "Help", "帮助": "Help",
    ]

    private static let commandKeys: [String: String] = [
        "undo:": "Undo", "redo:": "Redo", "cut:": "Cut", "copy:": "Copy", "paste:": "Paste",
        "pasteAsPlainText:": "Paste and Match Style", "delete:": "Delete", "selectAll:": "Select All",
        "performMiniaturize:": "Minimize", "performZoom:": "Zoom", "arrangeInFront:": "Bring All to Front",
        "showAllTabs:": "Show All Tabs",
    ]

    private static func localizeCommands(_ menu: NSMenu) {
        for item in menu.items {
            let action = item.action.map(NSStringFromSelector) ?? ""
            if let key = commandKeys[action] {
                item.title = L10n.text(key)
            } else if action == "toggleTabBar:" {
                item.title = NSApp.keyWindow?.tabGroup?.isTabBarVisible == true ? L10n.tr("Hide Tab Bar") : L10n.tr("Show Tab Bar")
            } else if action == "toggleFullScreen:" {
                item.title = NSApp.keyWindow?.styleMask.contains(.fullScreen) == true ? L10n.tr("Exit Full Screen") : L10n.tr("Enter Full Screen")
            }
            if let submenu = item.submenu { localizeCommands(submenu) }
        }
    }
}
