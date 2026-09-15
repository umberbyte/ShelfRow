//
//  SmartShelfEditorView.swift
//  ShelfRow
//
//  Created by Go Sugawara on 2026/09/16.
//

import SwiftUI
import SwiftData

/// Faithful recreation of the classic Stackroom "新規スマートシェルフ" dialog:
/// name + folder icon, キーワード / 日時 / 種類 / レート / 未読 condition rows.
struct SmartShelfEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Binding var isPresented: Bool

    /// When non-nil the dialog edits an existing smart shelf.
    var editingShelf: Shelf? = nil

    // Customized field labels (Customize settings tab)
    @AppStorage("fieldNameAuthor") private var fieldAuthor = "作者"
    @AppStorage("fieldNameGenre") private var fieldGenre = "ジャンル"
    @AppStorage("fieldNameRelation") private var fieldRelation = "関連"
    @AppStorage("fieldNameKeywordA") private var fieldKeywordA = "キーワードA"
    @AppStorage("fieldNameKeywordB") private var fieldKeywordB = "キーワードB"

    // Customized type labels
    @AppStorage("typeNameThickBook") private var thickBook = "厚い本"
    @AppStorage("typeNameThinBook") private var thinBook = "薄い本"
    @AppStorage("typeNamePartBook") private var partBook = "本の一部"
    @AppStorage("typeNameImageSet") private var imageSet = "画像セット"
    @AppStorage("typeNameText") private var textType = "テキスト"
    @AppStorage("typeNameMovie") private var movieType = "ムービー"

    // Dialog state
    @State private var name = "新規スマートシェルフ"
    @State private var icon = 0

    @State private var keywordEnabled = false
    @State private var keywordField = "Title"
    @State private var keywordText = ""
    @State private var keywordMode = 0

    @State private var dateEnabled = false
    @State private var dateField = 0
    @State private var dateDays = "30"
    @State private var dateMode = 0

    @State private var typeEnabled = false
    @State private var selectedTypes: Set<Int> = []

    @State private var rateEnabled = false
    @State private var selectedRates: Set<Int> = []

    @State private var unreadEnabled = false
    @State private var unreadOnly = false // false = ALL, true = O (未読のみ)

    private var keywordFieldChoices: [(String, String)] {
        [("Title", "タイトル"),
         ("Author", fieldAuthor),
         ("Genre", fieldGenre),
         ("Relation", fieldRelation),
         ("Keyword A", fieldKeywordA),
         ("Keyword B", fieldKeywordB),
         ("Neta", "メモ")]
    }

    private var typeNames: [String] {
        [thickBook, thinBook, partBook, imageSet, textType, movieType]
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(editingShelf == nil ? "新規スマートシェルフ" : "スマートシェルフを編集")
                .font(.system(size: 13, weight: .bold))
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(Color(NSColor.windowBackgroundColor))

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                // 名前 + アイコン
                HStack(spacing: 8) {
                    Text("名前:")
                        .frame(width: 60, alignment: .trailing)
                    TextField("", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)

                    // Folder icon selector (classic colored folder popup)
                    Picker("", selection: $icon) {
                        ForEach(0..<7, id: \.self) { idx in
                            Image(systemName: "folder.fill")
                                .foregroundColor(BookTypeInfo.folderColor(forIcon: idx))
                                .tag(idx)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 60)
                    Spacer()
                }
                .padding(.top, 6)

                // キーワード
                conditionGroup(isOn: $keywordEnabled, label: "キーワード") {
                    HStack(spacing: 8) {
                        Picker("", selection: $keywordField) {
                            ForEach(keywordFieldChoices, id: \.0) { choice in
                                Text(choice.1).tag(choice.0)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130)

                        Text("が")

                        TextField("", text: $keywordText)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 120)

                        Picker("", selection: $keywordMode) {
                            Text("の項目").tag(0)
                            Text("でない項目").tag(1)
                            Text("と一致する項目").tag(2)
                        }
                        .labelsHidden()
                        .frame(width: 130)
                    }
                    .disabled(!keywordEnabled)
                }

                // 日時
                conditionGroup(isOn: $dateEnabled, label: "日時") {
                    HStack(spacing: 8) {
                        Picker("", selection: $dateField) {
                            Text("登録した日").tag(0)
                            Text("最後に読んだ日").tag(1)
                        }
                        .labelsHidden()
                        .frame(width: 130)

                        Text("が")

                        TextField("", text: $dateDays)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 120)

                        Picker("", selection: $dateMode) {
                            Text("日以内の項目").tag(0)
                            Text("日以上前の項目").tag(1)
                        }
                        .labelsHidden()
                        .frame(width: 130)
                    }
                    .disabled(!dateEnabled)
                }

                // 種類 + レート (side by side like the original)
                HStack(alignment: .top, spacing: 24) {
                    HStack(spacing: 8) {
                        Toggle("種類", isOn: $typeEnabled)
                            .toggleStyle(.checkbox)
                        typeSegments
                            .disabled(!typeEnabled)
                            .opacity(typeEnabled ? 1 : 0.5)
                    }

                    HStack(spacing: 8) {
                        Toggle("レート", isOn: $rateEnabled)
                            .toggleStyle(.checkbox)
                        rateSegments
                            .disabled(!rateEnabled)
                            .opacity(rateEnabled ? 1 : 0.5)
                    }
                }

                // 未読 + 注記
                HStack(alignment: .top, spacing: 24) {
                    HStack(spacing: 8) {
                        Toggle("未読", isOn: $unreadEnabled)
                            .toggleStyle(.checkbox)
                        unreadSegments
                            .disabled(!unreadEnabled)
                            .opacity(unreadEnabled ? 1 : 0.5)
                    }

                    Text("※フィルタはクリックで追加選択／選択解除できます")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Divider()

            // キャンセル / OK
            HStack(spacing: 12) {
                Spacer()
                Button("キャンセル") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("OK") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 560)
        .onAppear(perform: loadFromShelf)
    }

    // MARK: - Condition group layout (checkbox + inset rounded content)
    private func conditionGroup<Content: View>(isOn: Binding<Bool>, label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(label, isOn: isOn)
                .toggleStyle(.checkbox)
            content()
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor).opacity(0.6)))
                .padding(.leading, 18)
        }
    }

    // MARK: - Segment controls
    private var typeSegments: some View {
        HStack(spacing: 0) {
            segmentButton(title: "ALL", isSelected: selectedTypes.isEmpty) {
                selectedTypes.removeAll()
            }
            ForEach(0..<BookTypeInfo.count, id: \.self) { idx in
                segmentButton(isSelected: selectedTypes.contains(idx)) {
                    if selectedTypes.contains(idx) {
                        selectedTypes.remove(idx)
                    } else {
                        selectedTypes.insert(idx)
                    }
                } label: {
                    Image(systemName: BookTypeInfo.systemImage(for: idx))
                        .font(.system(size: 9))
                        .foregroundColor(BookTypeInfo.color(for: idx))
                }
                .help(typeNames[idx])
            }
        }
        .border(Color.gray.opacity(0.4), width: 1)
    }

    private var rateSegments: some View {
        HStack(spacing: 0) {
            segmentButton(title: "ALL", isSelected: selectedRates.isEmpty) {
                selectedRates.removeAll()
            }
            ForEach(1...5, id: \.self) { rate in
                segmentButton(title: String(repeating: "★", count: rate), fontSize: 7, isSelected: selectedRates.contains(rate)) {
                    if selectedRates.contains(rate) {
                        selectedRates.remove(rate)
                    } else {
                        selectedRates.insert(rate)
                    }
                }
            }
        }
        .border(Color.gray.opacity(0.4), width: 1)
    }

    private var unreadSegments: some View {
        HStack(spacing: 0) {
            segmentButton(title: "ALL", isSelected: !unreadOnly) {
                unreadOnly = false
            }
            segmentButton(isSelected: unreadOnly) {
                unreadOnly = true
            } label: {
                Circle()
                    .stroke(Color.green, lineWidth: 2)
                    .frame(width: 8, height: 8)
            }
        }
        .border(Color.gray.opacity(0.4), width: 1)
    }

    private func segmentButton(title: String, fontSize: CGFloat = 10, isSelected: Bool, action: @escaping () -> Void) -> some View {
        segmentButton(isSelected: isSelected, action: action) {
            Text(title)
                .font(.system(size: fontSize, weight: isSelected ? .bold : .regular))
        }
    }

    private func segmentButton<Label: View>(isSelected: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(minWidth: 22)
                .background(isSelected ? Color.blue.opacity(0.25) : Color(NSColor.controlBackgroundColor))
                .foregroundColor(isSelected ? .blue : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Load / Save
    private func loadFromShelf() {
        guard let shelf = editingShelf else { return }
        name = shelf.title
        icon = shelf.icon

        let conditions = SmartConditionsCodec.decode(shelf.smartConditionsJson)
        if let keyword = conditions.keyword {
            keywordEnabled = true
            keywordField = keyword.field
            keywordText = keyword.text
            keywordMode = keyword.mode
        }
        if let date = conditions.date {
            dateEnabled = true
            dateField = date.field
            dateDays = String(date.days)
            dateMode = date.mode
        }
        if let types = conditions.types {
            typeEnabled = true
            selectedTypes = types
        }
        if let rates = conditions.rates {
            rateEnabled = true
            selectedRates = rates
        }
        if conditions.unreadOnly {
            unreadEnabled = true
            unreadOnly = true
        }
    }

    private func save() {
        var conditions = SmartConditions()
        if keywordEnabled && !keywordText.isEmpty {
            conditions.keyword = .init(field: keywordField, text: keywordText, mode: keywordMode)
        }
        if dateEnabled {
            conditions.date = .init(field: dateField, days: Int(dateDays) ?? 30, mode: dateMode)
        }
        if typeEnabled && !selectedTypes.isEmpty {
            conditions.types = selectedTypes
        }
        if rateEnabled && !selectedRates.isEmpty {
            conditions.rates = selectedRates
        }
        conditions.unreadOnly = unreadEnabled && unreadOnly

        let json = SmartConditionsCodec.encode(conditions)

        if let shelf = editingShelf {
            shelf.title = name
            shelf.icon = icon
            shelf.smartConditionsJson = json
        } else {
            let shelf = Shelf(title: name, icon: icon, type: 1, smartConditionsJson: json)
            modelContext.insert(shelf)
        }
        try? modelContext.save()
        isPresented = false
    }
}
