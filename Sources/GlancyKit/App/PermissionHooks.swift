// Modules that must notice a permission granted while they run (no relaunch). Each one's
// `permissionsChanged()` lives in its own folder; the AppDelegate calls it when the permission
// center sees a change.

extension CalendarModule: PermissionAware {}
extension HUDModule: PermissionAware {}
extension PowerModule: PermissionAware {}
extension ClipboardModule: PermissionAware {}
extension WindowsModule: PermissionAware {}
