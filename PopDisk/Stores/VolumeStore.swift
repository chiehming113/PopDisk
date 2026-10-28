import Foundation
import Observation

@Observable
@MainActor
final class VolumeStore {
    /// 退出成功後短暫顯示「可以安全拔除」的提示
    struct EjectedNotice: Identifiable {
        let id = UUID()
        let name: String
    }

    private(set) var drives: [ExternalDrive] = []
    private(set) var ejectStates: [ExternalDrive.ID: EjectState] = [:]
    private(set) var ejectedNotices: [EjectedNotice] = []
    private(set) var mountingVolumeIDs: Set<Volume.ID> = []
    /// 掛載失敗的訊息。與 ejectStates 分開：退出失敗的面板提供的是重試退出與強制退出，不適用於掛載
    private(set) var mountErrors: [Volume.ID: String] = [:]

    private let diskService: DiskArbitrationService

    /// 外接碟清單變動（舊清單、新清單）
    @ObservationIgnored var onDrivesChanged: (([ExternalDrive], [ExternalDrive]) -> Void)?
    /// 退出結束：nil 代表成功，否則為失敗狀態
    @ObservationIgnored var onEjectFinished: ((ExternalDrive, EjectState?) -> Void)?

    init(diskService: DiskArbitrationService) {
        self.diskService = diskService
        diskService.onChange = { [weak self] in self?.reload() }
        diskService.start()
    }

    func ejectState(for drive: ExternalDrive) -> EjectState {
        ejectStates[drive.id] ?? .idle
    }

    /// 重新讀取清單與容量（選單打開時呼叫，讓剩餘空間保持最新）
    func reload() {
        let previous = drives
        drives = diskService.drives()
        #if DEBUG
        if let names = SnapshotRenderer.volumeNames {
            drives = drives.filter { drive in drive.volumes.contains { names.contains($0.name) } }
        }
        #endif
        onDrivesChanged?(previous, drives)
        // 已經不存在的裝置不需要保留狀態
        let ids = Set(drives.map(\.id))
        ejectStates = ejectStates.filter { ids.contains($0.key) }
        let unmountedVolumeIDs = Set(drives.flatMap(\.volumes).filter { !$0.isMounted }.map(\.id))
        mountErrors = mountErrors.filter { unmountedVolumeIDs.contains($0.key) }
    }

    func eject(_ drive: ExternalDrive, force: Bool = false) async {
        guard ejectState(for: drive) != .ejecting else { return }
        ejectStates[drive.id] = .ejecting
        do {
            try await diskService.eject(driveID: drive.id, force: force)
            ejectStates[drive.id] = nil
            // 不等延遲合併的變動通知，退出後列表立刻更新
            reload()
            showEjectedNotice(name: drive.volumes.map(\.name).joined(separator: ", "))
            onEjectFinished?(drive, nil)
        } catch .busy {
            let mountPaths = drive.volumes.compactMap { $0.mountURL?.path }
            ejectStates[drive.id] = .busy(await BusyProcessService.processes(using: mountPaths))
            onEjectFinished?(drive, ejectStates[drive.id])
        } catch {
            ejectStates[drive.id] = .failed(error.localizedDescription)
            onEjectFinished?(drive, ejectStates[drive.id])
        }
    }

    /// 結束佔用的程式，等它結束後自動重試退出
    func terminate(_ process: BusyProcess, thenEject drive: ExternalDrive) async {
        ejectStates[drive.id] = .ejecting
        _ = await BusyProcessService.terminate(process)
        // 程式沒在時限內結束（例如還在詢問是否儲存）時，重試會再列出它
        ejectStates[drive.id] = nil
        await eject(drive)
    }

    /// - Parameter only: 只退出這些（例如選單上看得到的）；nil 代表全部
    func ejectAll(only ids: Set<ExternalDrive.ID>? = nil) async {
        for drive in drives where ids?.contains(drive.id) ?? true {
            await eject(drive)
        }
    }

    func mount(_ volume: Volume, on drive: ExternalDrive) async {
        mountingVolumeIDs.insert(volume.id)
        mountErrors[volume.id] = nil
        do {
            try await diskService.mount(volumeID: volume.id)
            ejectStates[drive.id] = nil
        } catch {
            mountErrors[volume.id] = error.localizedDescription
        }
        // DiskArbitration 的變動通知會延遲合併；這裡直接重新讀取，免得「裝載」按鈕在完成後又閃一下
        reload()
        mountingVolumeIDs.remove(volume.id)
    }

    private func showEjectedNotice(name: String) {
        let notice = EjectedNotice(name: name)
        ejectedNotices.append(notice)
        Task {
            try? await Task.sleep(for: .seconds(4))
            ejectedNotices.removeAll { $0.id == notice.id }
        }
    }
}
