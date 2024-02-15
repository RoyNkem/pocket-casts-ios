import PocketCastsDataModel
import PocketCastsUtils

extension DataManager {
    func importPodcastSettings() {
        let podcasts = allPodcasts(includeUnsubscribed: true)

        podcasts.forEach { podcast in
            podcast.settings.$autoStartFrom = ModifiedDate<Int32>(wrappedValue: podcast.startFrom)
            podcast.settings.$autoSkipLast = ModifiedDate<Int32>(wrappedValue: podcast.skipLast)
            podcast.settings.$playbackSpeed = ModifiedDate<Double>(wrappedValue: podcast.playbackSpeed)
            podcast.settings.$trimSilence = ModifiedDate<TrimSilenceAmount>(wrappedValue: TrimSilenceAmount(rawValue: podcast.trimSilenceAmount)!)
            podcast.settings.$boostVolume = ModifiedDate<Bool>(wrappedValue: podcast.boostVolume)

            save(podcast: podcast)
        }
    }
}