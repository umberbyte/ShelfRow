//
//  PreferencesView.swift
//  ShelfRow
//
//  Created by Go Sugawara on 2026/09/16.
//

import SwiftUI
import UniformTypeIdentifiers

enum MaintenanceAction: String {
    case manageVolumes
    case importXMLLibrary
    case migrateLegacyThumbnails
    case repairThumbnails
    case repairEmptyTitles
}

extension Notification.Name {
    static let maintenanceActionRequested = Notification.Name("ShelfRowMaintenanceActionRequested")
    static let keywordEquivalenceEditRequested = Notification.Name("ShelfRowKeywordEquivalenceEditRequested")
}

enum KeywordEquivalenceEditRequest {
    static let fieldKey = "pendingKeywordEquivalenceField"
    static let termKey = "pendingKeywordEquivalenceTerm"

    static func store(field: KeywordEquivalenceField, term: String) {
        UserDefaults.standard.set(field.rawValue, forKey: fieldKey)
        UserDefaults.standard.set(term, forKey: termKey)
    }

    static func consume() -> (field: KeywordEquivalenceField, term: String)? {
        let defaults = UserDefaults.standard
        guard let rawField = defaults.string(forKey: fieldKey),
              let field = KeywordEquivalenceField(rawValue: rawField),
              let term = defaults.string(forKey: termKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !term.isEmpty else {
            return nil
        }
        defaults.removeObject(forKey: fieldKey)
        defaults.removeObject(forKey: termKey)
        return (field, term)
    }

    static var hasPendingRequest: Bool {
        UserDefaults.standard.string(forKey: fieldKey) != nil
    }
}

enum PreferencesLayout {
    static let windowWidth: CGFloat = 860
    static let windowHeight: CGFloat = 600
    static let labelWidth: CGFloat = 190
    static let bodyFont = Font.system(size: 13)
    static let captionFont = Font.system(size: 13)
    static let smallCaptionFont = Font.system(size: 12)
    static let sectionTitleFont = Font.system(size: 15, weight: .semibold)
}

enum PreferencesPane: String, CaseIterable, Identifiable {
    case general
    case viewer
    case helper
    case keywords
    case customize
    case icloud
    case security
    case maintenance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "一般"
        case .viewer: return "ビューア"
        case .helper: return "ヘルパー"
        case .keywords: return "キーワード"
        case .customize: return "カスタマイズ"
        case .icloud: return "iCloud"
        case .security: return "セキュリティ"
        case .maintenance: return "保守"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .viewer: return "play.rectangle"
        case .helper: return "square.and.arrow.up"
        case .keywords: return "tag"
        case .customize: return "slider.horizontal.3"
        case .icloud: return "icloud"
        case .security: return "lock"
        case .maintenance: return "wrench.and.screwdriver"
        }
    }
}

struct PreferencesView: View {
    @State private var selectedPane: PreferencesPane? = .general

    var body: some View {
        NavigationSplitView {
            List(PreferencesPane.allCases, selection: $selectedPane) { pane in
                Label(pane.title, systemImage: pane.systemImage)
                    .font(PreferencesLayout.bodyFont)
                    .tag(pane)
            }
            .listStyle(.sidebar)
            .navigationTitle("設定")
            .frame(minWidth: 180, idealWidth: 190)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    preferencesDetail(for: selectedPane ?? .general)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .navigationTitle((selectedPane ?? .general).title)
        }
        .frame(width: PreferencesLayout.windowWidth, height: PreferencesLayout.windowHeight)
        .onAppear {
            if KeywordEquivalenceEditRequest.hasPendingRequest {
                selectedPane = .keywords
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .keywordEquivalenceEditRequested)) { _ in
            selectedPane = .keywords
        }
    }


    @ViewBuilder
    private func preferencesDetail(for pane: PreferencesPane) -> some View {
        switch pane {
        case .general:
            GeneralSettingsView()
        case .viewer:
            SlideshowSettingsView()
        case .helper:
            HelperSettingsView()
        case .keywords:
            KeywordEquivalenceSettingsView()
        case .customize:
            CustomizeSettingsView()
        case .icloud:
            CloudSyncSettingsView()
        case .security:
            SecuritySettingsView()
        case .maintenance:
            MaintenanceSettingsView()
        }
    }
}

// MARK: - Shared right-aligned label row (classic Stackroom form layout)
private struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(label)
                .font(PreferencesLayout.bodyFont)
                .frame(width: PreferencesLayout.labelWidth, alignment: .trailing)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
    }
}

private struct PreferencesSectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .font(PreferencesLayout.captionFont)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PreferencesPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor).opacity(0.55), lineWidth: 1)
        )
    }
}

private struct PreferencesSettingRow<Control: View>: View {
    let icon: String
    let title: String
    let description: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.accentColor.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(description)
                    .font(PreferencesLayout.smallCaptionFont)
                    .foregroundColor(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }
}

private struct PreferencesDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 48)
    }
}

// MARK: - 1. Slideshow Tab
struct SlideshowSettingsView: View {
    @AppStorage("slideshowHelperPath") private var slideshowHelperName = ""
    @AppStorage("slideshowHelperFullPath") private var slideshowHelperFullPath = ""

    @AppStorage("zipHelperPath") private var zipHelperName = ""
    @AppStorage("zipHelperFullPath") private var zipHelperFullPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PreferencesSectionHeader(
                title: "ビューア",
                subtitle: "画像フォルダやアーカイブを開く外部ビューアを設定します。"
            )

            PreferencesPanel {
                PreferencesSettingRow(
                    icon: "play.rectangle",
                    title: "スライドショーヘルパー",
                    description: slideshowHelperName.trimmingCharacters(in: .whitespaces).isEmpty
                        ? "画像フォルダを開くための外部ビューアを設定してください。"
                        : "画像フォルダのドラッグ&ドロップに対応したビューアを指定します。"
                ) {
                    helperField(name: $slideshowHelperName, fullPath: $slideshowHelperFullPath)
                }

                PreferencesDivider()

                PreferencesSettingRow(
                    icon: "doc.zipper",
                    title: "Zip アーカイブヘルパー",
                    description: zipHelperName.trimmingCharacters(in: .whitespaces).isEmpty
                        ? "Zip アーカイブを開くための外部ビューアを設定してください。"
                        : "Zip アーカイブの閲覧に対応したビューアを指定します。"
                ) {
                    helperField(name: $zipHelperName, fullPath: $zipHelperFullPath)
                }
            }

