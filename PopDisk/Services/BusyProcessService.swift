import AppKit
import Darwin

/// 用 libproc 找出哪些程式正在使用指定的卷宗。
/// 只看得到目前使用者的程式；root 擁有的系統程式（例如 Spotlight）需要權限，看不到。
enum BusyProcessService {
    /// 掃描所有程式，回傳使用中的程式並對應到所屬的 App
    static func processes(using mountPaths: [String]) async -> [BusyProcess] {
        guard !mountPaths.isEmpty else { return [] }
        let found = await Task.detached(priority: .userInitiated) {
            scan(mountPaths: mountPaths)
        }.value
        return await MainActor.run {
            found.map { match in
                var process = BusyProcess(pid: match.pid, name: match.name)
                process.ownerApp = ownerApp(ancestors: match.ancestors)
                return process
            }
            .sorted { ($0.ownerApp?.name ?? $0.name).localizedStandardCompare($1.ownerApp?.name ?? $1.name) == .orderedAscending }
        }
    }

    // MARK: - libproc 掃描（背景執行緒）

    private struct Match: Sendable {
        let pid: pid_t
        let name: String
        /// 自己與所有上層程式的 pid，由近到遠
        let ancestors: [pid_t]
    }

    private static func scan(mountPaths: [String]) -> [Match] {
        // 以裝置編號比對，不受路徑寫法（symlink、相對路徑）影響
        let devices = Set(mountPaths.compactMap { path -> UInt32? in
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            return UInt32(bitPattern: info.st_dev)
        })
        let prefixes = mountPaths.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        let ownPID = getpid()

        return allPIDs().compactMap { pid in
            guard pid > 0, pid != ownPID,
                  usesDevice(pid: pid, devices: devices) || executable(of: pid).map({ path in
                      prefixes.contains { path.hasPrefix($0) }
                  }) == true else { return nil }
            return Match(pid: pid, name: name(of: pid), ancestors: ancestors(of: pid))
        }
    }

    private static func allPIDs() -> [pid_t] {
        let estimated = proc_listallpids(nil, 0)
        guard estimated > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimated) + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        return Array(pids.prefix(Int(max(count, 0))))
    }

    /// 開啟中的檔案或目前工作目錄位於指定裝置上
    private static func usesDevice(pid: pid_t, devices: Set<UInt32>) -> Bool {
        var paths = proc_vnodepathinfo()
        let pathsSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &paths, pathsSize) == pathsSize,
           devices.contains(paths.pvi_cdir.vip_vi.vi_stat.vst_dev) {
            return true
        }

        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return false }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bufferSize) / stride)
        let used = fds.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard used > 0 else { return false }

        let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            if proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, infoSize) == infoSize,
               devices.contains(info.pvip.vip_vi.vi_stat.vst_dev) {
                return true
            }
        }
        return false
    }

    private static func executable(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return string(from: buffer)
    }

    private static func name(of pid: pid_t) -> String {
        if let path = executable(of: pid) {
            return (path as NSString).lastPathComponent
        }
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, UInt32(buffer.count))
        return string(from: buffer)
    }

    private static func string(from buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func ancestors(of pid: pid_t) -> [pid_t] {
        var chain = [pid]
        var current = pid
        while chain.count < 32 {
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(current, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { break }
            let parent = pid_t(info.pbsi_ppid)
            guard parent > 1 else { break }
            chain.append(parent)
            current = parent
        }
        return chain
    }

    // MARK: - 對應到 App（主執行緒）

    @MainActor
    private static func ownerApp(ancestors: [pid_t]) -> BusyProcess.OwnerApp? {
        for pid in ancestors {
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular else { continue }
            return BusyProcess.OwnerApp(
                pid: pid,
                name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "",
                bundlePath: app.bundleURL?.path
            )
        }
        return nil
    }

    // MARK: - 結束程式

    /// App 用正常方式結束（會詢問是否儲存），其他程式送 SIGTERM。
    /// 回傳程式是否在期限內結束。
    @MainActor
    static func terminate(_ process: BusyProcess, timeout: Duration = .seconds(10)) async -> Bool {
        let isApp = process.isApp
        if isApp, let app = NSRunningApplication(processIdentifier: process.pid) {
            app.terminate()
        } else {
            kill(process.pid, SIGTERM)
        }
        let start = ContinuousClock.now
        var sentHangUp = false
        while ContinuousClock.now - start < timeout {
            // kill(pid, 0) 失敗代表程式已經不存在
            if kill(process.pid, 0) != 0 { return true }
            // 互動式 shell（例如終端機裡停在硬碟上的 zsh）會忽略 SIGTERM，改送關閉終端機視窗時的 SIGHUP
            if !isApp, !sentHangUp, ContinuousClock.now - start > .seconds(1) {
                kill(process.pid, SIGHUP)
                sentHangUp = true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }
}
