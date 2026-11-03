import SwiftUI

/// A licence text bundled in the app's `Licenses` folder.
struct LicenseFile: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }

    static func bundled() -> [LicenseFile] {
        guard let dir = Bundle.main.url(forResource: "Licenses", withExtension: nil),
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return items
            .filter { ["txt", "md"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { LicenseFile(url: $0) }
    }
}

struct AboutView: View {
    @State private var licenses: [LicenseFile] = []

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private struct Credit: Identifiable {
        let id = UUID()
        let title: String
        let holder: String
        let license: String
        let detail: String
    }

    private let credits: [Credit] = [
        Credit(title: "SpektraLab", holder: "© JamesQiu2005", license: "GPL-3.0-or-later",
               detail: "光谱胶片模拟引擎"),
        Credit(title: "spektrafilm", holder: "Andrea Volpato", license: "CC BY-SA 4.0",
               detail: "胶片冲洗过程模型、28 款胶片档案与相纸 LUT"),
        Credit(title: "黑白与 CineStill 胶片档案", holder: "Hanze Qiu", license: "SpektraLab 产品数据",
               detail: "黑白胶片与 CineStill 800T 的特性数据"),
        Credit(title: "Film-Simulation", holder: "trouble123456", license: "GPL-3.0",
               detail: "Windows 版移植"),
        Credit(title: "metal-cpp", holder: "Apple Inc.", license: "Apache-2.0",
               detail: "Metal 的 C++ 接口"),
        Credit(title: "胶片机 FilmShooter", holder: "本应用", license: "GPL-3.0",
               detail: "iOS 界面、相机与暗房"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                hero
                    .padding(.top, 12)

                Text("基于 SpektraLab 光谱胶片引擎的非官方 iOS 移植。用光谱模型重现胶片的感光、显影与放大冲印，在手机上拍一卷真正的“胶卷”。")
                    .font(AppFont.ui(14))
                    .foregroundStyle(Theme.text.opacity(0.88))
                    .lineSpacing(5)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(Theme.accent)
                    Text("本应用为非官方作品，与 SpektraLab 及其作者没有任何隶属或合作关系，也未获其认可或背书。")
                        .font(AppFont.ui(12.5))
                        .foregroundStyle(Theme.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .surfaceCard(radius: 14, fill: Theme.accent.opacity(0.07))

                ControlSection(title: "致谢") {
                    ForEach(Array(credits.enumerated()), id: \.element.id) { index, credit in
                        if index > 0 {
                            Rectangle().fill(Theme.hairline).frame(height: 1)
                        }
                        creditRow(credit)
                    }
                }

                ControlSection(title: "开源许可") {
                    if licenses.isEmpty {
                        Text("未找到随附的许可文件")
                            .font(AppFont.ui(13))
                            .foregroundStyle(Theme.secondary)
                    } else {
                        ForEach(Array(licenses.enumerated()), id: \.element.id) { index, file in
                            if index > 0 {
                                Rectangle().fill(Theme.hairline).frame(height: 1)
                            }
                            NavigationLink {
                                LicenseTextView(file: file)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "doc.text")
                                        .font(.system(size: 14))
                                        .foregroundStyle(Theme.accent)
                                        .frame(width: 20)
                                    Text(file.name)
                                        .font(AppFont.ui(14, .medium))
                                        .foregroundStyle(Theme.text)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Theme.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.pressable(scale: 0.98))
                        }
                    }
                }

                Text("胶片名称与品牌归各自所有者所有，仅用于描述模拟的风格。")
                    .font(AppFont.ui(11))
                    .foregroundStyle(Theme.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .task { licenses = LicenseFile.bundled() }
    }

    private var hero: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Theme.accent.opacity(0.18), Theme.accent.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: 90))
                    .frame(width: 180, height: 180)
                VStack(spacing: 4) {
                    FilmCanister(film: FilmCatalog.film("kodak_portra_400"), height: 62)
                    CanisterShadow(width: 92)
                }
            }
            .frame(height: 120)
            Text("胶片机")
                .font(AppFont.ui(30, .semibold))
                .foregroundStyle(Theme.text)
            Text("FILMSHOOTER · \(Self.versionString)")
                .font(AppFont.mono(11, .medium))
                .tracking(2)
                .foregroundStyle(Theme.accent)
        }
    }

    private func creditRow(_ credit: Credit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(credit.title)
                    .font(AppFont.ui(14.5, .semibold))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                Text(credit.license)
                    .font(AppFont.mono(10, .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.accent.opacity(0.1)))
            }
            Text(credit.holder)
                .font(AppFont.ui(12.5, .medium))
                .foregroundStyle(Theme.text.opacity(0.75))
            Text(credit.detail)
                .font(AppFont.ui(12))
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A licence file as scrollable monospaced text (loaded off the main thread,
/// laid out lazily paragraph by paragraph).
struct LicenseTextView: View {
    let file: LicenseFile
    @State private var paragraphs: [String]?

    var body: some View {
        ScrollView {
            if let paragraphs {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.text.opacity(0.85))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
                .transition(.opacity)
            } else {
                ProgressView()
                    .tint(Theme.secondary)
                    .padding(.top, 80)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .animation(Motion.fade, value: paragraphs == nil)
        .task {
            let url = file.url
            let text = await Task.detached(priority: .userInitiated) { () -> String in
                (try? String(contentsOf: url, encoding: .utf8)) ?? "无法读取这个许可文件。"
            }.value
            paragraphs = text.components(separatedBy: "\n\n")
        }
    }
}