            Spacer()
        }
    }

    private func helperField(name: Binding<String>, fullPath: Binding<String>) -> some View {
        let appName = name.wrappedValue.trimmingCharacters(in: .whitespaces)
        return HStack(spacing: 8) {
            // Display-only label of the chosen app (editing the name is meaningless)
            HStack(spacing: 6) {
                Image(systemName: "app.dashed")
                    .foregroundColor(.secondary)
                Text(appName.isEmpty ? "(未設定)" : appName)
                    .font(PreferencesLayout.bodyFont)
                    .foregroundColor(appName.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(NSColor.controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.gray.opacity(0.3)))

            Button("選択...") {
                selectApp(name: name, fullPath: fullPath)
            }
            .controlSize(.large)

            if !appName.isEmpty {
                Button("解除") {
                    name.wrappedValue = ""
                    fullPath.wrappedValue = ""
                }
                .controlSize(.large)
            }
        }
    }

    private func selectApp(name: Binding<String>, fullPath: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.title = "ヘルパーアプリケーションを選択"

        if panel.runModal() == .OK, let url = panel.url {
            name.wrappedValue = url.deletingPathExtension().lastPathComponent
            fullPath.wrappedValue = url.path
        }
    }
}

// MARK: - 2. Helper Tab
struct HelperSettingsView: View {
    @AppStorage("helperExtensionsList") private var extensionList = "mov, avi, mpg\nrar, zip, 7z"
    @AppStorage("helperApplicationsList") private var applicationList = "\n"

    @State private var extensions: [String] = ["mov, avi, mpg", "rar"]
    @State private var helpers: [String] = ["", ""]
    @State private var selectedIndex: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PreferencesSectionHeader(
                title: "ヘルパー",
                subtitle: "拡張子ごとに起動するアプリケーションを設定します。rar / zip / 7z はページ数で種類を判定し、それ以外はムービーとして登録します。"
            )

            PreferencesPanel {
                HStack(alignment: .top, spacing: 18) {
                    // Extensions Column (with its own +/- buttons, like the original)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("拡張子 (コンマ区切り)")
                            .font(PreferencesLayout.bodyFont)
                            .fontWeight(.bold)
                        List(selection: $selectedIndex) {
                            ForEach(0..<extensions.count, id: \.self) { idx in
                                TextField("", text: Binding(
                                    get: { extensions[idx] },
                                    set: { extensions[idx] = $0; saveLists() }
                                ))
                                .textFieldStyle(.plain)
                                .font(PreferencesLayout.bodyFont)
                                .accessibilityLabel("拡張子 \(idx + 1)")
                                .tag(idx)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor).opacity(0.7)))

                        HStack(spacing: 4) {
                            Button(action: addMapping) {
                                Image(systemName: "plus.circle.fill")
                            }
                            .accessibilityLabel("ヘルパー設定を追加")
                            Button(action: removeMapping) {
                                Image(systemName: "minus")
                            }
                            .accessibilityLabel("選択中のヘルパー設定を削除")
                            .disabled(selectedIndex == nil)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }
                    .frame(maxWidth: .infinity)

                    // Helpers Column (with its own +/- buttons)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ヘルパーアプリケーション")
                            .font(PreferencesLayout.bodyFont)
                            .fontWeight(.bold)
                        List {
                            ForEach(0..<helpers.count, id: \.self) { idx in
                                HStack {
                                    TextField("", text: Binding(
                                        get: { helpers[idx] },
                                        set: { helpers[idx] = $0; saveLists() }
                                    ))
                                    .textFieldStyle(.plain)
                                    .font(PreferencesLayout.bodyFont)
                                    .accessibilityLabel("ヘルパーアプリケーション \(idx + 1)")
                                    Button("選択...") {
                                        selectHelper(at: idx)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor).opacity(0.7)))

                        HStack(spacing: 4) {
                            Button(action: addMapping) {
                                Image(systemName: "plus.circle.fill")
                            }
                            .accessibilityLabel("ヘルパー設定を追加")
                            Button(action: removeMapping) {
                                Image(systemName: "minus")
                            }
                            .accessibilityLabel("選択中のヘルパー設定を削除")
                            .disabled(selectedIndex == nil)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(14)
            }

            Spacer()
        }
        .onAppear {
            loadLists()
        }
    }

    private func loadLists() {
        let exts = extensionList.components(separatedBy: "\n").filter { !$0.isEmpty }
        let apps = applicationList.components(separatedBy: "\n")

        self.extensions = exts.isEmpty ? ["mov, avi, mpg", "rar, zip, 7z"] : exts
        self.helpers = Array(repeating: "", count: self.extensions.count)
        for i in 0..<min(apps.count, self.extensions.count) {
            self.helpers[i] = apps[i]
        }
        saveLists()
    }

    private func saveLists() {
        extensionList = extensions.joined(separator: "\n")
        applicationList = helpers.joined(separator: "\n")
    }

    private func addMapping() {
        extensions.append("new_ext")
        helpers.append("")
        saveLists()
    }

    private func removeMapping() {
        if let idx = selectedIndex, idx < extensions.count {
            extensions.remove(at: idx)
            helpers.remove(at: idx)
            selectedIndex = nil
            saveLists()
        }
    }

    private func selectHelper(at idx: Int) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.title = "ヘルパーアプリケーションを選択"

        if panel.runModal() == .OK, let url = panel.url {
            helpers[idx] = url.path
            saveLists()
        }
    }
}

// MARK: - 3. Keyword Equivalence Tab
struct KeywordEquivalenceSettingsView: View {
    @AppStorage("keywordEquivalenceRulesJson") private var rulesJson = "[]"
    @State private var rules: [KeywordEquivalenceRule] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PreferencesSectionHeader(
                title: "キーワード",
                subtitle: "作者名・ジャンル・キーワードなどをグループ化し、検索時に同じものとして扱います。"
            )

            PreferencesPanel {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text("種類")
                            .frame(width: 130, alignment: .leading)
                        Text("同一視するキーワード")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("")
                            .frame(width: 34)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(NSColor.controlBackgroundColor))

