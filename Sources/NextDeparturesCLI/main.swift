import Foundation
import TransitCore

// Schedules are kept with your other caches. Live updates are never written down.
let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("next-departures", isDirectory: true)
let library = FeedLibrary(folder: caches, fetcher: FeedFetcher())
let status = await Command.run(
    Array(CommandLine.arguments.dropFirst()), library: library,
    out: { print($0) },
    err: { fputs($0 + "\n", stderr) }
)
exit(status)
