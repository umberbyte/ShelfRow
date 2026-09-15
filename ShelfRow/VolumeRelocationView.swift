//
//  VolumeRelocationView.swift
//  ShelfRow
//
//  Created by Go Sugawara on 2026/09/16.
//

import SwiftUI
import SwiftData

struct VolumeRelocationView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Volume.name) private var volumes: [Volume]
    @Binding var isPresented: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("ボリューム管理とパス再割り当て")
                    .font(.headline)
                Spacer()
                Button("閉じる") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            if volumes.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("管理されているボリュームがありません。")
                        .font(.callout)
                    Text("XMLライブラリをインポートすると、ここにボリュームが表示されます。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(volumes) { volume in
                        VolumeRowView(volume: volume)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .frame(width: 550, height: 350)
    }
}

struct VolumeRowView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var volume: Volume
    @State private var isAccessible: Bool = false
    @State private var bookmarkErrorMessage: String? = nil
    
    var body: some View {
        HStack(spacing: 12) {
            // Status Indicator
            Circle()
                .fill(isAccessible ? Color.green : Color.red)
                .frame(width: 10, height: 10)
                .help(isAccessible ? "接続済み（アクセス可能）" : "未接続（アクセス不可、再割り当てが必要です）")
            
            VStack(alignment: .leading, spacing: 4) {
                Text(volume.name)
                    .font(.body)
                    .fontWeight(.medium)
                
                Text(volume.lastKnownPath)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            Button("フォルダーを再割り当て...") {
                relocateVolume()
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 6)
        .onAppear {
            checkAccessibility()
        }
        .alert("アクセス権の保存に失敗しました", isPresented: Binding(
            get: { bookmarkErrorMessage != nil },
            set: { if !$0 { bookmarkErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(bookmarkErrorMessage ?? "")
        }
    }
    
    private func checkAccessibility() {
        // Check if the directory actually exists and is accessible
        let path = volume.lastKnownPath
        var accessible = FileManager.default.fileExists(atPath: path)
        
        if !accessible, let bookmark = volume.bookmarkData {
            var isStale = false
            if let resolvedURL = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale) {
                if resolvedURL.startAccessingSecurityScopedResource() {
                    accessible = FileManager.default.fileExists(atPath: resolvedURL.path)
                    resolvedURL.stopAccessingSecurityScopedResource()
                }
            }
        }
        isAccessible = accessible
    }
    
    private func relocateVolume() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "'\(volume.name)' の新しい親フォルダーを選択してください"
        panel.prompt = "選択"
        panel.directoryURL = URL(fileURLWithPath: volume.lastKnownPath)
        
        if panel.runModal() == .OK {
            guard let url = panel.url else { return }
            
            _ = url.startAccessingSecurityScopedResource()
            defer {
                url.stopAccessingSecurityScopedResource()
            }
            
            do {
                // Generate a Security-Scoped Bookmark for persistent access under Sandbox
                let bookmark = try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                
                volume.bookmarkData = bookmark
                volume.lastKnownPath = url.path
                volume.name = url.lastPathComponent
                
                try modelContext.save()
                
                // Immediately update status
                isAccessible = true
            } catch {
                // Without the app-scope bookmark entitlement this throws;
                // surface it so the user knows access will not persist.
                bookmarkErrorMessage = "セキュリティブックマークを作成できませんでした。アプリの再起動後はこのボリュームへ再度アクセス権の付与が必要になる可能性があります。\n\n詳細: \(error.localizedDescription)"
            }
        }
    }
}
