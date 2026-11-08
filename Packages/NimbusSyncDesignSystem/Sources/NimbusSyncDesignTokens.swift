import SwiftUI

public enum NimbusSyncDesignTokens {
    public static let spacing4: CGFloat = 4
    public static let spacing8: CGFloat = 8
    public static let spacing12: CGFloat = 12
    public static let spacing16: CGFloat = 16
    public static let spacing20: CGFloat = 20
    public static let cornerRadius: CGFloat = 8
    public static let popoverCardRadius: CGFloat = 10
    public static let settingsCardRadius: CGFloat = 12
    public static let settingsIconButtonSize: CGFloat = 34
    public static let iconTileSize: CGFloat = 32
    public static let controlSize: CGFloat = 28
    public static let popoverWidth: CGFloat = 400
    // Cloudreve's core logo blue (#056FEE).
    public static let brandColor = Color(red: 5 / 255, green: 111 / 255, blue: 238 / 255)
    /// Laid at 90% over the sidebar material, this lands on the design's light periwinkle
    /// (#E1E8F8) whatever the wallpaper behind the window.
    public static let settingsSidebarTint = Color(red: 224 / 255, green: 232 / 255, blue: 251 / 255)
    /// The selected sidebar item's wash (#0A84FF, a brighter blue than the brand), at 20% in light
    /// mode it reads as the design's #C3DBFC on the periwinkle.
    public static let settingsSidebarSelection = Color(red: 10 / 255, green: 132 / 255, blue: 1)
}
