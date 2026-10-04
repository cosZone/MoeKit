import Foundation

// Native experiment only. This target is not embedded in MoeKit or its releases.
@objc protocol GitSandboxProbeProtocol {
    func probe(bookmark: Data, selectedPath: String, outsidePath: String,
               reply: @escaping (Data) -> Void)
    func probeDescriptor(directory: FileHandle, selectedPath: String, outsidePath: String,
                         reply: @escaping (Data) -> Void)
}
