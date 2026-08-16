import Crypto
import Foundation
import SDKCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Orchestrates the App Store Connect Build Upload flow for an IPA:
///
/// 1. Create the Build Upload for the app, marketing version, and build number.
/// 2. Create the Build Upload File reservation.
/// 3. Execute every returned delivery operation with the exact method, URL, required
///    headers, byte offset, and length.
/// 4. Compute source checksums, verify against any server-declared expected values,
///    and PATCH the file as uploaded.
/// 5. Poll the Build Upload to a terminal state.
/// 6. Resolve the exact resulting build by app + marketing version + build number.
/// 7. Poll build processing and `buildBetaDetail` to internal TestFlight readiness.
///
/// The flow is kept separable: each step is independently testable and credential-free
/// parts (parsing, checksum verification, state transitions) take no credentials.
public struct BuildUploader: Sendable {
    public var operations: ASCOperations
    /// Injectable poll delay and clock so tests can advance state without sleeping.
    public var sleep: @Sendable (TimeInterval) throws -> Void
    public var now: @Sendable () -> Date
    public var logger: (@Sendable (String) -> Void)?

    public init(
        operations: ASCOperations,
        sleep: @escaping @Sendable (TimeInterval) throws -> Void = { interval in Thread.sleep(forTimeInterval: interval) },
        now: @escaping @Sendable () -> Date = { Date() },
        logger: (@Sendable (String) -> Void)? = nil
    ) {
        self.operations = operations
        self.sleep = sleep
        self.now = now
        self.logger = logger
    }

    /// Time budgets for the upload and polling phases.
    public struct Timeouts: Sendable {
        public var uploadOperation: TimeInterval
        public var buildUploadPoll: TimeInterval
        public var buildResolutionPoll: TimeInterval
        public var processingPoll: TimeInterval
        public var pollInterval: TimeInterval

        public init(
            uploadOperation: TimeInterval = 300,
            buildUploadPoll: TimeInterval = 600,
            buildResolutionPoll: TimeInterval = 900,
            processingPoll: TimeInterval = 5400,
            pollInterval: TimeInterval = 20
        ) {
            self.uploadOperation = uploadOperation
            self.buildUploadPoll = buildUploadPoll
            self.buildResolutionPoll = buildResolutionPoll
            self.processingPoll = processingPoll
            self.pollInterval = pollInterval
        }
    }

    /// The public-safe result of a completed upload.
    public struct Result: Sendable {
        public var buildUploadID: String
        public var buildUploadFileID: String
        public var uploadState: String?
        public var buildID: String?
        public var processingState: String?
        public var internalBetaState: String?
        public var externalBetaState: String?
        public var checksums: ASCSourceFileChecksums

        public init(
            buildUploadID: String,
            buildUploadFileID: String,
            uploadState: String? = nil,
            buildID: String? = nil,
            processingState: String? = nil,
            internalBetaState: String? = nil,
            externalBetaState: String? = nil,
            checksums: ASCSourceFileChecksums = ASCSourceFileChecksums()
        ) {
            self.buildUploadID = buildUploadID
            self.buildUploadFileID = buildUploadFileID
            self.uploadState = uploadState
            self.buildID = buildID
            self.processingState = processingState
            self.internalBetaState = internalBetaState
            self.externalBetaState = externalBetaState
            self.checksums = checksums
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        case fileUnreadable(String)
        case invalidOperation(String)
        case uploadRejected(Int, String)
        case noUploadOperations(String)
        case checksumMismatch(String, String, String)
        case uploadFailed([String])
        case timedOut(String)
        case buildNotFound(String, String, String)
        case processingFailed(String, String)
        case betaStateFailure(String)

        public var description: String {
            switch self {
            case let .fileUnreadable(path):
                return "Could not read the IPA at '\(path)'."
            case let .invalidOperation(detail):
                return "App Store Connect returned an invalid upload operation: \(detail)"
            case let .uploadRejected(status, detail):
                return "Upload delivery failed with HTTP \(status). \(detail)"
            case let .noUploadOperations(uploadID):
                return "Build Upload \(uploadID) returned no upload operations."
            case let .checksumMismatch(field, expected, computed):
                return "Checksum mismatch for '\(field)': expected \(expected), computed \(computed)."
            case let .uploadFailed(errors):
                return "App Store Connect Build Upload failed.\(errors.isEmpty ? "" : " \(errors.joined(separator: "; "))")"
            case let .timedOut(phase):
                return "Timed out while \(phase). Check the upload state and retry with `stupid-app release upload`."
            case let .buildNotFound(version, build, marketing):
                return "Could not resolve the uploaded build for \(version) (\(build)); expected marketing version \(marketing)."
            case let .processingFailed(state, detail):
                return "Build processing ended in \(state).\(detail.isEmpty ? "" : " \(detail)")"
            case let .betaStateFailure(state):
                return "Build beta state is \(state); internal TestFlight readiness was not reached."
            }
        }
    }

