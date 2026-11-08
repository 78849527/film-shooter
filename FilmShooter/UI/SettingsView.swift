import SwiftUI

/// Routes inside the settings sheet.
enum SettingsRoute: Hashable {
    case about
    case license(LicenseFile)
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// The navigation path. Initialised with About when asked to open there,
    /// so the push is part of the first render -- no timing involved.
    @State private var path: [SettingsRoute]
    @State private var confirmRewind = false

    init(startAtAbout: Bool = false) {
        _path = State(initialValue: startAtAbout ? [.about] : [])
    }

    var body: some View {
        @ObservedObject var settings = model.settings
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 22) {
                    ControlSection(title: "画质", spacing: 14) {
                        ForEach(Array(OutputQuality.allCases.enumerated()), id: \.element.id) { index, quality in
                            if index > 0 { RowDivider() }
                            qualityRow(quality, selected: settings.outputQuality == quality) {
                                settings.outputQuality = quality
                            }
                        }
                    }

                    ControlSection(title: "保存", spacing: 14) {
                        HStack {
                            Text("保存格式")
                                .font(AppFont.ui(15, .medium))
                                .foregroundStyle(Theme.text)
                            Spacer()
                            PillSegmented(options: PhotoDecoder.Format.allCases, selection: $settings.saveFormat,
                                          title: { $0.title })
                                .frame(width: 150)
                        }
                        RowDivider()
                        SettingToggle(title: "自动存入相册", subtitle: "冲洗完成后自动保存到系统相册",
                                      systemImage: "photo.on.rectangle", isOn: $settings.autoSaveToPhotos)
                        RowDivider(inset: 34)
                        SettingToggle(title: "保留原图", subtitle: "用于日后重新冲洗，会多占用一些空间",
                                      systemImage: "doc.on.doc", isOn: $settings.keepOriginals)
                    }

                    ControlSection(title: "取景器", spacing: 14) {
                        SettingToggle(title: "取景网格", subtitle: "三分法构图线",
                                      systemImage: "square.grid.3x3", isOn: $settings.showGrid)
                        RowDivider(inset: 34)
                        SettingToggle(title: "取景器颗粒预览", subtitle: "在取景器里模拟胶片颗粒",
                                      systemImage: "circle.dotted", isOn: $settings.viewfinderGrain)
                    }

                    ControlSection(title: "胶卷", spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("胶卷长度")
                                    .font(AppFont.ui(15, .medium))
                                    .foregroundStyle(Theme.text)
                                Text("当前拍到第 \(String(model.frameNumber)) 张")
                                    .font(AppFont.ui(12))
                                    .foregroundStyle(Theme.secondary)
                                    .compatibleNumericText(Double(model.frameNumber))
                            }
                            Spacer()
                            PillSegmented(options: [24, 36], selection: $settings.rollLength,
                                          title: { "\($0) 张" })
                                .frame(width: 150)
                        }
                        RowDivider()
                        Button {
                            confirmRewind = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "arrow.counterclockwise.circle")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.secondary)
                                    .frame(width: 22)
                                Text("重新装片")
                                    .font(AppFont.ui(15, .medium))
                                    .foregroundStyle(Theme.text)
                                Spacer()
                                Text("计数归零")
                                    .font(AppFont.ui(12))
                                    .foregroundStyle(Theme.secondary)
                            }
                            .frame(minHeight: 32)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable(scale: 0.98))
                    }

                    ControlSection(title: "通用", spacing: 14) {
                        SettingToggle(title: "触感反馈", subtitle: "快门、过片和切换胶片时的振动",
                                      systemImage: "hand.tap", isOn: $settings.haptics)
                        RowDivider(inset: 34)
                        NavigationLink(value: SettingsRoute.about) {
                            HStack(spacing: 12) {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.secondary)
                                    .frame(width: 22)
                                Text("关于胶片机")
                                    .font(AppFont.ui(15, .medium))
                                    .foregroundStyle(Theme.text)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.tertiary)
                            }
                            .frame(minHeight: 32)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable(scale: 0.98))
                    }

                    Text("胶片机 \(AboutView.versionString) · 开源软件 · GPL-3.0")
                        .font(AppFont.ui(11))
                        .foregroundStyle(Theme.tertiary)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
            .background { SheetBackground() }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Text("完成")
                            .font(AppFont.ui(15, .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .about:
                    AboutView()
                case .license(let file):
                    LicenseTextView(file: file)
                }
            }
        }
        .onAppear {
            ScreenshotMode.log("settings appeared, path \(path.count)")
        }
        .compatibleOnChange(of: path) { old, new in
            ScreenshotMode.log("settings path \(old.count) -> \(new.count)")
        }
        .tint(Theme.accent)
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.clear)
        .presentationCornerRadius(28)
        .confirmationDialog("重新装片？", isPresented: $confirmRewind, titleVisibility: .visible) {
            Button("装上新胶卷") {
                model.rewindRoll()
                Haptics.filmAdvance()
                model.show("新胶卷已装好")
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("计数器归零，从第 1 张开始拍一卷新的 \(String(model.settings.rollLength)) 张胶卷。")
        }
    }

    private func qualityRow(_ quality: OutputQuality, selected: Bool, select: @escaping () -> Void) -> some View {
        Button {
            guard !selected else { return }
            Haptics.selection()
            withAnimation(Motion.snappy) { select() }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 0) {
                        Text(quality.title)
                            .font(AppFont.ui(15, .medium))
                            .foregroundStyle(Theme.text)
                        if quality == OutputQuality.recommended {
                            Text("（推荐）")
                                .font(AppFont.ui(15))
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                    Text("\(quality.detail) · 长边 \(String(quality.longEdge)) 像素")
                        .font(AppFont.ui(12))
                        .foregroundStyle(Theme.secondary)
                }
                Spacer()
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .opacity(selected ? 1 : 0)
                    .scaleEffect(selected ? 1 : 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.98))
    }
}
