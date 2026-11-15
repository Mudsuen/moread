import AppKit
import ReaderCore

struct ChapterLoadRequest: Sendable {
    let generation: UInt64
    let book: Book
    let chapter: Int
    let character: Int
    let end: Bool
    let position: ReadingPosition?
}
struct ImportBatch {
    let urls: [URL]
    let intent: UInt64
    let completion: ((Bool) -> Void)?
}

extension ReaderApp {
    func invalidateChapterLoad() {
        chapterGeneration += 1; pendingChapter = nil; requestedChapter = nil
        chapterReadTask?.cancel()
    }
    func invalidateReadingIntent() { readingIntentGeneration += 1; invalidateChapterLoad() }

    func openBook(_ target: Book, chapter: Int, character: Int = 0, end: Bool = false, position: ReadingPosition? = nil, userInitiated: Bool = true) {
        guard !terminating else { return }
        if userInitiated { invalidateReadingIntent() } else { invalidateChapterLoad() }
        guard target.chapters.indices.contains(chapter) else { refreshLibrary(); showError(ReaderError.invalid("章节不存在")); return }
        if target.id != displayedBookID { chapterPicker?.close() }
        let request = ChapterLoadRequest(generation: chapterGeneration, book: target, chapter: chapter, character: character, end: end, position: position)
        requestedChapter = request; pendingChapter = request
        guard chapterTask == nil else { return }
        chapterTask = Task { [self] in
            while let request = pendingChapter {
                pendingChapter = nil
                let loader = chapterLoader
                let read = Task.detached(priority: .userInitiated) { Result { try Task.checkCancellation(); return try loader(request.book, request.chapter) } }
                chapterReadTask = read
                let result = await read.value
                chapterReadTask = nil
                guard request.generation == chapterGeneration, !terminating else { continue }
                requestedChapter = nil
                switch result {
                case .success(let text):
                    let migrated = request.position?.requiresTextMigration == true
                    let character = migrated ? 0 : (request.position?.character ?? request.character)
                    let legacy = migrated ? request.position?.character : request.position?.legacyCharacter
                    commitChapter(book: request.book, chapter: request.chapter, text: text, character: character, end: request.end, legacyCharacter: legacy, legacyChapter: migrated ? request.position?.chapter : request.position?.legacyChapter, migrated: migrated)
                case .failure(let error):
                    refreshLibrary() // Restores committed book/TOC; filtered searches still select their first candidate.
                    if !(error is CancellationError) { showError(error) }
                }
            }
            chapterTask = nil
        }
    }
    func waitForChapterLoad() async { await chapterTask?.value }

    func importURLs(_ urls: [URL], completion: ((Bool) -> Void)? = nil) {
        guard !terminating, !urls.isEmpty else { completion?(false); return }
        invalidateReadingIntent()
        importBatches.append(ImportBatch(urls: urls, intent: readingIntentGeneration, completion: completion))
        startPendingImports()
    }
    func rejectPendingImports() {
        let rejected = importBatches; importBatches.removeAll()
        for batch in rejected { batch.completion?(false) }
    }
    func startPendingImports() {
        guard importsReady, libraryLoaded, importTask == nil, !importBatches.isEmpty else { return }
        importing = true
        importTask = Task { [self] in
            while !importBatches.isEmpty {
                let batch = importBatches.removeFirst()
                var failures: [String] = []
                var lastSuccessful: (book: Book, text: String)?
                for url in batch.urls {
                    subtitleLabel.stringValue = "正在导入：\(url.lastPathComponent)"
                    let importer = bookImporter, library = support.appendingPathComponent("Books")
                    let result = await Task.detached(priority: .userInitiated) { Result { try importer(url, library) } }.value
                    switch result {
                    case .success(let imported):
                        state.books.append(imported.book)
                        recordPosition()
                        switch await persistence.flush(state) {
                        case .success: lastSuccessful = imported
                        case .failure(let error): failures.append("\(url.lastPathComponent)：书架未保存，\(error.localizedDescription)")
                        }
                    case .failure(let error): failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                    }
                }
                refreshLibrary()
                if let imported = lastSuccessful, batch.intent == readingIntentGeneration, !terminating {
                    invalidateChapterLoad()
                    search.stringValue = ""
                    commitChapter(book: imported.book, chapter: 0, text: imported.text, save: false)
                    revealReader(highlight: true, userInitiated: false)
                    // Completion includes the final selected-book/position snapshot, too.
                    if case .failure(let error) = await persistence.flush(state) { failures.append("书架未保存：\(error.localizedDescription)") }
                }
                batch.completion?(failures.isEmpty)
                if !failures.isEmpty { showError(ReaderError.invalid(failures.joined(separator: "\n"))) }
            }
            importing = false; importTask = nil
        }
    }
    func waitForImports() async { await importTask?.value }
}
