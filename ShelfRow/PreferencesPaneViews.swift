//
//  PreferencesPaneViews.swift
//  ShelfRow
//
//  Created by Go Sugawara on 2026/09/17.
//

import SwiftUI
import UniformTypeIdentifiers

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

// MARK: - 1. Slideshow Tab
struct SlideshowSettingsView: View {
    @AppStorage("slideshowHelperPath") private var slideshowHelperName = ""
    @AppStorage("slideshowHelperFullPath") private var slideshowHelperFullPath = ""

    @AppStorage("zipHelperPath") private var zipHelperName = ""
    @AppStorage("zipHelperFullPath") private var zipHelperFullPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("ビューア")
                .font(.title2.weight(.semibold))

            SettingsRow(label: "スライドショーヘルパー:") {
                helperField(name: $slideshowHelperName, fullPath: $slideshowHelperFullPath)
                if slideshowHelperName.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("画像フォルダを開くための外部ビューアを設定してください。")
                        .font(PreferencesLayout.captionFont)
                        .foregroundColor(.red)
                } else {
                    Text("使用するビューアは画像フォルダのドラッグ＆ドロップに対応している必要があります。")
                        .font(PreferencesLayout.captionFont)
                        .foregroundColor(.secondary)
                }
            }

            SettingsRow(label: "Zip アーカイブヘルパー:") {
                helperField(name: $zipHelperName, fullPath: $zipHelperFullPath)
                if zipHelperName.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Zip アーカイブを開くための外部ビューアを設定してください。")
                        .font(PreferencesLayout.captionFont)
                        .foregroundColor(.red)
                } else {
                    Text("使用するビューアは Zip アーカイブの閲覧に対応している必要があります。")
                        .font(PreferencesLayout.captionFont)
                        .foregroundColor(.secondary)
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
        VStack(alignment: .leading, spacing: 14) {
            Text("ヘルパー")
                .font(.title2.weight(.semibold))
            Text("拡張子ごとに起動するアプリケーションを設定します。拡張子は1行にカンマ区切りで複数登録できます。ここに登録された拡張子はD&D登録でも受け入れます。rar / zip / 7z はページ数で種類を判定し、それ以外はムービーとして登録します。")
                .font(PreferencesLayout.captionFont)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

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
                            .tag(idx)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 280)
                    .border(Color.gray.opacity(0.3))

                    HStack(spacing: 4) {
                        Button(action: addMapping) {
                            Image(systemName: "plus.circle.fill")
                        }
                        Button(action: removeMapping) {
                            Image(systemName: "minus")
                        }
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
                                Button("選択...") {
                                    selectHelper(at: idx)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 280)
                    .border(Color.gray.opacity(0.3))

                    HStack(spacing: 4) {
                        Button(action: addMapping) {
                            Image(systemName: "plus.circle.fill")
                        }
                        Button(action: removeMapping) {
                            Image(systemName: "minus")
                        }
                        .disabled(selectedIndex == nil)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
                .frame(maxWidth: .infinity)
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
        VStack(alignment: .leading, spacing: 16) {
            Text("キーワード")
                .font(.title2.weight(.semibold))

            Text("同じものとして扱いたい作者名・ジャンル・キーワードなどをグループ化します。検索欄にグループ内のいずれかを入力すると、同じグループの全キーワードを含む項目も検索結果に含まれます。")
                .font(PreferencesLayout.captionFont)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

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
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(NSColor.separatorColor).opacity(0.8), lineWidth: 1)
            )

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
            Text("カスタマイズ")
                .font(.title2.weight(.semibold))

            VStack(alignment: .center, spacing: 8) {
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
    @AppStorage("advancedCloseOnExit") private var closeOnExit = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("一般")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 10) {
                Toggle("メインウインドウを閉じると終了", isOn: $closeOnExit)
                    .font(PreferencesLayout.bodyFont)

                Text("メインウインドウを閉じた時にShelfRowを終了します。")
                    .font(PreferencesLayout.captionFont)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 5. Security Pane
struct SecuritySettingsView: View {
    @AppStorage("advancedPasswordLockEnabled") private var lockEnabled = false
    @AppStorage("advancedPasswordValue") private var passwordValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("セキュリティ")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("簡易ロックをかける", isOn: $lockEnabled)
                        .font(PreferencesLayout.bodyFont)

                    HStack(spacing: 10) {
                        Text("パスワード:")
                            .font(PreferencesLayout.bodyFont)
                        TextField("", text: $passwordValue)
                            .textFieldStyle(.roundedBorder)
                            .font(PreferencesLayout.bodyFont)
                            .disabled(!lockEnabled)
                            .frame(width: 220)
                    }

                    Text("ウインドウの表示にパスワードの入力が必要になります。")
                        .font(PreferencesLayout.captionFont)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 18) {
            Text("保守")
                .font(.title2.weight(.semibold))

            backupSection

            VStack(alignment: .leading, spacing: 10) {
                maintenanceRow(
                    title: "ボリューム管理...",
                    description: "外部ドライブやNASの場所が変わった時に、親ボリュームを再割り当てしてアクセス権を保存します。",
                    action: .manageVolumes
                )
                maintenanceRow(
                    title: "XMLライブラリのインポート...",
                    description: "旧StackroomのLibrary XMLを読み込み、既存データへマージします。",
                    action: .importXMLLibrary
                )
                maintenanceRow(
                    title: "旧Stackroomサムネイルの移行...",
                    description: "旧Stackroom Library内のthumbnail.jpgをShelfRowのキャッシュへコピーします。",
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var backupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("バックアップ")
                .font(PreferencesLayout.sectionTitleFont)

            Toggle("バックアップを有効にする", isOn: $backupEnabled)
                .font(PreferencesLayout.bodyFont)

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
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor).opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(NSColor.separatorColor).opacity(0.65)))
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
        HStack(alignment: .top, spacing: 18) {
            Button(title) {
                NotificationCenter.default.post(name: .maintenanceActionRequested, object: action)
            }
            .controlSize(.large)
            .frame(width: 240, alignment: .leading)

            Text(description)
                .font(PreferencesLayout.captionFont)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
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
