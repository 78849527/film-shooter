import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var showAbout = false
    @State private var confirmRewind = false
    private let startAtAbout: Bool

    init(startAtAbout: Bool = false) {
        self.startAtAbout = startAtAbout
    }

    var body: some View {
        @Bindable var settings = model.settings
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    ControlSection(title: "输出") {
                        VStack(spacing: 14) {
                            ForEach(OutputQuality.allCases) { quality in
                                qualityRow(quality, selected: settings.outputQuality == quality) {
                                    settings.outputQuality = quality
                                }
                            }
                        }
                        divider
                        HStack {
                            Text("保存格式")
                                .font(AppFont.ui(15, .medium))
                                .foregroundStyle(Theme.text)
                            Spacer()
                            PillSegmented(options: PhotoDecoder.Format.allCases, selection: $settings.saveFormat,
                                          title: { $0.title })
                                .frame(width: 150)
                        }
                        divider
                        SettingToggle(title: "自动存入相册", subtitle: "冲洗完成后自动保存到系统相册",
                                      systemImage: "photo.on.rectangle", isOn: $settings.autoSaveToPhotos)
                        divider
                        SettingToggle(title: "保留原图", subtitle: "用于日后重新冲洗，会多占用一些空间",
                                      systemImage: "doc.on.doc", isOn: $settings.keepOriginals)
                    }

                    ControlSection(title: "取景器") {
                        SettingToggle(title: "取景网格", subtitle: "三分法构图线",
                                      systemImage: "square.grid.3x3", isOn: $settings.showGrid)
                        divider
                        SettingToggle(title: "取景器颗粒预览", subtitle: "在取景器里模拟胶片颗粒",
                                      systemImage: "circle.dotted", isOn: $settings.viewfinderGrain)
                    }

                    ControlSection(title: "胶卷") {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("胶卷长度")
                                    .font(AppFont.ui(15, .medium))
                                    .foregroundStyle(Theme.text)
                                Text("当前拍到第 \(model.frameNumber) 张")
                                    .font(AppFont.ui(12))
                                    .foregroundStyle(Theme.secondary)
                                    .contentTransition(.numericText(value: Double(model.frameNumber)))
                            }
                            Spacer()
                            PillSegmented(options: [24, 36], selection: $settings.rollLength,
                                          title: { "\($0) 张" })
                                .frame(width: 150)
                        }
                        divider
                        Button {
                            Haptics.tap()
                            confirmRewind = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "arrow.counterclockwise.circle")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 22)
                                Text("重新装片")
                                    .font(AppFont.ui(15, .medium))
                                    .foregroundStyle(Theme.text)
                                Spacer()
                                Text("计数归零")
                                    .font(AppFont.ui(12))
                                    .foregroundStyle(Theme.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable(scale: 0.98))
                    }

                    ControlSection(title: "通用") {
                        SettingToggle(title: "触感反馈", subtitle: "快门、过片和切换胶片时的振动",
                                      systemImage: "hand.tap", isOn: $settings.haptics)
                        divider
                        Button {
                            Haptics.tap()
                            showAbout = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 22)
                                Text("关于胶片机")
                                    .font(AppFont.ui(15, .medium))
                                    .foregroundStyle(Theme.text)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.tertiary)
                            }
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
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
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
            .navigationDestination(isPresented: $showAbout) {
                AboutView()
            }
        }
        .task {
            // Opened straight to About: push once the sheet has settled.
            guard startAtAbout, !showAbout else { return }
            try? await Task.sleep(nanoseconds: 600_000_000)
            showAbout = true
        }
        .tint(Theme.accent)
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.background)
        .presentationCornerRadius(28)
        .confirmationDialog("重新装片？", isPresented: $confirmRewind, titleVisibility: .visible) {
            Button("装上新胶卷") {
                model.rewindRoll()
                Haptics.filmAdvance()
                model.show("新胶卷已装好")
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("计数器归零，从第 1 张开始拍一卷新的 \(model.settings.rollLength) 张胶卷。")
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
    }

    private func qualityRow(_ quality: OutputQuality, selected: Bool, select: @escaping () -> Void) -> some View {
        Button {
            guard !selected else { return }
            Haptics.selection()
            withAnimation(Motion.snappy) { select() }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("画质 · \(quality.title)")
                            .font(AppFont.ui(15, .medium))
                            .foregroundStyle(Theme.text)
                        if quality == OutputQuality.recommended {
                            Text("推荐")
                                .font(AppFont.ui(10, .semibold))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.5), lineWidth: 0.8))
                        }
                    }
                    Text("\(quality.detail) · 长边 \(quality.longEdge) 像素")
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