                    Divider()

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rules) { rule in
                                keywordRuleRow(ruleID: rule.id)
                                Divider()
                            }
                        }
                    }
                    .frame(minHeight: 260)
                }
            }

            HStack(spacing: 8) {
                Button {
                    addRule()
                } label: {
                    Label("追加", systemImage: "plus")
                }
                .controlSize(.large)

                Spacer()
            }

            Text("例: 種類を「作者」、キーワードを「Lorem ipsum, Dolor sit, Amet」にすると、検索欄でどれを検索しても同じグループの作者名を持つ項目がヒットします。")
                .font(PreferencesLayout.smallCaptionFont)
                .foregroundColor(.secondary)
                .lineSpacing(2)

            Spacer()
        }
        .onAppear {
            rules = KeywordEquivalenceCodec.decode(rulesJson)
            consumePendingEditRequest()
        }
        .onReceive(NotificationCenter.default.publisher(for: .keywordEquivalenceEditRequested)) { _ in
            consumePendingEditRequest()
        }
    }

    private func keywordRuleRow(ruleID: UUID) -> some View {
        HStack(spacing: 12) {
            Picker("", selection: fieldBinding(for: ruleID)) {
                ForEach(KeywordEquivalenceField.allCases) { field in
                    Text(field.label).tag(field)
                }
            }
            .accessibilityLabel("キーワードの種類")
            .labelsHidden()
            .frame(width: 130)

            TextField("例: Lorem ipsum, Dolor sit, Amet", text: termsBinding(for: ruleID))
            .textFieldStyle(.plain)
            .font(PreferencesLayout.bodyFont)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(NSColor.textBackgroundColor).opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(NSColor.separatorColor).opacity(0.55), lineWidth: 1)
            )

            Button {
                deleteRule(id: ruleID)
            } label: {
                Image(systemName: "minus")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("キーワードルールを削除")
            .help("削除")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func fieldBinding(for ruleID: UUID) -> Binding<KeywordEquivalenceField> {
        Binding(
            get: {
                rules.first(where: { $0.id == ruleID })?.field ?? .keywordA
            },
            set: { newValue in
                guard let index = rules.firstIndex(where: { $0.id == ruleID }) else { return }
                rules[index].field = newValue
                saveRules()
            }
        )
    }

    private func termsBinding(for ruleID: UUID) -> Binding<String> {
        Binding(
            get: {
                guard let rule = rules.first(where: { $0.id == ruleID }) else { return "" }
                return KeywordEquivalenceCodec.termsText(rule.terms)
            },
            set: { newValue in
                guard let index = rules.firstIndex(where: { $0.id == ruleID }) else { return }
                rules[index].terms = KeywordEquivalenceCodec.terms(from: newValue)
                saveRules()
            }
        )
    }

    private func deleteRule(id: UUID) {
        rules.removeAll { $0.id == id }
        saveRules()
    }

    private func addRule() {
        rules.append(KeywordEquivalenceRule(field: .keywordA, terms: []))
        saveRules()
    }

    private func consumePendingEditRequest() {
        guard let request = KeywordEquivalenceEditRequest.consume() else { return }
        rules = KeywordEquivalenceCodec.decode(rulesJson)
        let normalizedTerm = KeywordEquivalenceCodec.normalize(request.term)
        if let index = rules.firstIndex(where: { rule in
            rule.field == request.field && rule.terms.contains { KeywordEquivalenceCodec.normalize($0) == normalizedTerm }
        }) {
            let rule = rules.remove(at: index)
            rules.insert(rule, at: 0)
        } else {
            rules.insert(KeywordEquivalenceRule(field: request.field, terms: [request.term]), at: 0)
        }
        saveRules()
    }

    private func saveRules() {
        rulesJson = KeywordEquivalenceCodec.encode(rules)
    }
}

// MARK: - 3. Customize Tab
struct CustomizeSettingsView: View {
    @AppStorage("customRenameFormat") private var renameFormat = "[@author] @title"

    // Type Customizable Names (empty = use the classic default shown as placeholder)
    @AppStorage("typeNameThickBook") private var thickBook = ""
    @AppStorage("typeNameThinBook") private var thinBook = ""
    @AppStorage("typeNamePartBook") private var partBook = ""
    @AppStorage("typeNameImageSet") private var imageSet = ""
    @AppStorage("typeNameText") private var textType = ""
    @AppStorage("typeNameMovie") private var movieType = ""

    // Field Customizable Names
    @AppStorage("fieldNameAuthor") private var fieldAuthor = ""
    @AppStorage("fieldNameGenre") private var fieldGenre = ""
    @AppStorage("fieldNameRelation") private var fieldRelation = ""
    @AppStorage("fieldNameKeywordA") private var fieldKeywordA = ""
    @AppStorage("fieldNameKeywordB") private var fieldKeywordB = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PreferencesSectionHeader(
                title: "カスタマイズ",
                subtitle: "ファイル名の解析ルールと、種類・項目名の表示を調整します。"
            )

            PreferencesPanel {
                VStack(alignment: .leading, spacing: 8) {
                Text("フォーマットのカスタマイズ:")
                    .font(PreferencesLayout.sectionTitleFont)
                    .frame(maxWidth: .infinity, alignment: .leading)

                customizeTextField("例: [@author(@keywordA)] @title", text: $renameFormat, width: nil, monospaced: true)

                Text("ドラッグ&ドロップ登録やタイトル補完時に、ファイル名から各項目へ値を振り分けます。区切り文字や空白は入力した書式に従います。")
                    .font(PreferencesLayout.captionFont)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("プレースホルダ:\n作者 @author  タイトル @title  キーワードA @keywordA  キーワードB @keywordB\n関連 @relation  ジャンル @genre  種類 @type")
                    .font(PreferencesLayout.smallCaptionFont)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
                .padding(14)
            }

            PreferencesPanel {
                HStack(alignment: .top, spacing: 34) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("種類のカスタマイズ:")
                            .font(PreferencesLayout.sectionTitleFont)

                        customTypeRow(typeIndex: 0, placeholder: "厚い本", text: $thickBook)
                        customTypeRow(typeIndex: 1, placeholder: "薄い本", text: $thinBook)
                        customTypeRow(typeIndex: 2, placeholder: "本の一部", text: $partBook)
                        customTypeRow(typeIndex: 3, placeholder: "画像セット", text: $imageSet)
                        customTypeRow(typeIndex: 4, placeholder: "テキスト", text: $textType)
                        customTypeRow(typeIndex: 5, placeholder: "ムービー", text: $movieType)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("項目のカスタマイズ:")
                            .font(PreferencesLayout.sectionTitleFont)

                        customFieldRow(placeholder: "作者", text: $fieldAuthor)
                        customFieldRow(placeholder: "ジャンル", text: $fieldGenre)
                        customFieldRow(placeholder: "関連", text: $fieldRelation)
                        customFieldRow(placeholder: "キーワードA", text: $fieldKeywordA)
                        customFieldRow(placeholder: "キーワードB", text: $fieldKeywordB)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
            }

            Spacer()
        }
    }

    private func customTypeRow(typeIndex: Int, placeholder: String, text: Binding<String>) -> some View {
        HStack {
            Image(systemName: BookTypeInfo.systemImage(for: typeIndex))
                .foregroundColor(BookTypeInfo.color(for: typeIndex))
                .frame(width: 26)
            customizeTextField(placeholder, text: text, width: nil)
        }
    }

    private func customFieldRow(placeholder: String, text: Binding<String>) -> some View {
        customizeTextField(placeholder, text: text, width: nil)
    }

    private func customizeTextField(_ placeholder: String, text: Binding<String>, width: CGFloat?, monospaced: Bool = false) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(monospaced ? .system(size: 13, design: .monospaced) : PreferencesLayout.bodyFont)
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(width: width)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(NSColor.textBackgroundColor).opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(NSColor.separatorColor).opacity(0.8), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 1, x: 0, y: 1)
    }
}

