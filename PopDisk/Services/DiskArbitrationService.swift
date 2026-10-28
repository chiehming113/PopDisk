import DiskArbitration
import Foundation
import IOKit

enum DiskOperationError: LocalizedError, Sendable {
    case busy
    case failed(String?)

    var errorDescription: String? {
        switch self {
        case .busy:
            String(localized: "The disk is in use. Close any apps using it and try again.")
        case .failed(let detail?):
            detail
        case .failed(nil):
            String(localized: "The operation couldn't be completed.")
        }
    }
}

/// 包裝 DiskArbitration：追蹤外接卷宗的出現／消失／變更，並提供裝載與退出。
/// session 排在 main queue 上，所有 callback 都在主執行緒執行。
@MainActor
final class DiskArbitrationService {
    var onChange: (() -> Void)?

    private let session: DASession
    /// 目前追蹤中的卷宗，key 為 BSD 名稱
    private var volumeDisks: [String: DADisk] = [:]
    /// 接上一顆硬碟會連續收到數十個事件，合併成一次 onChange，避免反覆重建清單
    private var pendingChange: Task<Void, Never>?

    /// APFS 的系統輔助卷宗，不顯示給使用者
    private static let hiddenAPFSRoles: Set<String> = [
        "Preboot", "Recovery", "VM", "Update", "Hardware", "xART", "Baseband", "iSCPreboot",
    ]

    init() {
        session = DASessionCreate(kCFAllocatorDefault)!
    }

    func start() {
        DASessionSetDispatchQueue(session, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()

        DARegisterDiskAppearedCallback(session, nil, { disk, context in
            let service = Unmanaged<DiskArbitrationService>.fromOpaque(context!).takeUnretainedValue()
            MainActor.assumeIsolated { service.update(disk) }
        }, context)

        DARegisterDiskDescriptionChangedCallback(session, nil, nil, { disk, _, context in
            let service = Unmanaged<DiskArbitrationService>.fromOpaque(context!).takeUnretainedValue()
            MainActor.assumeIsolated { service.update(disk) }
        }, context)

        DARegisterDiskDisappearedCallback(session, nil, { disk, context in
            let service = Unmanaged<DiskArbitrationService>.fromOpaque(context!).takeUnretainedValue()
            MainActor.assumeIsolated { service.remove(disk) }
        }, context)
    }

    // MARK: - 查詢

    /// 依實體裝置分組後的外接硬碟清單
    func drives() -> [ExternalDrive] {
        var drivesByID: [String: ExternalDrive] = [:]
        for disk in volumeDisks.values {
            guard let physical = physicalWholeDisk(of: disk),
                  let physicalID = bsdName(of: physical) else { continue }
            let volume = makeVolume(from: disk)
            if drivesByID[physicalID] == nil {
                drivesByID[physicalID] = makeDrive(id: physicalID, from: physical)
            }
            drivesByID[physicalID]?.volumes.append(volume)
        }
        return drivesByID.values
            .map { drive in
                var drive = drive
                drive.volumes.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                return drive
            }
            .sorted { ($0.volumes.first?.name ?? $0.name).localizedStandardCompare($1.volumes.first?.name ?? $1.name) == .orderedAscending }
    }

    // MARK: - 動作

    func mount(volumeID: String) async throws(DiskOperationError) {
        guard let disk = volumeDisks[volumeID] else { throw .failed(nil) }
        let result = await perform { context in
            DADiskMount(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), Self.completion, context)
        }
        try result.check()
    }

