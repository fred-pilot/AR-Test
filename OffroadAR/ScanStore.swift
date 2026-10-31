import ARKit

/// Speichert eigene Scans unter Dokumente/Scans (in der Dateien-App sichtbar).
enum ScanStore {
    static var directory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("Scans", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func savedScans() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "arobject" }
    }

    static func save(_ object: ARReferenceObject) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = directory.appendingPathComponent("Auto_\(formatter.string(from: Date())).arobject")
        try object.export(to: url, previewImage: nil)
        return url
    }

    static func deleteAll() {
        for url in savedScans() {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// Alle Scans, nach denen die App sucht: die mitgelieferten aus dem App-Bundle
/// (Resources/ReferenceObjects) und die selbst erstellten.
enum ReferenceObjectLibrary {
    static func load() -> Set<ARReferenceObject> {
        var urls = Bundle.main.urls(forResourcesWithExtension: "arobject", subdirectory: "ReferenceObjects") ?? []
        urls += ScanStore.savedScans()

        var objects = Set<ARReferenceObject>()
        for url in urls {
            guard let object = try? ARReferenceObject(archiveURL: url) else { continue }
            object.name = url.deletingPathExtension().lastPathComponent
            objects.insert(object)
        }
        return objects
    }
}
