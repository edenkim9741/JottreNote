extension DefaultsKey where T == String {
    static let webDAVURL: DefaultsKey = "webdav_url"
    static let webDAVUsername: DefaultsKey = "webdav_username"
    static let webDAVPassword: DefaultsKey = "webdav_password"
}

extension DefaultsKey where T == Int {
    /// Automatic WebDAV backup cadence in minutes. A value of zero disables
    /// both the in-app timer and future BackgroundTasks requests.
    static let webDAVBackupIntervalMinutes: DefaultsKey = "webdav_backup_interval_minutes"
}
