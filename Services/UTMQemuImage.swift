//
// Copyright © 2022 osy. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import Foundation
import QEMUKitInternal

@objc class UTMQemuImage: UTMProcess {
    typealias ProgressCallback = (Float) -> Void

    private var logOutput: String = ""
    private var processExitContinuation: CheckedContinuation<Void, any Error>?
    private var onProgress: ProgressCallback?

    private init() {
        super.init(arguments: [])
    }
    
    override func processHasExited(_ exitCode: Int, message: String?) {
        if let processExitContinuation = processExitContinuation {
            self.processExitContinuation = nil
            if exitCode != 0 {
                if let message = message {
                    processExitContinuation.resume(throwing: UTMQemuImageError.qemuError(message))
                } else {
                    processExitContinuation.resume(throwing: UTMQemuImageError.unknown)
                }
            } else {
                processExitContinuation.resume()
            }
        }
    }
    
    private func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            processExitContinuation = continuation
            start("qemu-img") { error in
                if let error = error {
                    self.processExitContinuation = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    static func convert(from url: URL, toQcow2 dest: URL, withCompression compressed: Bool = false, onProgress: ProgressCallback? = nil) async throws {
        let qemuImg = UTMQemuImage()
        let srcBookmark = try url.bookmarkData()
        let dstBookmark = try dest.deletingLastPathComponent().bookmarkData()
        qemuImg.pushArgv("convert")
        if onProgress != nil {
            qemuImg.pushArgv("-p")
        }
        if compressed {
            qemuImg.pushArgv("-c")
            qemuImg.pushArgv("-o")
            qemuImg.pushArgv("compression_type=zstd")
        }
        qemuImg.pushArgv("-O")
        qemuImg.pushArgv("qcow2")
        qemuImg.accessData(withBookmark: srcBookmark)
        qemuImg.pushArgv(url.path)
        qemuImg.accessData(withBookmark: dstBookmark)
        qemuImg.pushArgv(dest.path)
        let logging = QEMULogging()
        logging.delegate = qemuImg
        qemuImg.standardOutput = logging.standardOutput
        qemuImg.standardError = logging.standardError
        qemuImg.onProgress = onProgress
        try await qemuImg.start()
    }
    
    /*
     The info format looks like:
     
     $ qemu-img info foo.img --output=json
     {
         "virtual-size": 20971520,
         "filename": "foo.img",
         "cluster-size": 65536,
         "format": "qcow2",
         "actual-size": 200704,
         "format-specific": {
             "type": "qcow2",
             "data": {
                 "compat": "1.1",
                 "compression-type": "zlib",
                 "lazy-refcounts": false,
                 "refcount-bits": 16,
                 "corrupt": false,
                 "extended-l2": false
             }
         },
         "dirty-flag": false
     }
     */

    struct QemuImageInfo : Codable {
        let virtualSize : Int64
        let filename : String
        let clusterSize : Int32
        let format : String
        let actualSize : Int64
        let dirtyFlag : Bool
        /// Absent for images that hold none, and for raw images entirely.
        let snapshots : [Snapshot]?

        /// One internal snapshot inside a QCOW2 image.
        struct Snapshot: Codable, Hashable {
            let id: String
            let name: String
            /// Bytes of saved RAM. Zero means the snapshot captured only the
            /// disk, so restoring it boots rather than resumes.
            let vmStateSize: Int64?
            let dateSec: TimeInterval?

            var creationDate: Date? {
                dateSec.map { Date(timeIntervalSince1970: $0) }
            }

            var includesMemory: Bool {
                (vmStateSize ?? 0) > 0
            }

            private enum CodingKeys: String, CodingKey {
                case id
                case name
                case vmStateSize = "vm-state-size"
                case dateSec = "date-sec"
            }
        }

        private enum CodingKeys: String, CodingKey {
            case virtualSize = "virtual-size"
            case filename
            case clusterSize = "cluster-size"
            case format
            case actualSize = "actual-size"
            case dirtyFlag = "dirty-flag"
            case snapshots
        }
    }

    static func size(image url: URL) async throws -> Int64 {
        let qemuImg = UTMQemuImage()
        let srcBookmark = try url.bookmarkData()
        qemuImg.pushArgv("info")
        qemuImg.pushArgv("--output=json")
        qemuImg.accessData(withBookmark: srcBookmark)
        qemuImg.pushArgv(url.path)
        let logging = QEMULogging()
        logging.delegate = qemuImg
        qemuImg.standardOutput = logging.standardOutput
        qemuImg.standardError = logging.standardError
        try await qemuImg.start()

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let data = qemuImg.logOutput.data(using: .utf8) ?? Data()
        let image_info: QemuImageInfo = try decoder.decode(QemuImageInfo.self, from: data)

        return image_info.virtualSize
    }

    /// Lists the internal snapshots stored in a QCOW2 image.
    ///
    /// Read from the image rather than the running QEMU monitor, which offers
    /// save, restore and delete but no way to enumerate. `--force-share` is
    /// needed because a running VM holds a write lock, and without it qemu-img
    /// refuses to read the image at all.
    static func snapshots(image url: URL) async throws -> [QemuImageInfo.Snapshot] {
        let qemuImg = UTMQemuImage()
        let srcBookmark = try url.bookmarkData()
        qemuImg.pushArgv("info")
        qemuImg.pushArgv("--output=json")
        qemuImg.pushArgv("--force-share")
        qemuImg.accessData(withBookmark: srcBookmark)
        qemuImg.pushArgv(url.path)
        let logging = QEMULogging()
        logging.delegate = qemuImg
        qemuImg.standardOutput = logging.standardOutput
        qemuImg.standardError = logging.standardError
        try await qemuImg.start()

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let data = qemuImg.logOutput.data(using: .utf8) ?? Data()
        let info = try decoder.decode(QemuImageInfo.self, from: data)
        return info.snapshots ?? []
    }

    /// Creates, applies or deletes an internal snapshot on a stopped image.
    ///
    /// Only valid when the VM is not running: these rewrite the image, and
    /// QEMU holds a write lock while it has the disk open. A running VM's
    /// snapshots go through the monitor instead.
    static func snapshotOperation(_ operation: SnapshotOperation,
                                  named name: String,
                                  image url: URL) async throws {
        let qemuImg = UTMQemuImage()
        let srcBookmark = try url.bookmarkData()
        qemuImg.pushArgv("snapshot")
        qemuImg.pushArgv(operation.flag)
        qemuImg.pushArgv(name)
        qemuImg.accessData(withBookmark: srcBookmark)
        qemuImg.pushArgv(url.path)
        let logging = QEMULogging()
        logging.delegate = qemuImg
        qemuImg.standardOutput = logging.standardOutput
        qemuImg.standardError = logging.standardError
        try await qemuImg.start()
    }

    enum SnapshotOperation {
        case create
        case apply
        case delete

        var flag: String {
            switch self {
            case .create: return "-c"
            case .apply: return "-a"
            case .delete: return "-d"
            }
        }
    }

    static func resize(image url: URL, size : UInt64) async throws {
        let qemuImg = UTMQemuImage()
        let srcBookmark = try url.bookmarkData()
        qemuImg.pushArgv("resize")
        qemuImg.pushArgv("-f")
        qemuImg.pushArgv("qcow2")
        qemuImg.accessData(withBookmark: srcBookmark)
        qemuImg.pushArgv(url.path)
        qemuImg.pushArgv(String(size))
        let logging = QEMULogging()
        logging.delegate = qemuImg
        qemuImg.standardOutput = logging.standardOutput
        qemuImg.standardError = logging.standardError
        try await qemuImg.start()
    }
}

private enum UTMQemuImageError: Error {
    case qemuError(String)
    case unknown
}

extension UTMQemuImageError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .qemuError(let message): return message
        case .unknown: return NSLocalizedString("An unknown QEMU error has occurred.", comment: "UTMQemuImage")
        }
    }
}

// MARK: - Logging

extension UTMQemuImage: QEMULoggingDelegate {
    func logging(_ logging: QEMULogging, didRecieveOutputLine line: String) {
        logOutput += line
        if let onProgress = onProgress, line.contains("100%") {
            if let progress = parseProgress(line) {
                onProgress(progress)
            }
        }
    }
    
    func logging(_ logging: QEMULogging, didRecieveErrorLine line: String) {
    }
}

extension UTMQemuImage {
    private func parseProgress(_ line: String) -> Float? {
        let pattern = "\\(([0-9]+\\.[0-9]+)/100\\%\\)"
        do {
            let regex = try NSRegularExpression(pattern: pattern)
            if let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: line.count)) {
                let range = match.range(at: 1)
                if let swiftRange = Range(range, in: line) {
                    let floatValueString = line[swiftRange]
                    if let floatValue = Float(floatValueString) {
                        return floatValue
                    }
                }
            }
        } catch {

        }
        return nil
    }
}
