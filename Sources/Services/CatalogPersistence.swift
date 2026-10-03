import Foundation

/// Stores app metadata only. Never writes to a selected project directory.
struct CatalogPersistence {
    private let fileURL: URL
    init(directory: URL? = nil) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MoeKit", isDirectory: true)
        fileURL = root.appendingPathComponent("projects.json")
    }
    func load() throws -> [ProjectRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([ProjectRecord].self, from: data)
    }
    func save(_ projects: [ProjectRecord]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(projects)
        try data.write(to: fileURL, options: .atomic)
    }
}
