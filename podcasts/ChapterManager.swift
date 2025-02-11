import Foundation
import PocketCastsDataModel
import PocketCastsUtils

class ChapterManager {
    private var chapterParser = PodcastChapterParser()
    private var showInfoCoordinator: ShowInfoCoordinating
    private var chapters = [ChapterInfo]() {
        didSet {
            visibleChapters = chapters.filter { !$0.isHidden }
        }
    }
    private var visibleChapters = [ChapterInfo]()

    private var lastEpisodeUuid = ""

    var numberOfChaptersSkipped = 0

    var currentChapters = Chapters()

    private var playableChapters: [ChapterInfo] {
        visibleChapters.filter { $0.isPlayable() }
    }

    init(
        chapterParser: PodcastChapterParser = PodcastChapterParser(),
        showInfoCoordinator: ShowInfoCoordinating = ShowInfoCoordinator.shared) {
        self.chapterParser = chapterParser
        self.showInfoCoordinator = showInfoCoordinator
    }

    func visibleChapterCount() -> Int {
        visibleChapters.count
    }

    func playableChapterCount() -> Int {
        playableChapters.count
    }

    func haveTriedToParseChaptersFor(episodeUuid: String?) -> Bool {
        lastEpisodeUuid == episodeUuid
    }

    func previousVisibleChapter() -> ChapterInfo? {
        guard let visibleChapter = currentChapters.visibleChapter else {
            return nil
        }
        let previousChapter: ChapterInfo?

        if let index = visibleChapters.firstIndex(of: visibleChapter) {
            previousChapter = visibleChapters.enumerated().filter { $0.offset < index && $0.element.isPlayable() }.map { $0.element }.last
        } else {
            previousChapter = nil
        }
        return previousChapter
    }

    func nextVisiblePlayableChapter() -> ChapterInfo? {
        guard let visibleChapter = currentChapters.visibleChapter else {
            return nil
        }
        let nextChapter: ChapterInfo?

        if let index = visibleChapters.firstIndex(of: visibleChapter) {
            nextChapter = visibleChapters.enumerated().first { $0.offset > index && $0.element.isPlayable() }.map { $0.element }
        } else {
            nextChapter = nil
        }
        return nextChapter
    }

    var lastChapter: ChapterInfo? {
        visibleChapters.last
    }

    func chapterAt(index: Int) -> ChapterInfo? {
        visibleChapters[safe: index]
    }

    func playableChapterAt(index: Int) -> ChapterInfo? {
        visibleChapters.filter({ $0.isPlayable() })[safe: index]
    }

    func index(for chapter: Chapters) -> Int? {
        guard let visibleChapter = chapter.visibleChapter else {
            return nil
        }

        return playableChapters.firstIndex(of: visibleChapter)
    }

    @discardableResult
    func updateCurrentChapter(time: TimeInterval) -> Bool {
        if chapters.count == 0 { return false }

        let chapters = chaptersForTime(time)
        let hasChanged = currentChapters != chapters

        if hasChanged {
            currentChapters = chapters
        }

        return hasChanged
    }

    func parseChapters(episode: BaseEpisode, duration: TimeInterval) {
        Task {
            await parseChapters(episode: episode, duration: duration)
        }
    }

    func parseChapters(episode: BaseEpisode, duration: TimeInterval) async {
        // store the last episode uuid we were asked to check chapters for, we use that below in case this method is called multiple times to not return old results
        lastEpisodeUuid = episode.uuid

        guard !FeatureFlag.rssChapters.enabled else {
            try? await parseLocalAndRemoteChapters(for: episode, duration: duration)
            return
        }

        if episode.downloaded(pathFinder: DownloadManager.shared) {
            chapterParser.parseLocalFile(episode.pathToDownloadedFile(pathFinder: DownloadManager.shared), episodeDuration: duration) { [weak self] parsedChapters in
                if self?.lastEpisodeUuid == episode.uuid {
                    self?.handleChaptersLoaded(parsedChapters, for: episode)
                }
            }
        } else if let url = EpisodeManager.urlForEpisode(episode) {
            chapterParser.parseRemoteFile(url.absoluteString, episodeDuration: duration) { [weak self] parsedChapters in
                if self?.lastEpisodeUuid == episode.uuid {
                    self?.handleChaptersLoaded(parsedChapters, for: episode)
                }
            }
        }
    }

    private func parseLocalAndRemoteChapters(for episode: BaseEpisode, duration: TimeInterval) async throws {
        // Parse chapters from the file and request external chapters
        async let fileChaptersAsync = loadChapters(for: episode, duration: duration)

        async let (podloveChaptersAsync, podcastIndexChaptersAsync) = await
        showInfoCoordinator.loadChapters(podcastUuid: episode.parentIdentifier(), episodeUuid: episode.uuid)

        var chapters: [ChapterInfo]

        do {
            let (fileChapters, podloveChapters, podcastIndexChapters) = try await (fileChaptersAsync, podloveChaptersAsync, podcastIndexChaptersAsync)

            // Prioritize embedded chapters, given for some shows it will take
            // into account dynamic ads
            if !fileChapters.isEmpty {
                chapters = fileChapters
            } else if let externalChapters = parseExternalChapters(podlove: podloveChapters, podcastIndex: podcastIndexChapters, duration: duration) {
                chapters = externalChapters
            } else {
                chapters = []
            }
        } catch {
            chapters = await fileChaptersAsync
        }

        if lastEpisodeUuid == episode.uuid {
            handleChaptersLoaded(chapters, for: episode)
        }
    }

    private func loadChapters(for episode: BaseEpisode, duration: TimeInterval) async -> [ChapterInfo] {
        if episode.downloaded(pathFinder: DownloadManager.shared) {
            return await chapterParser.parseLocalFile(episode.pathToDownloadedFile(pathFinder: DownloadManager.shared), episodeDuration: duration)
        } else if let url = EpisodeManager.urlForEpisode(episode) {
            return await chapterParser.parseRemoteFile(url.absoluteString, episodeDuration: duration)
        }

        return []
    }

    private func parseExternalChapters(podlove: [Episode.Metadata.EpisodeChapter]?, podcastIndex: [PodcastIndexChapter]?, duration: TimeInterval) -> [ChapterInfo]? {
        if let podcastIndex {
            return chapterParser.parsePodcastIndexChapters(podcastIndex, episodeDuration: duration)
        }

        if let podlove {
            return chapterParser.parsePodloveChapters(podlove, episodeDuration: duration)
        }

        return nil
    }

    func clearChapterInfo() {
        lastEpisodeUuid = ""
        chapters.removeAll()
        currentChapters = Chapters()

        NotificationCenter.postOnMainThread(notification: Constants.Notifications.podcastChaptersDidUpdate)
    }

    func chaptersForTime(_ time: TimeInterval) -> Chapters {
        Chapters(chapters: chapters.filter { $0.startTime.seconds <= time && ($0.startTime.seconds + $0.duration) > time })
    }

    private func handleChaptersLoaded(_ chapters: [ChapterInfo], for episode: BaseEpisode) {
        self.chapters = chapters

        episode.deselectedChapters?
            .split(separator: ",")
            .compactMap { Int($0) }
            .forEach { self.chapters[safe: $0]?.shouldPlay = false }

        updateCurrentChapter(time: PlaybackManager.shared.currentTime())

        NotificationCenter.postOnMainThread(notification: Constants.Notifications.podcastChaptersDidUpdate)
    }
}
