import Foundation
import Darwin

// Native fixture only; never compiled into the app or Swift Testing host. The
// Python driver launches two exec'd processes and controls each save via pipes.
// Its catalog directory is always a unique synthetic temporary fixture.
func respond(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
}

func run() throws {
    guard CommandLine.arguments.count == 4 else { throw FixtureError.protocolFailure }
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let label = CommandLine.arguments[2]
    let hold = CommandLine.arguments[3] == "hold"
    let persistence = CatalogPersistence(directory: root) {
        if hold {
            respond("LOCKED")
            guard let command = readLine() else { throw FixtureError.protocolFailure }
            if command == "ABORT" { throw FixtureError.aborted }
            guard command == "COMMIT" else { throw FixtureError.protocolFailure }
        }
    }
    var projects = try persistence.load()
    let project = ProjectRecord(name: label, path: root.appendingPathComponent("synthetic-" + label).path, kind: .folder)
    respond("LOADED")
    while let command = readLine() {
        switch command {
        case "SAVE":
            var updated = projects
            if !updated.contains(where: { $0.id == project.id }) { updated.append(project) }
            do {
                try persistence.save(updated)
                projects = updated
                respond("SAVED")
            } catch CatalogPersistence.CatalogError.writerBusy {
                respond("BUSY")
            } catch CatalogPersistence.CatalogError.changedSinceLoad {
                respond("CONFLICT")
            } catch FixtureError.aborted {
                respond("ABORTED")
            }
        case "LOAD":
            projects = try persistence.load()
            respond("LOADED")
        case "EXIT": return
        default: throw FixtureError.protocolFailure
        }
    }
}

enum FixtureError: Error { case protocolFailure, aborted }

do {
    try run()
} catch {
    respond("ERROR: \(error)")
    exit(1)
}