    /// Uploads an IPA and optionally waits for internal TestFlight readiness.
    /// - Parameter wait: when true, polls through Build Upload completion, exact-build
    ///   resolution, processing, and internal beta readiness.
    public func upload(ipaURL: URL, appID: String, version: String, buildNumber: String, wait: Bool, timeouts: Timeouts = Timeouts()) throws -> Result {
        guard FileManager.default.fileExists(atPath: ipaURL.path) else {
            throw Error.fileUnreadable(ipaURL.path)
        }
        let fileSize = try fileSize(of: ipaURL)

        // 1. Create the Build Upload.
        let upload = try operations.createBuildUpload(appID: appID, version: version, buildNumber: buildNumber)
        logger?("Created Build Upload \(upload.id)")

        // 2. Create the Build Upload File reservation.
        let file = try operations.createBuildUploadFile(
            buildUploadID: upload.id,
            fileName: ipaURL.lastPathComponent,
            fileSize: fileSize
        )
        guard !file.uploadOperations.isEmpty else {
            throw Error.noUploadOperations(upload.id)
        }

        // 3. Execute every delivery operation with exact offsets.
        try executeOperations(file.uploadOperations, ipaURL: ipaURL, timeout: timeouts.uploadOperation)

        // 4. Compute checksums, verify, and commit. The server declares expected
        //    checksums in the create response; when it declares none, commit with
        //    `uploaded: true` only (a checksum payload the server did not ask for is
        //    rejected).
        let checksums = try Self.computeAndVerifyChecksums(fileURL: ipaURL, expected: file.sourceFileChecksums)
        try operations.updateBuildUploadFile(id: file.id, sourceFileChecksums: checksums, uploaded: true)
        logger?("Marked upload file \(file.id) as uploaded")

        var result = Result(
            buildUploadID: upload.id,
            buildUploadFileID: file.id,
            checksums: checksums ?? ASCSourceFileChecksums()
        )

        guard wait else { return result }

        // 5. Poll the Build Upload to a terminal state.
        let terminal = try pollBuildUpload(uploadID: upload.id, timeout: timeouts.buildUploadPoll, interval: timeouts.pollInterval)
        result.uploadState = terminal

        // 6. Resolve the exact build by app + marketing version + build number.
        let build = try pollExactBuild(
            appID: appID,
            version: version,
            buildNumber: buildNumber,
            timeout: timeouts.buildResolutionPoll,
            interval: timeouts.pollInterval
        )
        result.buildID = build.id

        // 7. Poll processing and internal beta readiness.
        let processed = try pollProcessing(buildID: build.id, timeout: timeouts.processingPoll, interval: timeouts.pollInterval)
        result.processingState = processed
        let beta = try pollInternalBeta(buildID: build.id, timeout: timeouts.processingPoll, interval: timeouts.pollInterval)
        result.internalBetaState = beta.internalBuildState
        result.externalBetaState = beta.externalBuildState
        return result
    }

    // MARK: - Delivery execution

    private func executeOperations(_ operations: [DeliveryFileUploadOperation], ipaURL: URL, timeout: TimeInterval) throws {
        let handle = try FileHandle(forReadingFrom: ipaURL)
        defer { try? handle.close() }
        for operation in operations {
            try executeOperation(operation, handle: handle, timeout: timeout)
        }
    }

    private func executeOperation(_ operation: DeliveryFileUploadOperation, handle: FileHandle, timeout: TimeInterval) throws {
        guard !operation.url.isEmpty, operation.offset >= 0, operation.length > 0,
              let url = URL(string: operation.url) else {
            throw Error.invalidOperation("offset=\(operation.offset) length=\(operation.length) url=\(operation.url.isEmpty ? "<empty>" : "<presigned>")")
        }
        let range = try readRange(handle: handle, offset: operation.offset, length: operation.length)
        let method = operation.method.isEmpty ? "PUT" : operation.method
        let response = try operations.client.rawRequest(
            method: method,
            url: url,
            headers: operation.requestHeaders,
            body: range,
            timeout: timeout
        )
        guard (200..<300).contains(response.statusCode) else {
            throw Error.uploadRejected(response.statusCode, String(decoding: response.data.prefix(200), as: UTF8.self))
        }
    }

    /// Reads exactly `length` bytes at `offset` from a file handle.
    func readRange(handle: FileHandle, offset: Int64, length: Int64) throws -> Data {
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: Int(length))
        guard let data, data.count == length else {
            throw Error.fileUnreadable("expected \(length) bytes at offset \(offset)")
        }
        return data
    }

    // MARK: - Checksums