// MARK: - 4. General Pane
struct GeneralSettingsView: View {
    @AppStorage("appearanceMode") private var appearanceModeRaw = AppAppearanceMode.system.rawValue
    @AppStorage("advancedCloseOnExit") private var closeOnExit = true
    @AppStorage("compactDisplay") private var compactDisplay = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PreferencesSectionHeader(
                title: "一般",
                subtitle: "表示とアプリの基本動作を設定します。"
            )

            PreferencesPanel {
                PreferencesSettingRow(
                    icon: "circle.lefthalf.filled",
                    title: "外観",
                    description: "macOSのライト/ダークモードに合わせるか、固定の外観を使います。"
                ) {
                    Picker("", selection: $appearanceModeRaw) {
                        ForEach(AppAppearanceMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                }

                PreferencesDivider()

                PreferencesSettingRow(
                    icon: "arrow.down.right.and.arrow.up.left",
                    title: "表示を縮小",
                    description: "左右のペインとツールバーを75%に縮め、行間や余白はそれ以上に詰めます。画面の狭いMacで本の一覧に幅と高さを回すための表示です。"
                ) {
                    Toggle("縮小表示", isOn: $compactDisplay)
                        .font(PreferencesLayout.bodyFont)
                        .toggleStyle(.switch)
                }

                PreferencesDivider()

                PreferencesSettingRow(
                    icon: "xmark.circle",
                    title: "終了動作",
                    description: "メインウインドウを閉じた時にShelfRowを終了します。"
                ) {
                    Toggle("閉じると終了", isOn: $closeOnExit)
                        .font(PreferencesLayout.bodyFont)
                        .toggleStyle(.switch)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 5. Security Pane
struct CloudSyncSettingsView: View {
    @Environment(LibraryStore.self) private var libraryStore
    @Environment(CloudAccountMonitor.self) private var cloudAccount

    /// Nothing merges two libraries, so turning sync on has to be told which
    /// copy survives: this device's, or the one iCloud already holds.
    @State private var isAskingWhichLibraryWins = false
    @State private var isConfirmingDisable = false
    @State private var isConfirmingPurge = false
    @State private var isConfirmingResend = false

    /// The switch says what the user wants; the mode says what the library is
    /// actually doing. They differ whenever iCloud is signed out, which is the
    /// case this pane most needs to explain.
    private var modeText: String {
        switch libraryStore.mode {
        case .cloud:
            // Worth naming: it is why iCloud's own contents cannot be changed
            // from here.
            return libraryStore.isReplica
                ? "クラウド（iCloudと同期中・2台目以降）"
                : "クラウド（iCloudと同期中）"
        case .local:
            return libraryStore.syncEnabled
                ? "ローカル（iCloudを利用できないため）"
                : "ローカル"
        }
    }

    private var canToggle: Bool {
        // Turning it off has to stay possible while signed out, or the setting
        // would be stuck on with no way back.
        libraryStore.syncEnabled || cloudAccount.availability.isAvailable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PreferencesSectionHeader(
                title: "iCloud",
                subtitle: "本・シェルフ・ボリュームの書誌情報を、同じiCloudアカウントのMacやiPadと同期します。サムネイルと書籍ファイルはiCloudへ送信されません。"
            )

            PreferencesPanel {
                PreferencesSettingRow(
                    icon: "icloud",
                    title: "iCloud同期",
                    description: "オフにするとこの端末だけで動作します。オフの間の変更は、次にオンにしたときにまとめて送信されます。"
                ) {
                    Toggle("同期する", isOn: Binding(
                        get: { libraryStore.syncEnabled },
                        set: { isOn in
                            if isOn {
                                isAskingWhichLibraryWins = true
                            } else {
                                isConfirmingDisable = true
                            }
                        }
                    ))
                    .font(PreferencesLayout.bodyFont)
                    .toggleStyle(.switch)
                    .disabled(!canToggle || libraryStore.blockingTask != nil)
                }

                PreferencesDivider()

                PreferencesSettingRow(
                    icon: "checkmark.seal",
                    title: "状態",
                    description: cloudAccount.availability.statusText
                ) {
                    Button("更新") {
                        Task { await cloudAccount.refresh() }
                    }
                    .font(PreferencesLayout.bodyFont)
                }

                PreferencesDivider()

                PreferencesSettingRow(
                    icon: "person.crop.circle",
                    title: "アカウント",
                    description: cloudAccount.userRecordName.map {
                        "ID: \($0)\n同じiCloudアカウントの端末では同じIDになります。メールアドレスはiCloudの仕様によりアプリからは取得できません。"
                    } ?? "サインインすると、このアカウントのIDを表示します。"
                ) {
                    HStack(spacing: 6) {
                        if let recordName = cloudAccount.userRecordName {
                            Button("コピー") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(recordName, forType: .string)
                            }
                        }
                        Button("システム設定") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    .font(PreferencesLayout.bodyFont)
                }

                PreferencesDivider()

                PreferencesSettingRow(
                    icon: "externaldrive.connected.to.line.below",
                    title: "現在のモード",
                    description: lastSyncDescription
                ) {
                    Text(modeText)
                        .font(PreferencesLayout.bodyFont)
                        .foregroundColor(.secondary)
                }

                if libraryStore.mode == .cloud {
                    PreferencesDivider()

                    PreferencesSettingRow(
                        icon: "arrow.triangle.2.circlepath",
                        title: "同期の進行",
                        description: syncProgressDescription
                    ) {
                        if cloudAccount.isSyncing {
                            // CloudKit says a round finished and never how many
                            // are left, so there is nothing to fill a bar with.
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                        } else {
                            Text("送受信完了")
                                .font(PreferencesLayout.bodyFont)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            if libraryStore.mode == .cloud, !libraryStore.isReplica {
                PreferencesPanel {
                    PreferencesSettingRow(
                        icon: "arrow.up.doc.on.clipboard",
                        title: "iCloudへ全件を再送信",
                        description: "この端末の蔵書をすべて送信待ちに入れ直します。「未送信 0件」なのにiCloudや他の端末に蔵書が揃っていないときに使います。蔵書の内容は変わりません。"
                    ) {
                        if libraryStore.isResending {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                        } else {
                            Button("全件を送信待ちに入れる…") {
                                isConfirmingResend = true
                            }
                            .font(PreferencesLayout.bodyFont)
                            .disabled(!cloudAccount.availability.isAvailable || libraryStore.blockingTask != nil)
                        }
                    }
                }

                if let resendOutcome = libraryStore.resendMessage {
                    Text(resendOutcome)
                        .font(PreferencesLayout.smallCaptionFont)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Both of these reach into iCloud on behalf of every device. They
            // belong to the one that filled it; on a device that took iCloud's
            // copy they are only a way to destroy someone else's work.
            if !libraryStore.isReplica {
                PreferencesPanel {
                    PreferencesSettingRow(
                        icon: "trash",
                        title: "iCloudのデータを削除",
                        description: "このアプリがiCloudに保存している書誌情報をすべて消し、使用しているiCloudの容量を解放します。この端末の蔵書・サムネイル・設定は残ります。"
                    ) {
                        Button("iCloudから完全に削除…", role: .destructive) {
                            isConfirmingPurge = true
                        }
                        .font(PreferencesLayout.bodyFont)
                        .disabled(!cloudAccount.availability.isAvailable || libraryStore.blockingTask != nil)
                    }
                }

                if let purgeOutcome = cloudAccount.lastPurgeMessage {
                    Text(purgeOutcome)
                        .font(PreferencesLayout.smallCaptionFont)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if libraryStore.restartRequired {
                HStack(spacing: 8) {
                    Label("再起動すると新しい設定で開きます。", systemImage: "arrow.clockwise")
                        .font(PreferencesLayout.smallCaptionFont)
                    Button("今すぐ再起動") { relaunch() }
                        .font(PreferencesLayout.smallCaptionFont)
                }
                .foregroundColor(.orange)
            }

            Text("2台の蔵書を突き合わせる処理は行いません。1台目でiCloudへ送り、2台目以降はiCloudの蔵書で置き換える、という使い方になります。")
                .font(PreferencesLayout.smallCaptionFont)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await cloudAccount.refresh() }
        .task(id: libraryStore.mode) { await watchUploadBacklog() }
        .confirmationDialog(
            "どちらの蔵書を残しますか？",
            isPresented: $isAskingWhichLibraryWins,
            titleVisibility: .visible
        ) {
            Button("この端末の蔵書をiCloudへ送る（1台目）") {
                libraryStore.enableSyncSeedingCloud()
                relaunch()
            }
            Button("iCloudの蔵書で置き換える（2台目以降）", role: .destructive) {
                libraryStore.enableSyncReplacingLocalLibrary()
                relaunch()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("""
                どちらを選んでもアプリが再起動します。
                1台目を選ぶと、この端末の蔵書がiCloudへ送られます。
                2台目以降を選ぶと、この端末の蔵書とボリュームのアクセス権は削除され、iCloudの内容に置き換わります。削除は取り消せません。置き換えはアプリの再起動後に行われ、同期が終わるまで蔵書は空に見えます。
                すでにiCloudに蔵書がある状態で「1台目」を選ぶと、同じ本が二重に登録されます。
                """)
        }
        .confirmationDialog(
            "iCloud同期をオフにしますか？",
            isPresented: $isConfirmingDisable,
            titleVisibility: .visible
        ) {
            Button("オフにして再起動") {
                libraryStore.disableSync()
                relaunch()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この端末の蔵書はそのまま残り、iCloudへの送信だけを止めます。iCloud側の蔵書も消えません。反映にはアプリの再起動が必要です。")
        }
        .confirmationDialog(
            "蔵書をすべて送信待ちに入れますか？",
            isPresented: $isConfirmingResend,
            titleVisibility: .visible
        ) {
            Button("全件を送信待ちに入れる") {
                Task { await libraryStore.resendEverythingToCloud() }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("""
                この端末の蔵書をすべてiCloudへの送信待ちに入れ直します。蔵書の内容は変わらず、失われるものもありません。
                件数が多いと送信には時間がかかります。準備中はアプリの動作が重くなることがあります。
                他の端末で受け取るには、送信が終わってから「iCloudの蔵書で置き換える」を実行してください。
                """)
        }
        .confirmationDialog(
            "iCloudのデータをすべて削除しますか？",
            isPresented: $isConfirmingPurge,
            titleVisibility: .visible
        ) {
            Button("削除して再起動", role: .destructive) {
                libraryStore.requestCloudPurge()
                relaunch()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("""
                iCloudに保存されているこのアプリの書誌情報をすべて削除し、使用中のiCloud容量を解放します。削除は取り消せません。
                この端末の蔵書・サムネイル・設定は残ります。iCloud同期はオフになります。
                他の端末で同期をオンにしたままだと、その端末が同じ内容を再びアップロードします。先にすべての端末で同期をオフにしてください。
                削除はアプリの再起動後に実行されます。
                """)
        }
    }

    private var syncProgressDescription: String {
        guard let counts = cloudAccount.uploadCounts else {
            return "iCloudとの送受信の状態です。"
        }
        return "未送信 \(counts.pending.formatted())件 / 送信済み \(counts.uploaded.formatted())件 / この端末 \(counts.held.formatted())件"
    }

    /// Counting the backlog means reading the store, so it only runs while
    /// someone is looking at this pane.
    private func watchUploadBacklog() async {
        while !Task.isCancelled {
            cloudAccount.updateUploadCounts(
                libraryStore.mode == .cloud
                    ? CloudUploadBacklog.counts(container: libraryStore.container)
                    : nil
            )
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// Every mode change takes effect at the next launch: the store cannot be
    /// swapped under a running app without handing views models whose context
    /// has been torn down.
    private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    private var lastSyncDescription: String {
        if let task = libraryStore.blockingTask {
            return "「\(task)」の実行中は切り替えできません。"
        }
        guard let date = cloudAccount.lastSyncDate else {
            return "まだ同期していません。"
        }
        return "最終同期: \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

struct SecuritySettingsView: View {
    @AppStorage("advancedPasswordLockEnabled") private var lockEnabled = false
    @AppStorage("advancedPasswordValue") private var passwordValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PreferencesSectionHeader(
                title: "セキュリティ",
                subtitle: "起動後の簡易ロックとパスワードを設定します。"
            )

            PreferencesPanel {
                PreferencesSettingRow(
                    icon: "lock",
                    title: "簡易ロック",
                    description: "ウインドウの表示にパスワードの入力が必要になります。"
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("簡易ロックをかける", isOn: $lockEnabled)
                            .font(PreferencesLayout.bodyFont)

                        HStack(spacing: 10) {
                            Text("パスワード:")
                                .font(PreferencesLayout.bodyFont)
                                .lineLimit(1)
                                .fixedSize()
                            TextField("", text: $passwordValue)
                                .textFieldStyle(.roundedBorder)
                                .font(PreferencesLayout.bodyFont)
                                .accessibilityLabel("パスワード")
                                .disabled(!lockEnabled)
                                .frame(width: 220)
                        }
                    }
                    .frame(width: 330, alignment: .leading)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 6. Maintenance Pane
struct MaintenanceSettingsView: View {
    @AppStorage("backupEnabled") private var backupEnabled = false
    @AppStorage("backupFolderPath") private var backupFolderPath = ""
    @AppStorage("backupFolderBookmark") private var backupFolderBookmark = ""

    @State private var isBackingUp = false
    @State private var isRestoring = false
    @State private var showRestoreConfirmation = false
    @State private var backupStatusMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PreferencesSectionHeader(
                title: "保守",
                subtitle: "バックアップ、移行、修復などのメンテナンス操作を行います。"
            )

            backupSection

            PreferencesPanel {
                maintenanceRow(
                    title: "ボリューム管理...",
                    description: "外部ドライブやNASの場所が変わった時に、親ボリュームを再割り当てしてアクセス権を保存します。",
                    action: .manageVolumes
                )
                maintenanceRow(
                    title: "XMLライブラリのインポート...",
                    description: "StackroomのLibrary XMLを読み込み、既存データへマージします。",
                    action: .importXMLLibrary
                )
                maintenanceRow(
                    title: "Stackroomサムネイルの移行...",
                    description: "Stackroom Library内のthumbnail.jpgをShelfRowのキャッシュへコピーします。",
                    action: .migrateLegacyThumbnails
                )
                maintenanceRow(
                    title: "サムネイルの一括生成...",
                    description: "既存サムネイルを検査し、モノクロや横長の表紙を再抽出します。",
                    action: .repairThumbnails
                )
                maintenanceRow(
                    title: "ファイル名からタイトルを補完...",
                    description: "カスタマイズした書式でファイル名を解析し、空欄のタイトルや項目を埋めます。",
                    action: .repairEmptyTitles
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var backupSection: some View {
        PreferencesPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive.badge.timemachine")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .frame(width: 34, height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.accentColor.opacity(0.12))
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        Text("バックアップ")
                            .font(.system(size: 13, weight: .semibold))
                        Text("データベース、サムネイル、設定ファイルをまとめて保存・復元します。")
                            .font(PreferencesLayout.smallCaptionFont)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Toggle("有効", isOn: $backupEnabled)
                        .font(PreferencesLayout.bodyFont)
                }

            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(backupFolderPath.isEmpty ? "バックアップ先フォルダ未設定" : backupFolderPath)
                        .font(PreferencesLayout.bodyFont)
                        .foregroundStyle(backupFolderPath.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor).opacity(0.7)))

                Button("選択...") {
                    selectBackupFolder()
                }
                .controlSize(.large)
                .disabled(!backupEnabled || isBackingUp || isRestoring)
            }

            HStack(alignment: .top, spacing: 18) {
                Button(isBackingUp ? "バックアップ中..." : "今すぐバックアップ") {
                    runBackupNow()
                }
                .controlSize(.large)
                .disabled(!backupEnabled || backupFolderPath.isEmpty || isBackingUp || isRestoring)
                .frame(width: 240, alignment: .leading)

                Text("SwiftDataのDB、サムネイルキャッシュ、ShelfRowの設定ファイルを対象フォルダ内の「ShelfRowBackup」へ差分コピーします。前回とサイズ・更新日時が同じファイルはコピーせず、不要になったバックアップファイルは削除します。")
                    .font(PreferencesLayout.captionFont)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .top, spacing: 18) {
                Button(isRestoring ? "リストア中..." : "バックアップからリストア") {
                    showRestoreConfirmation = true
                }
                .controlSize(.large)
                .disabled(!backupEnabled || backupFolderPath.isEmpty || isBackingUp || isRestoring)
                .frame(width: 240, alignment: .leading)

                Text("選択中のバックアップ先にある「ShelfRowBackup」から復元します。現在のDB・サムネイル・設定はバックアップ時点の内容で上書きされ、古い状態への先祖返りも許容します。完了後はShelfRowを再起動してください。")
                    .font(PreferencesLayout.captionFont)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !backupStatusMessage.isEmpty {
                Text(backupStatusMessage)
                    .font(PreferencesLayout.captionFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("バックアップからリストアしますか？", isPresented: $showRestoreConfirmation) {
            Button("リストア", role: .destructive) {
                runRestoreNow()
            }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("現在のShelfRowデータはバックアップ時点の内容で上書きされます。リストア完了後はShelfRowを再起動してください。")
        }
    }

    private func maintenanceRow(title: String, description: String, action: MaintenanceAction) -> some View {
        PreferencesSettingRow(
            icon: maintenanceIcon(for: action),
            title: title.replacingOccurrences(of: "...", with: ""),
            description: description
        ) {
            Button(title) {
                NotificationCenter.default.post(name: .maintenanceActionRequested, object: action)
            }
            .controlSize(.large)
            .frame(width: 210, alignment: .leading)
        }
    }

    private func maintenanceIcon(for action: MaintenanceAction) -> String {
        switch action {
        case .manageVolumes: return "externaldrive"
        case .importXMLLibrary: return "square.and.arrow.down"
        case .migrateLegacyThumbnails: return "photo.on.rectangle"
        case .repairThumbnails: return "wand.and.stars"
        case .repairEmptyTitles: return "textformat"
        }
    }

    private func selectBackupFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "バックアップ先フォルダを選択"

        if panel.runModal() == .OK, let url = panel.url {
            backupFolderPath = url.path
            if let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                backupFolderBookmark = bookmark.base64EncodedString()
                backupStatusMessage = ""
            } else {
                backupFolderBookmark = ""
                backupStatusMessage = "フォルダへのアクセス権を保存できませんでした。もう一度「選択...」でフォルダを指定してください。"
            }
        }
    }

    private func runBackupNow() {
        guard let folderURL = resolvedBackupFolderURL() else {
            backupStatusMessage = "バックアップ先フォルダのアクセス権がありません。「選択...」でフォルダを再指定してください。"
            return
        }

        isBackingUp = true
        backupStatusMessage = "バックアップを開始しています..."

        Task {
            let didStartAccessing = folderURL.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    folderURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let summary = try await Task.detached(priority: .utility) {
                    try ShelfRowBackupManager.backUp(to: folderURL)
                }.value
                backupStatusMessage = "バックアップ完了: コピー \(summary.copiedFiles) 件、スキップ \(summary.skippedFiles) 件、削除 \(summary.removedFiles) 件。"
            } catch {
                backupStatusMessage = "バックアップに失敗しました: \(error.localizedDescription)"
            }
            isBackingUp = false
        }
    }

    private func runRestoreNow() {
        guard let folderURL = resolvedBackupFolderURL() else {
            backupStatusMessage = "バックアップ先フォルダのアクセス権がありません。「選択...」でフォルダを再指定してください。"
            return
        }

        isRestoring = true
        backupStatusMessage = "リストアを開始しています..."

        Task {
            let didStartAccessing = folderURL.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    folderURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let summary = try await Task.detached(priority: .utility) {
                    try ShelfRowBackupManager.restore(from: folderURL)
                }.value
                backupStatusMessage = "リストア完了: 復元 \(summary.copiedFiles) 件、削除 \(summary.removedFiles) 件。ShelfRowを再起動してください。"
            } catch {
                backupStatusMessage = "リストアに失敗しました: \(error.localizedDescription)"
            }
            isRestoring = false
        }
    }

    private func resolvedBackupFolderURL() -> URL? {
        guard let bookmarkData = Data(base64Encoded: backupFolderBookmark), !bookmarkData.isEmpty else {
            return nil
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        if isStale,
           let updatedBookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            backupFolderBookmark = updatedBookmark.base64EncodedString()
            backupFolderPath = url.path
        }
        return url
    }
}

struct ShelfRowBackupSummary: Equatable, Sendable {
    var copiedFiles = 0
    var skippedFiles = 0
    var removedFiles = 0

    nonisolated init(copiedFiles: Int = 0, skippedFiles: Int = 0, removedFiles: Int = 0) {
        self.copiedFiles = copiedFiles
        self.skippedFiles = skippedFiles
        self.removedFiles = removedFiles
    }
}

enum ShelfRowBackupManager {
    private struct BackupSource: Sendable {
        let name: String
        let url: URL
        let isDirectory: Bool
    }

    private struct ManifestEntry: Codable, Sendable {
        var size: Int64
        var modificationTime: TimeInterval

        nonisolated init(size: Int64, modificationTime: TimeInterval) {
            self.size = size
            self.modificationTime = modificationTime
        }

        nonisolated func matches(_ other: ManifestEntry) -> Bool {
            size == other.size && modificationTime == other.modificationTime
        }
    }

    nonisolated static func backUp(to selectedFolder: URL) throws -> ShelfRowBackupSummary {
        UserDefaults.standard.synchronize()

        let backupRoot = selectedFolder.appendingPathComponent("ShelfRowBackup", isDirectory: true)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)

        let manifestURL = backupRoot.appendingPathComponent("manifest.json")
        let previousManifest = readManifest(from: manifestURL)
        let sources = backupSources()

        var currentManifest: [String: ManifestEntry] = [:]
        var summary = ShelfRowBackupSummary()

        for source in sources {
            // Continue to the next source even if one fails, such as a permission error on a single source.
            try? backUpSource(
                source,
                backupRoot: backupRoot,
                previousManifest: previousManifest,
                currentManifest: &currentManifest,
                summary: &summary
            )
        }

        for relativePath in previousManifest.keys where currentManifest[relativePath] == nil {
            let staleURL = backupRoot.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: staleURL.path) {
                try FileManager.default.removeItem(at: staleURL)
                summary.removedFiles += 1
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(currentManifest)
        try manifestData.write(to: manifestURL, options: .atomic)

        return summary
    }

    nonisolated static func restore(from selectedFolder: URL) throws -> ShelfRowBackupSummary {
        let backupRoot = selectedFolder.appendingPathComponent("ShelfRowBackup", isDirectory: true)
        let manifestURL = backupRoot.appendingPathComponent("manifest.json")
        let manifest = readManifest(from: manifestURL)
        guard !manifest.isEmpty else {
            throw NSError(
                domain: "ShelfRowBackup",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "バックアップのmanifest.jsonが見つからないか、空です。"]
            )
        }

        let sources = Dictionary(uniqueKeysWithValues: backupSources().map { ($0.name, $0) })
        var summary = ShelfRowBackupSummary()

        try removeFilesMissingFromBackup(
            backupManifest: manifest,
            sources: sources,
            backupRoot: backupRoot,
            summary: &summary
        )

        for relativePath in manifest.keys.sorted() {
            guard let splitPath = splitBackupRelativePath(relativePath),
                  let source = sources[splitPath.sourceName] else {
                continue
            }

            let backupFileURL = backupRoot.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: backupFileURL.path) else {
                continue
            }

            let destinationURL = source.isDirectory
                ? source.url.appendingPathComponent(splitPath.pathInsideSource)
                : source.url
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: backupFileURL, to: destinationURL)
            if let entry = manifest[relativePath] {
                let modificationDate = Date(timeIntervalSince1970: entry.modificationTime)
                try? FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: destinationURL.path)
            }
            summary.copiedFiles += 1
        }

        UserDefaults.standard.synchronize()
        return summary
    }

    nonisolated private static func backupSources() -> [BackupSource] {
        let fileManager = FileManager.default
        var sources: [BackupSource] = []

        if let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
           fileManager.fileExists(atPath: applicationSupport.path) {
            sources.append(BackupSource(name: "ApplicationSupport", url: applicationSupport, isDirectory: true))
        }

        let thumbnailDir = ThumbnailCache.diskCacheDirectory
        if fileManager.fileExists(atPath: thumbnailDir.path) {
            sources.append(BackupSource(name: "Thumbnails", url: thumbnailDir, isDirectory: true))
        }

        if let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first {
            let bundleID = ThumbnailCache.appIdentifier
            let preferences = library
                .appendingPathComponent("Preferences", isDirectory: true)
                .appendingPathComponent("\(bundleID).plist")
            if fileManager.fileExists(atPath: preferences.path) {
                sources.append(BackupSource(name: "Preferences", url: preferences, isDirectory: false))
            }
        }

        return sources
    }

    nonisolated private static func removeFilesMissingFromBackup(
        backupManifest: [String: ManifestEntry],
        sources: [String: BackupSource],
        backupRoot: URL,
        summary: inout ShelfRowBackupSummary
    ) throws {
        for source in sources.values {
            if source.isDirectory {
                guard let enumerator = FileManager.default.enumerator(
                    at: source.url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsPackageDescendants]
                ) else {
                    continue
                }

                for case let fileURL as URL in enumerator {
                    if isFile(fileURL, containedIn: backupRoot) {
                        continue
                    }
                    let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                    guard values.isRegularFile == true else { continue }
                    let relative = source.name + "/" + relativePath(from: source.url, to: fileURL)
                    if backupManifest[relative] == nil {
                        try FileManager.default.removeItem(at: fileURL)
                        summary.removedFiles += 1
                    }
                }
            } else {
                let relative = source.name + "/" + source.url.lastPathComponent
                if backupManifest[relative] == nil, FileManager.default.fileExists(atPath: source.url.path) {
                    try FileManager.default.removeItem(at: source.url)
                    summary.removedFiles += 1
                }
            }
        }
    }

    nonisolated private static func isSQLiteAuxiliaryFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasSuffix("-wal") || name.hasSuffix("-shm") || name.hasSuffix("-journal")
    }

    nonisolated private static func backUpSource(
        _ source: BackupSource,
        backupRoot: URL,
        previousManifest: [String: ManifestEntry],
        currentManifest: inout [String: ManifestEntry],
        summary: inout ShelfRowBackupSummary
    ) throws {
        if source.isDirectory {
            guard let enumerator = FileManager.default.enumerator(
                at: source.url,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsPackageDescendants]
            ) else {
                return
            }

            for case let fileURL as URL in enumerator {
                if isFile(fileURL, containedIn: backupRoot) {
                    continue
                }
                // SQLite WAL/SHM/journal files are ephemeral transaction logs; skip them.
                if isSQLiteAuxiliaryFile(fileURL) {
                    continue
                }
                do {
                    let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                    guard values.isRegularFile == true else { continue }
                    let relativePath = source.name + "/" + relativePath(from: source.url, to: fileURL)
                    try backUpFile(
                        from: fileURL,
                        relativePath: relativePath,
                        values: values,
                        backupRoot: backupRoot,
                        previousManifest: previousManifest,
                        currentManifest: &currentManifest,
                        summary: &summary
                    )
                } catch {
                    // Skip files that cannot be read or copied, and continue to the next file.
                    summary.skippedFiles += 1
                }
            }
        } else {
            let values = try source.url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true else { return }
            let relativePath = source.name + "/" + source.url.lastPathComponent
            try backUpFile(
                from: source.url,
                relativePath: relativePath,
                values: values,
                backupRoot: backupRoot,
                previousManifest: previousManifest,
                currentManifest: &currentManifest,
                summary: &summary
            )
        }
    }

    nonisolated private static func backUpFile(
        from sourceURL: URL,
        relativePath: String,
        values: URLResourceValues,
        backupRoot: URL,
        previousManifest: [String: ManifestEntry],
        currentManifest: inout [String: ManifestEntry],
        summary: inout ShelfRowBackupSummary
    ) throws {
        let entry = ManifestEntry(
            size: Int64(values.fileSize ?? 0),
            modificationTime: values.contentModificationDate?.timeIntervalSince1970 ?? 0
        )
        currentManifest[relativePath] = entry

        let destinationURL = backupRoot.appendingPathComponent(relativePath)
        if previousManifest[relativePath]?.matches(entry) == true,
           FileManager.default.fileExists(atPath: destinationURL.path) {
            summary.skippedFiles += 1
            return
        }

        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        if let modificationDate = values.contentModificationDate {
            try? FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: destinationURL.path)
        }
        summary.copiedFiles += 1
    }

    nonisolated private static func relativePath(from root: URL, to fileURL: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return fileURL.lastPathComponent }
        let startIndex = filePath.index(filePath.startIndex, offsetBy: rootPath.count)
        return String(filePath[startIndex...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    nonisolated private static func isFile(_ fileURL: URL, containedIn directoryURL: URL) -> Bool {
        let directoryPath = directoryURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        return filePath == directoryPath || filePath.hasPrefix(directoryPath + "/")
    }

    nonisolated private static func splitBackupRelativePath(_ relativePath: String) -> (sourceName: String, pathInsideSource: String)? {
        guard let slashIndex = relativePath.firstIndex(of: "/") else { return nil }
        let sourceName = String(relativePath[..<slashIndex])
        let pathStart = relativePath.index(after: slashIndex)
        let pathInsideSource = String(relativePath[pathStart...])
        guard !sourceName.isEmpty, !pathInsideSource.isEmpty else { return nil }
        return (sourceName, pathInsideSource)
    }

    nonisolated private static func readManifest(from url: URL) -> [String: ManifestEntry] {
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode([String: ManifestEntry].self, from: data) else {
            return [:]
        }
        return manifest
    }
}
