/*
 Jottre: Minimalistic jotting for iPhone, iPad and Mac.
 Copyright (C) 2021-2026 Anton Lorani

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

import Foundation

/// Process-wide WebDAV graph. Jottre supports multiple scenes, so constructing
/// backup services inside each SceneDelegate would create independent timers
/// and allow overlapping uploads to the same remote paths.
@MainActor
final class WebDAVApplicationServices {

    static let shared = WebDAVApplicationServices()

    let defaultsService: DefaultsService
    let editorFlushRegistry: WebDAVEditorFlushRegistry
    let backupService: WebDAVBackupService
    let autoBackupScheduler: WebDAVAutoBackupScheduler

    private init() {
        let defaultsService = DefaultsService(userDefaults: .standard)
        let fileService = LocalFileService(fileManager: .default)
        let editorFlushRegistry = WebDAVEditorFlushRegistry()
        let operationGate = WebDAVBackupOperationGate()
        let backupService = WebDAVBackupService(
            defaultsService: defaultsService,
            fileService: fileService,
            operationGate: operationGate
        )

        self.defaultsService = defaultsService
        self.editorFlushRegistry = editorFlushRegistry
        self.backupService = backupService
        autoBackupScheduler = WebDAVAutoBackupScheduler(
            defaultsService: defaultsService,
            backgroundTaskScheduler: SystemWebDAVBackgroundTaskScheduler(),
            flushEditors: {
                await editorFlushRegistry.flushAll()
            },
            performBackup: {
                await backupService.backupAllAutomatically()
            },
            logger: OSLogLogger(category: "WebDAVAutoBackup")
        )
    }
}