    /// Computes the source-file checksums and verifies them against any expected values
    /// the server declared. Composite is always MD5; `file` follows the declared
    /// algorithm (MD5 or SHA-256). Returns nil when the server declared no expected
    /// checksums, in which case the commit carries only `uploaded: true`.
    public static func computeAndVerifyChecksums(fileURL: URL, expected: ASCSourceFileChecksums?) throws -> ASCSourceFileChecksums? {
        let fileData = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let declaredFile = expected?.file
        let declaredComposite = expected?.composite
        guard declaredFile != nil || declaredComposite != nil else {
            return nil
        }

        let fileChecksum: ASCChecksumValue
        if let declared = declaredFile, declared.algorithm == "SHA_256" {
            let computed = ASCChecksumValue(hash: SHA256.hex(data: fileData), algorithm: "SHA_256")
            try verify(declared, computed: computed, field: "file")
            fileChecksum = computed
        } else {
            let computed = ASCChecksumValue(hash: MD5.hex(data: fileData), algorithm: "MD5")
            if let declared = declaredFile {
                try verify(declared, computed: computed, field: "file")
            }
            fileChecksum = computed
        }

        let composite: ASCChecksumValue
        let computedComposite = ASCChecksumValue(hash: MD5.hex(data: fileData), algorithm: "MD5")
        if let declared = declaredComposite {
            try verify(declared, computed: computedComposite, field: "composite")
        }
        composite = computedComposite

        return ASCSourceFileChecksums(file: fileChecksum, composite: composite)
    }

    private static func verify(_ declared: ASCChecksumValue, computed: ASCChecksumValue, field: String) throws {
        guard declared.hash.caseInsensitiveCompare(computed.hash) == .orderedSame else {
            throw Error.checksumMismatch(field, declared.hash, computed.hash)
        }
    }

    // MARK: - Polling

    private func pollBuildUpload(uploadID: String, timeout: TimeInterval, interval: TimeInterval) throws -> String {
        let deadline = now().addingTimeInterval(timeout)
        while true {
            let upload = try operations.getBuildUpload(id: uploadID)
            switch upload.state {
            case "COMPLETE":
                return "COMPLETE"
            case "FAILED":
                throw Error.uploadFailed(upload.stateErrors)
            case "PROCESSING", "AWAITING_UPLOAD", .none:
                if now() > deadline {
                    throw Error.timedOut("waiting for Build Upload \(uploadID)")
                }
                try sleep(interval)
            default:
                throw Error.uploadFailed(["unexpected state '\(upload.state ?? "nil")'"])
            }
        }
    }

    private func pollExactBuild(appID: String, version: String, buildNumber: String, timeout: TimeInterval, interval: TimeInterval) throws -> ASCBuild {
        let deadline = now().addingTimeInterval(timeout)
        while true {
            if let build = try operations.findBuild(appID: appID, version: version, buildNumber: buildNumber) {
                return build
            }
            if now() > deadline {
                throw Error.buildNotFound("version \(version)", "build \(buildNumber)", version)
            }
            try sleep(interval)
        }
    }

    private func pollProcessing(buildID: String, timeout: TimeInterval, interval: TimeInterval) throws -> String {
        let deadline = now().addingTimeInterval(timeout)
        while true {
            let build = try operations.getBuild(id: buildID)
            switch build.processingState {
            case "VALID":
                return "VALID"
            case "FAILED", "INVALID":
                throw Error.processingFailed(build.processingState ?? "unknown", "")
            case .none, "PROCESSING":
                if now() > deadline {
                    throw Error.timedOut("waiting for build \(buildID) processing")
                }
                try sleep(interval)
            default:
                throw Error.processingFailed(build.processingState ?? "unknown", "")
            }
        }
    }

    /// Polls `buildBetaDetail` until the internal state is ready for internal
    /// TestFlight testing. Terminal failures throw; transient states keep polling.
    private func pollInternalBeta(buildID: String, timeout: TimeInterval, interval: TimeInterval) throws -> ASCBuildBetaDetail {
        let deadline = now().addingTimeInterval(timeout)
        while true {
            let detail = try operations.getBuildBetaDetail(buildID: buildID)
            switch try Self.betaReadinessDecision(detail.internalBuildState) {
            case .ready:
                return detail
            case .keepPolling:
                if now() > deadline {
                    throw Error.timedOut("waiting for internal beta readiness of build \(buildID)")
                }
                try sleep(interval)
            }
        }
    }

    /// Classifies an internal beta state into a readiness decision without any I/O so
    /// state transitions are unit-testable.
    enum BetaReadinessDecision: Sendable, Equatable {
        case ready
        case keepPolling
    }

    static func betaReadinessDecision(_ state: String?) throws -> BetaReadinessDecision {
        switch state {
        case "READY_FOR_BETA_TESTING", "IN_BETA_TESTING":
            return .ready
        case "PROCESSING_EXCEPTION", "MISSING_EXPORT_COMPLIANCE", "EXPIRED":
            throw Error.betaStateFailure(state ?? "unknown")
        case .none, "PROCESSING":
            return .keepPolling
        default:
            throw Error.betaStateFailure(state ?? "unknown")
        }
    }

    private func fileSize(of url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw Error.fileUnreadable(url.path)
        }
        return size.int64Value
    }
}

// MARK: - MD5

/// MD5 digest for the ASC `composite` checksum and MD5-declared `file` checksums.
/// MD5 is not used for security here; App Store Connect mandates it for upload
/// verification.
enum MD5 {
    static func hex(data: Data) -> String {
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
