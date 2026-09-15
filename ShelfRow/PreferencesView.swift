//
//  PreferencesView.swift
//  ShelfRow
//
//  Created by Go Sugawara on 2026/09/16.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct PreferencesView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            SlideshowSettingsView()
                .tabItem {
                    Label("スライドショー", systemImage: "play.rectangle")
                }
                .tag(0)

            HelperSettingsView()
                .tabItem {
                    Label("ヘルパー", systemImage: "square.and.arrow.up")
                }
                .tag(1)

            CustomizeSettingsView()
                .tabItem {
                    Label("カスタマイズ", systemImage: "slider.horizontal.3")
                }
                .tag(2)

            AdvancedSettingsView()
                .tabItem {
                    Label("詳細設定", systemImage: "gearshape")
                }
                .tag(3)
        }
        .frame(width: 540, height: 500)
        .padding()
    }
}

// MARK: - Shared right-aligned label row (classic Stackroom form layout)
private struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .frame(width: 160, alignment: .trailing)
            VStack(alignment: .leading, spacing: 6) {
                content
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 1. Slideshow Tab
struct SlideshowSettingsView: View {
    @AppStorage("slideshowShowProgress") private var showProgress = true
    @AppStorage("slideshowShowFileName") private var showFileName = false
    @AppStorage("slideshowShowWorkName") private var showWorkName = true

    @AppStorage("slideshowHelperPath") private var slideshowHelperName = ""
    @AppStorage("slideshowHelperFullPath") private var slideshowHelperFullPath = ""

    @AppStorage("zipHelperPath") private var zipHelperName = ""
    @AppStorage("zipHelperFullPath") private var zipHelperFullPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsRow(label: "追加表示項目:") {
                Toggle("進行状況", isOn: $showProgress)
                Toggle("ファイル名", isOn: $showFileName)
                Toggle("作品名・作者名", isOn: $showWorkName)
            }

            SettingsRow(label: "スライドショーヘルパー:") {
                helperField(name: $slideshowHelperName, fullPath: $slideshowHelperFullPath)
                if slideshowHelperName.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("画像フォルダを開くための外部ビューアを設定してください。")
                        .font(.caption)
                        .foregroundColor(.red)
                } else {
                    Text("使用するビューアは画像フォルダのドラッグ＆ドロップに対応している必要があります。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            SettingsRow(label: "Zip アーカイブヘルパー:") {
                helperField(name: $zipHelperName, fullPath: $zipHelperFullPath)
                if zipHelperName.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Zip アーカイブを開くための外部ビューアを設定してください。")
                        .font(.caption)
                        .foregroundColor(.red)
                } else {
                    Text("使用するビューアは Zip アーカイブの閲覧に対応している必要があります。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding()
    }

    private func helperField(name: Binding<String>, fullPath: Binding<String>) -> some View {
        let appName = name.wrappedValue.trimmingCharacters(in: .whitespaces)
        return HStack(spacing: 8) {
            // Display-only label of the chosen app (editing the name is meaningless)
            HStack(spacing: 6) {
                Image(systemName: "app.dashed")
                    .foregroundColor(.secondary)
                Text(appName.isEmpty ? "(未設定)" : appName)
                    .foregroundColor(appName.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
            }
            .frame(width: 180, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(NSColor.controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.gray.opacity(0.3)))

            Button("選択...") {
                selectApp(name: name, fullPath: fullPath)
            }

            if !appName.isEmpty {
                Button("解除") {
                    name.wrappedValue = ""
                    fullPath.wrappedValue = ""
                }
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
    @AppStorage("helperExtensionsList") private var extensionList = "mov, avi, mpg\nrar"
    @AppStorage("helperApplicationsList") private var applicationList = "\n"

    @State private var extensions: [String] = ["mov, avi, mpg", "rar"]
    @State private var helpers: [String] = ["", ""]
    @State private var selectedIndex: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ヘルパーの設定:")
                .font(.headline)
            Text("拡張子ごとにヘルパーの設定ができます。通常はリストの一番上のヘルパーが使用されます。")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(alignment: .top, spacing: 12) {
                // Extensions Column (with its own +/- buttons, like the original)
                VStack(alignment: .leading, spacing: 4) {
                    Text("拡張子 (コンマ区切り)")
                        .font(.caption)
                        .fontWeight(.bold)
                    List(selection: $selectedIndex) {
                        ForEach(0..<extensions.count, id: \.self) { idx in
                            TextField("", text: Binding(
                                get: { extensions[idx] },
                                set: { extensions[idx] = $0; saveLists() }
                            ))
                            .textFieldStyle(.plain)
                            .tag(idx)
                        }
                    }
                    .frame(height: 200)
                    .border(Color.gray.opacity(0.3))

                    HStack(spacing: 4) {
                        Button(action: addMapping) {
                            Image(systemName: "plus")
                        }
                        Button(action: removeMapping) {
                            Image(systemName: "minus")
                        }
                        .disabled(selectedIndex == nil)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                // Helpers Column (with its own +/- buttons)
                VStack(alignment: .leading, spacing: 4) {
                    Text("ヘルパーアプリケーション")
                        .font(.caption)
                        .fontWeight(.bold)
                    List {
                        ForEach(0..<helpers.count, id: \.self) { idx in
                            HStack {
                                TextField("", text: Binding(
                                    get: { helpers[idx] },
                                    set: { helpers[idx] = $0; saveLists() }
                                ))
                                .textFieldStyle(.plain)
                                Button("選択...") {
                                    selectHelper(at: idx)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    .frame(height: 200)
                    .border(Color.gray.opacity(0.3))

                    HStack(spacing: 4) {
                        Button(action: addMapping) {
                            Image(systemName: "plus")
                        }
                        Button(action: removeMapping) {
                            Image(systemName: "minus")
                        }
                        .disabled(selectedIndex == nil)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Spacer()
        }
        .padding()
        .onAppear {
            loadLists()
        }
    }

    private func loadLists() {
        let exts = extensionList.components(separatedBy: "\n").filter { !$0.isEmpty }
        let apps = applicationList.components(separatedBy: "\n")

        self.extensions = exts.isEmpty ? ["mov, avi, mpg", "rar"] : exts
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
        VStack(alignment: .leading, spacing: 16) {
            // NOTE: 未実装 — the rename format token feature is not yet wired up.
            // Colored red for visibility until implemented.
            VStack(alignment: .center, spacing: 4) {
                Text("フォーマットのカスタマイズ: (未実装)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)

                TextField("", text: $renameFormat)
                    .textFieldStyle(.roundedBorder)
                    .foregroundColor(.red)

                Text("ファイルのリネームや項目名のコピー等に適用されます。必要な項目が未記入のときは、そのトークン（青いひとまとまり）は省略されます。")
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("書式:\nタイトル @title  キーワードA @keywordA  キーワードB @keywordB\n作者 @author  関連 @relation  ジャンル @genre  種類 @type")
                    .font(.caption2)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("種類のカスタマイズ:")
                        .font(.system(size: 12, weight: .bold))

                    customTypeRow(typeIndex: 0, placeholder: "厚い本", text: $thickBook)
                    customTypeRow(typeIndex: 1, placeholder: "薄い本", text: $thinBook)
                    customTypeRow(typeIndex: 2, placeholder: "本の一部", text: $partBook)
                    customTypeRow(typeIndex: 3, placeholder: "画像セット", text: $imageSet)
                    customTypeRow(typeIndex: 4, placeholder: "テキスト", text: $textType)
                    customTypeRow(typeIndex: 5, placeholder: "ムービー", text: $movieType)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("項目のカスタマイズ:")
                        .font(.system(size: 12, weight: .bold))

                    customFieldRow(placeholder: "作者", text: $fieldAuthor)
                    customFieldRow(placeholder: "ジャンル", text: $fieldGenre)
                    customFieldRow(placeholder: "関連", text: $fieldRelation)
                    customFieldRow(placeholder: "キーワード A", text: $fieldKeywordA)
                    customFieldRow(placeholder: "キーワード B", text: $fieldKeywordB)
                }
            }

            Spacer()
        }
        .padding()
    }

    private func customTypeRow(typeIndex: Int, placeholder: String, text: Binding<String>) -> some View {
        HStack {
            Image(systemName: BookTypeInfo.systemImage(for: typeIndex))
                .foregroundColor(BookTypeInfo.color(for: typeIndex))
                .frame(width: 22)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
        }
    }

    private func customFieldRow(placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 180)
    }
}

// MARK: - 4. Advanced Tab
struct AdvancedSettingsView: View {
    @Environment(\.modelContext) private var modelContext

    @AppStorage("advancedCloseOnExit") private var closeOnExit = true
    @AppStorage("advancedPasswordLockEnabled") private var lockEnabled = false
    @AppStorage("advancedPasswordValue") private var passwordValue = ""

    @State private var restoreMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsRow(label: "セキュリティ:") {
                Toggle("メインウインドウを閉じると終了", isOn: $closeOnExit)
                Toggle("簡易ロックをかける", isOn: $lockEnabled)

                HStack {
                    Text("パスワード :")
                    SecureField("", text: $passwordValue)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!lockEnabled)
                        .frame(width: 140)
                }
                .padding(.leading, 18)

                Text("ウインドウの表示にパスワードの入力が必要になります。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 18)
            }

            SettingsRow(label: "エイリアスの復元:") {
                Button("ファイルの位置をライブラリに書き込む...") {
                    exportFileLocations()
                }
                Button("ライブラリに書き込まれた位置を読み込む...") {
                    importFileLocations()
                }

                if let message = restoreMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.blue)
                }

                Text("\(Text("●注意 ").foregroundStyle(.red))これらの機能はOSのクリーンインストール、HDDの交換等の際に使用します。まずデータを消去する前に上のボタンで最新のファイルのパスを位置ファイルに文字列として書き込み、すべてのデータを新しい環境に移し替えた後、下のボタンで、書き込んだパスを元に位置を把握し直します。読み込み時は、ファイルは同じパスに存在していなければなりません（ユーザ名やフォルダの構成が変化していてはいけません）。なお本アプリケーションでは、ボリューム単位の一括再割り当て（サイドバー下の「ボリューム管理...」）も使用できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Alias Restore (modernized: JSON path snapshot export / re-import)

    private func exportFileLocations() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ShelfRow Locations.json"
        panel.title = "ファイルの位置をライブラリに書き込む"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let items = try modelContext.fetch(FetchDescriptor<Item>())
            let entries: [[String: Any]] = items.map { item in
                var entry: [String: Any] = [
                    "id": item.id.uuidString,
                    "path": (item.volume?.lastKnownPath ?? "") + "/" + item.relativePath
                ]
                if let legacyID = item.legacyID {
                    entry["legacyID"] = legacyID
                }
                return entry
            }
            let data = try JSONSerialization.data(withJSONObject: ["items": entries], options: [.prettyPrinted])
            try data.write(to: url, options: .atomic)
            restoreMessage = "\(entries.count)件のファイル位置を書き込みました。"
        } catch {
            restoreMessage = "書き込みに失敗しました: \(error.localizedDescription)"
        }
    }

    private func importFileLocations() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.title = "ライブラリに書き込まれた位置を読み込む"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = dict["items"] as? [[String: Any]] else {
                restoreMessage = "位置ファイルの形式が不正です。"
                return
            }

            let items = try modelContext.fetch(FetchDescriptor<Item>())
            var itemsByID: [String: Item] = [:]
            var itemsByLegacyID: [Int: Item] = [:]
            for item in items {
                itemsByID[item.id.uuidString] = item
                if let legacyID = item.legacyID {
                    itemsByLegacyID[legacyID] = item
                }
            }

            let volumes = try modelContext.fetch(FetchDescriptor<Volume>())
            var volumesByPath: [String: Volume] = [:]
            for volume in volumes {
                volumesByPath[volume.lastKnownPath] = volume
            }

            var updated = 0
            for entry in entries {
                guard let path = entry["path"] as? String, !path.isEmpty else { continue }

                let item: Item?
                if let idString = entry["id"] as? String, let found = itemsByID[idString] {
                    item = found
                } else if let legacyID = entry["legacyID"] as? Int, let found = itemsByLegacyID[legacyID] {
                    item = found
                } else {
                    item = nil
                }
                guard let item else { continue }

                let (volumePath, volumeName, relativePath) = PathParser.split(path)
                let volume: Volume
                if let existing = volumesByPath[volumePath] {
                    volume = existing
                } else {
                    let newVolume = Volume(name: volumeName, lastKnownPath: volumePath)
                    modelContext.insert(newVolume)
                    volumesByPath[volumePath] = newVolume
                    volume = newVolume
                }

                if item.volume !== volume || item.relativePath != relativePath {
                    item.volume = volume
                    item.relativePath = relativePath
                    updated += 1
                }
            }

            try modelContext.save()
            restoreMessage = "\(updated)件のファイル位置を更新しました。"
        } catch {
            restoreMessage = "読み込みに失敗しました: \(error.localizedDescription)"
        }
    }
}