    /// 卸載整顆實體裝置上的所有卷宗後退出裝置。
    /// force 會強制卸載使用中的卷宗，開著的檔案可能遺失未儲存的資料。
    func eject(driveID: String, force: Bool = false) async throws(DiskOperationError) {
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, driveID) else {
            throw .failed(nil)
        }
        // 整碟卸載實體碟不會連帶卸載 APFS 合成碟上的卷宗，要先逐一卸載這些 container
        let containerIDs = Set(volumeDisks.values.compactMap { volume -> String? in
            guard let physical = physicalWholeDisk(of: volume), bsdName(of: physical) == driveID,
                  let whole = DADiskCopyWholeDisk(volume), let wholeID = bsdName(of: whole),
                  wholeID != driveID else { return nil }
            return wholeID
        })
        for containerID in containerIDs.sorted() {
            guard let container = DADiskCreateFromBSDName(kCFAllocatorDefault, session, containerID) else { continue }
            try await unmountWhole(container, force: force)
        }
        try await unmountWhole(disk, force: force)
        let eject = await perform { context in
            DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), Self.completion, context)
        }
        try eject.check()
    }

    /// 卸載單一卷宗（網路卷宗用）。走 DiskArbitration 才能拿到與外接碟相同的 busy 判斷。
    func unmountVolume(at mountURL: URL, force: Bool = false) async throws(DiskOperationError) {
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, mountURL as CFURL) else {
            throw .failed(nil)
        }
        let options = force ? kDADiskUnmountOptionForce : kDADiskUnmountOptionDefault
        let result = await perform { context in
            DADiskUnmount(disk, DADiskUnmountOptions(options), Self.completion, context)
        }
        try result.check()
    }

    private func unmountWhole(_ disk: DADisk, force: Bool) async throws(DiskOperationError) {
        var options = kDADiskUnmountOptionWhole
        if force { options |= kDADiskUnmountOptionForce }
        let result = await perform { context in
            DADiskUnmount(disk, DADiskUnmountOptions(options), Self.completion, context)
        }
        try result.check()
    }

    // MARK: - DiskArbitration callback 轉 async

    private struct Result: Sendable {
        var status: DAReturn?
        var message: String?

        func check() throws(DiskOperationError) {
            guard let status else { return }
            var busyStatuses = [kDAReturnBusy, kDAReturnExclusiveAccess].map { DAReturn(truncatingIfNeeded: $0) }
            // umount 失敗時 DiskArbitration 回傳 unix_err(EBUSY)，也就是 0xC000 | errno
            busyStatuses.append(DAReturn(0xC000 | EBUSY))
            if busyStatuses.contains(status) { throw .busy }
            // 系統拒絕這個操作時 DiskArbitration 不附說明，換成使用者能照著做的替代方式
            if status == DAReturn(truncatingIfNeeded: kDAReturnNotPrivileged) {
                throw .failed(String(localized: "macOS doesn't allow PopDisk to do this with this disk. Remove and reinsert it, or use Disk Utility."))
            }
            // DiskArbitration 常常不附說明文字，附上狀態碼才查得到原因
            throw .failed(message ?? String(localized: "The operation couldn't be completed (error \(String(format: "0x%08X", UInt32(bitPattern: status))))."))
        }
    }

    private final class ResultBox {
        let continuation: CheckedContinuation<Result, Never>
        init(_ continuation: CheckedContinuation<Result, Never>) { self.continuation = continuation }
    }

    /// mount / unmount / eject 的 callback 簽章相同，共用同一個
    private static let completion: @convention(c) (DADisk, DADissenter?, UnsafeMutableRawPointer?) -> Void = { _, dissenter, context in
        let box = Unmanaged<ResultBox>.fromOpaque(context!).takeRetainedValue()
        guard let dissenter else {
            box.continuation.resume(returning: Result())
            return
        }
        let message = DADissenterGetStatusString(dissenter) as String?
        box.continuation.resume(returning: Result(status: DADissenterGetStatus(dissenter), message: message))
    }

    private func perform(_ operation: (UnsafeMutableRawPointer) -> Void) async -> Result {
        await withCheckedContinuation { continuation in
            operation(Unmanaged.passRetained(ResultBox(continuation)).toOpaque())
        }
    }

    // MARK: - 追蹤

    private func update(_ disk: DADisk) {
        guard let id = bsdName(of: disk) else { return }
        if isVisibleExternalVolume(disk) {
            volumeDisks[id] = disk
        } else {
            // 內接碟、整碟、系統輔助卷宗的事件與清單無關
            guard volumeDisks.removeValue(forKey: id) != nil else { return }
        }
        scheduleChange()
    }

    private func remove(_ disk: DADisk) {
        guard let id = bsdName(of: disk), volumeDisks.removeValue(forKey: id) != nil else { return }
        scheduleChange()
    }

    /// volumeDisks 已即時更新（mount／eject 直接讀它），只有通知延後；
    /// 期間的事件不再往後延，最多晚 0.2 秒
    private func scheduleChange() {
        guard pendingChange == nil else { return }
        pendingChange = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            self?.pendingChange = nil
            self?.onChange?()
        }
    }

    private func isVisibleExternalVolume(_ disk: DADisk) -> Bool {
        let info = description(of: disk)
        guard info[kDADiskDescriptionVolumeKindKey as String] != nil,
              info[kDADiskDescriptionVolumeNetworkKey as String] as? Bool != true,
              info[kDADiskDescriptionVolumeMountableKey as String] as? Bool != false else { return false }

        // APFS 合成碟本身不帶 DeviceInternal，要看背後的實體裝置；磁碟映像檔則完全沒有這個 key
        guard let physical = physicalWholeDisk(of: disk) else { return false }
        let physicalInfo = description(of: physical)
        // 內建讀卡機的 SD 卡是內部裝置，但媒體可移除，比照 Finder 當成外接碟
        let isRemovableMedia = physicalInfo[kDADiskDescriptionMediaRemovableKey as String] as? Bool == true
            || physicalInfo[kDADiskDescriptionMediaEjectableKey as String] as? Bool == true
        guard physicalInfo[kDADiskDescriptionDeviceInternalKey as String] as? Bool != true || isRemovableMedia else { return false }

        if let roles = mediaProperty(of: disk, key: "Role") as? [String],
           !Self.hiddenAPFSRoles.isDisjoint(with: roles) {
            return false
        }

        // 比照 Finder：nobrowse 掛載的（例如 Xcode 模擬器 runtime）不顯示
        if let url = info[kDADiskDescriptionVolumePathKey as String] as? URL {
            var stats = statfs()
            if statfs(url.path, &stats) == 0, stats.f_flags & UInt32(MNT_DONTBROWSE) != 0 {
                return false
            }
        }
        return true
    }

    // MARK: - 建立模型

    private func makeVolume(from disk: DADisk) -> Volume {
        let info = description(of: disk)
        let id = bsdName(of: disk) ?? ""
        let mountURL = info[kDADiskDescriptionVolumePathKey as String] as? URL
        var volume = Volume(
            id: id,
            name: info[kDADiskDescriptionVolumeNameKey as String] as? String ?? id,
            mountURL: mountURL,
            fileSystem: info[kDADiskDescriptionVolumeKindKey as String] as? String
        )
        if let uuid = info[kDADiskDescriptionVolumeUUIDKey as String] {
            // CFUUID 不能直接 as? 轉型，用 CFGetTypeID 確認
            let cfValue = uuid as CFTypeRef
            if CFGetTypeID(cfValue) == CFUUIDGetTypeID() {
                volume.uuid = CFUUIDCreateString(kCFAllocatorDefault, (cfValue as! CFUUID)) as String
            }
        }
        if let mountURL,
           let values = try? mountURL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]) {
            volume.totalBytes = values.volumeTotalCapacity.map(Int64.init)
            volume.availableBytes = values.volumeAvailableCapacity.map(Int64.init)
        } else {
            volume.totalBytes = (info[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value
        }
        return volume
    }

    private func makeDrive(id: String, from physical: DADisk) -> ExternalDrive {
        let info = description(of: physical)
        let model = (info[kDADiskDescriptionDeviceModelKey as String] as? String)?
            .trimmingCharacters(in: .whitespaces)
        let isImage = model == "Disk Image"
            || (info[kDADiskDescriptionDeviceProtocolKey as String] as? String) == "Disk Image"
        let name = [info[kDADiskDescriptionDeviceVendorKey as String] as? String, model]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let media = DADiskCopyIOMedia(physical)
        defer { if media != 0 { IOObjectRelease(media) } }
        return ExternalDrive(
            id: id,
            name: name.isEmpty ? (info[kDADiskDescriptionMediaNameKey as String] as? String ?? id) : name,
            kind: isImage ? .diskImage : .disk,
            volumes: [],
            link: isImage || media == 0 ? nil : LinkSpeedService.externalLink(media: media),
            serialNumber: media == 0 ? nil : LinkSpeedService.serialNumber(media: media),
            partitionUUID: media == 0 ? nil : Self.partitionUUIDs(of: media).min()
        )
    }

    /// 整碟分割表裡各分割區的 GUID。分割區在磁碟讀取時就全部出現，不像卷宗是一個一個掛上，
    /// 所以適合當個人設定的 key。只往下找兩層（整碟 → 分割表 → 分割區），
    /// 再往下是 APFS 合成的容器與卷宗，它們較晚出現，會讓 key 變動。
    private static func partitionUUIDs(of wholeMedia: io_object_t) -> [String] {
        var uuids: [String] = []
        for scheme in children(of: wholeMedia) {
            for partition in children(of: scheme) {
                if IOObjectConformsTo(partition, "IOMedia") != 0,
                   let uuid = IORegistryEntryCreateCFProperty(partition, "UUID" as CFString, kCFAllocatorDefault, 0)?
                       .takeRetainedValue() as? String {
                    uuids.append(uuid)
                }
                IOObjectRelease(partition)
            }
            IOObjectRelease(scheme)
        }
        return uuids
    }

    /// 呼叫端負責 release 回傳的每個物件
    private static func children(of entry: io_registry_entry_t) -> [io_registry_entry_t] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [io_registry_entry_t] = []
        while case let child = IOIteratorNext(iterator), child != 0 {
            result.append(child)
        }
        return result
    }

    // MARK: - 工具

    private func description(of disk: DADisk) -> [String: Any] {
        DADiskCopyDescription(disk) as? [String: Any] ?? [:]
    }

    private func bsdName(of disk: DADisk) -> String? {
        DADiskGetBSDName(disk).map { String(cString: $0) }
    }

    private func mediaProperty(of disk: DADisk, key: String) -> Any? {
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }
        return IORegistryEntryCreateCFProperty(media, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// 找出卷宗所在的實體整碟。APFS 卷宗的整碟是合成碟（例如 disk5），
    /// 要沿 IORegistry 往上找到 Physical Store 所在的整碟（例如 disk4）才是能退出的裝置。
    private func physicalWholeDisk(of disk: DADisk) -> DADisk? {
        guard let whole = DADiskCopyWholeDisk(disk) else { return nil }
        var entry = DADiskCopyIOMedia(whole)
        guard entry != 0 else { return whole }
        defer { IOObjectRelease(entry) }

        var parent: io_registry_entry_t = 0
        while IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS {
            IOObjectRelease(entry)
            entry = parent
            guard IOObjectConformsTo(entry, "IOMedia") != 0,
                  IORegistryEntryCreateCFProperty(entry, "Whole" as CFString, kCFAllocatorDefault, 0)?
                      .takeRetainedValue() as? Bool == true,
                  let name = IORegistryEntryCreateCFProperty(entry, "BSD Name" as CFString, kCFAllocatorDefault, 0)?
                      .takeRetainedValue() as? String else { continue }
            return DADiskCreateFromBSDName(kCFAllocatorDefault, session, name) ?? whole
        }
        return whole
    }
}
