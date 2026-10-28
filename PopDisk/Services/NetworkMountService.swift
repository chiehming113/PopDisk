import AppKit
import Darwin
import NetFS

enum NetworkMountError: LocalizedError, Sendable {
    case cancelled
    case authenticationFailed
    case unreachable
    case shareNotFound
    case failed(Int32)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            String(localized: "Connection was cancelled.")
        case .authenticationFailed:
            String(localized: "Incorrect username or password.")
        case .unreachable:
            String(localized: "Couldn't reach the server. Check the address and your network connection.")
        case .shareNotFound:
            String(localized: "The shared folder doesn't exist on the server.")
        case .failed(let code):
            String(localized: "Couldn't connect (error \(code)).")
        }
    }
}

/// 列出、掛載網路卷宗。卸載走 DiskArbitration（與外接碟共用 busy 處理）。
@MainActor
final class NetworkMountService {
    var onChange: (() -> Void)?

    private var observers: [NSObjectProtocol] = []

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange?() }
            }
        }
    }

    // MARK: - 列出

    /// 用 getfsstat(MNT_NOWAIT) 讀系統快取的掛載資訊。
    /// 不用 URL resourceValues：伺服器失聯時，那些 API 會卡住數十秒。
    func mountedVolumes() -> [NetworkVolume] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        var stats = Array(repeating: Darwin.statfs(), count: Int(count))
        let filled = stats.withUnsafeMutableBufferPointer { buffer in
            getfsstat(buffer.baseAddress, Int32(MemoryLayout<statfs>.stride * buffer.count), MNT_NOWAIT)
        }
        guard filled > 0 else { return [] }

        return stats.prefix(Int(filled)).compactMap { stat in
            var stat = stat
            let type = Self.string(from: &stat.f_fstypename)
            guard let networkProtocol = NetworkProtocol(fileSystemType: type),
                  stat.f_flags & UInt32(MNT_DONTBROWSE) == 0 else { return nil }
            let mountPath = Self.string(from: &stat.f_mntonname)
            let source = Self.string(from: &stat.f_mntfromname)
            let blockSize = Int64(stat.f_bsize)
            return NetworkVolume(
                name: (mountPath as NSString).lastPathComponent,
                mountURL: URL(filePath: mountPath, directoryHint: .isDirectory),
                networkProtocol: networkProtocol,
                serverURL: Self.serverURL(from: source, protocol: networkProtocol),
                totalBytes: stat.f_blocks > 0 ? Int64(stat.f_blocks) * blockSize : nil,
                availableBytes: stat.f_blocks > 0 ? Int64(stat.f_bavail) * blockSize : nil
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// f_mntfromname 轉成伺服器位址：
    /// smbfs `//user@host/share`、nfs `host:/export/path`、webdav 本身就是 `https://host/path`
    nonisolated static func serverURL(from source: String, protocol networkProtocol: NetworkProtocol) -> URL? {
        switch networkProtocol {
        case .smb, .afp:
            guard source.hasPrefix("//") else { return nil }
            let scheme = networkProtocol == .smb ? "smb" : "afp"
            // 去掉 smbfs 可能附帶的 workgroup 前綴（例如 //WORKGROUP;user@host）
            var rest = String(source.dropFirst(2))
            if let semicolon = rest.firstIndex(of: ";"), rest[..<semicolon].contains("@") == false {
                rest = String(rest[rest.index(after: semicolon)...])
            }
            return URL(string: "\(scheme)://\(rest)")
        case .nfs:
            // IPv6 位址本身含有 :（例如 fe80::1%en0:/export），分隔點要取路徑開頭前的最後一個 :
            let hostEnd = source.firstIndex(of: "/") ?? source.endIndex
            guard let colon = source[..<hostEnd].lastIndex(of: ":") else { return nil }
            var host = String(source[..<colon])
            let path = source[source.index(after: colon)...]
            if host.contains(":"), !host.hasPrefix("[") {
                // URL 中的 IPv6 位址要加方括號，zone 的 % 要編碼成 %25
                if !host.contains("%25") { host = host.replacingOccurrences(of: "%", with: "%25") }
                host = "[\(host)]"
            }
            return URL(string: "nfs://\(host)\(path.hasPrefix("/") ? "" : "/")\(path)")
        case .webdav:
            return URL(string: source)
        }
    }

    private static func string<T>(from tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    // MARK: - 掛載

    /// - Parameter allowUI: 沒有密碼時讓系統跳出登入視窗
    func mount(url: URL, username: String?, password: String?, allowUI: Bool) async throws(NetworkMountError) {
        // NetFS.h 的 kNAUIOptionKey 等是 CFSTR 巨集，Swift 看不到，直接用字串值
        let openOptions = NSMutableDictionary()
        openOptions["UIOption"] = allowUI ? "AllowUI" : "NoUI"

        let shareKey = ShareKey(url)
        if let shareKey, isMounted(shareKey) { return }

        let request = MountRequest()
        let status: Int32 = await withCheckedContinuation { continuation in
            request.continuation = continuation
            var requestID: AsyncRequestID?
            let started = NetFSMountURLAsync(
                url as CFURL,
                nil,
                username as CFString?,
                password as CFString?,
                openOptions as CFMutableDictionary,
                nil,
                &requestID,
                .main
            ) { status, _, _ in
                MainActor.assumeIsolated { request.finish(status) }
            }
            // 啟動就失敗時不會呼叫 block
            guard started == 0 else {
                request.finish(started)
                return
            }
            request.requestID = requestID

            // 實測 NetFS 有時卷宗已經掛上，完成回呼卻遲遲不來（WebDAV 尤其明顯），
            // 所以同時輪詢掛載表；跳出登入視窗時使用者可能要輸入很久，逾時放寬
            let timeout: Duration = allowUI ? .seconds(300) : .seconds(60)
            Task { @MainActor [weak self] in
                let deadline = ContinuousClock.now + timeout
                while !request.isFinished, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .seconds(1))
                    if let shareKey, let self, self.isMounted(shareKey) {
                        request.finish(0, cancelRequest: true)
                    }
                }
                request.finish(ETIMEDOUT, cancelRequest: true)
            }
        }
        try Self.check(status)
        // WebDAV 的 didMountNotification 要等 mount_webdav 結束（實測 70–90 秒）才會來，
        // 掛載表裡已經有了就先通知，選單才不會一直顯示「連線」
        onChange?()
    }

    private func isMounted(_ key: ShareKey) -> Bool {
        mountedVolumes().contains { $0.serverURL.flatMap(ShareKey.init) == key }
    }

    /// 確保 continuation 只 resume 一次；提早結束時取消 NetFS 請求
    private final class MountRequest {
        var continuation: CheckedContinuation<Int32, Never>?
        var requestID: AsyncRequestID?
        private(set) var isFinished = false

        /// - Parameter cancelRequest: 不是由 NetFS 回呼結束時，取消還在進行的請求
        @MainActor
        func finish(_ status: Int32, cancelRequest: Bool = false) {
            guard !isFinished else { return }
            isFinished = true
            continuation?.resume(returning: status)
            continuation = nil
            if cancelRequest, let requestID {
                NetFSMountURLCancel(requestID)
            }
        }
    }

    private static func check(_ status: Int32) throws(NetworkMountError) {
        switch status {
        case 0, EEXIST:
            return
        case ECANCELED, -128 /* userCanceledErr */:
            throw .cancelled
        case EAUTH, ENEEDAUTH, EACCES, EPERM:
            throw .authenticationFailed
        case EHOSTUNREACH, EHOSTDOWN, ENETUNREACH, ETIMEDOUT, ECONNREFUSED, ENOTCONN:
            throw .unreachable
        case ENOENT:
            throw .shareNotFound
        default:
            throw .failed(status)
        }
    }
}
