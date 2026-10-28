import AppKit
import SwiftUI

struct AboutSettingsView: View {
    @Environment(UpdateStore.self) private var updates
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: "PopDisk")
                            .font(.title2.weight(.semibold))
                        Text("Eject and mount drives from the menu bar.")
                            .foregroundStyle(.secondary)
                        if let copyright = Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String {
                            Text(verbatim: copyright)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)

                LabeledContent("Version") {
                    HStack {
                        Text(verbatim: UpdateStore.versionDescription)
                            .textSelection(.enabled)
                        Button("Check for Updates…", action: updates.checkForUpdates)
                    }
                }
            }

            Section {
                Link("Website", destination: AppLinks.website)
                Link("What's New", destination: AppLinks.releaseNotes)
                Link("License on GitHub", destination: AppLinks.license)
                Link("Privacy", destination: AppLinks.privacy)
            }

            Section {
                Link("Report a Problem", destination: AppLinks.reportProblem)
                HStack {
                    Button("Copy System Info", action: copySystemInfo)
                    if copied {
                        Label("Copied", systemImage: "checkmark")
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                }
            } footer: {
                Text("When reporting a problem, paste the system info so it's easier to find the cause.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                FullTextDisclosure("License") {
                    if AppLinks.prefersChinese {
                        FullText(Self.licenseTranslation)
                        Text("This translation is for reference only. The English license below is the official version.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    FullText(Self.license)
                }
            } footer: {
                Text("PopDisk is open source under the MIT License.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                FullTextDisclosure("Acknowledgements") {
                    FullText(Self.acknowledgements)
                }
            } footer: {
                Text("PopDisk uses Sparkle for in-app updates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .animation(.default, value: copied)
    }

    /// 和 repo 根目錄的 LICENSE 相同（preflight.sh 會檢查）
    private static let license = bundledText("License")
    /// LICENSE.zh-Hant.md 的譯文段落（preflight.sh 會檢查）；只是參考，所以英文正式版本一定接在後面
    private static let licenseTranslation = bundledText("License.zh-Hant")
    private static let acknowledgements = bundledText("Acknowledgements")

    private static func bundledText(_ name: String) -> String {
        Bundle.main.url(forResource: name, withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    private func copySystemInfo() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SystemInfo.report, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// 內建的 DisclosureGroup 只有 > 符號點得到，標題文字也能點才好按
private struct FullTextDisclosure<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content
    @State private var isExpanded = false

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
        } label: {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation { isExpanded.toggle() }
                }
        }
    }
}

private struct FullText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(verbatim: text)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 回報問題時附上的環境資訊；不含硬碟名稱、伺服器位址等個人資料
enum SystemInfo {
    static var report: String {
        [
            "PopDisk \(UpdateStore.versionDescription)",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Mac: \(sysctlString("hw.model") ?? "?")",
            "Chip: \(sysctlString("machdep.cpu.brand_string") ?? "?")",
            "Language: \(Bundle.main.preferredLocalizations.first ?? "?") (\(Locale.preferredLanguages.first ?? "?"))",
        ].joined(separator: "\n")
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
