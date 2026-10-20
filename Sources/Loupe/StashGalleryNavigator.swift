import LoupeCore
import StashKitUI

/// Folder steps through the Stash gallery list a gallery was opened from (Stash spec §2.3): `StashGalleryList` pages
/// the list, `StashLibrary` maps each gallery's path (mounting its share), a plain `FolderNavigator` lists it. The end
/// and the skipped galleries are said in the viewer's toast.
enum StashGalleryNavigator {
    @MainActor static func make(list context: StashGalleryListContext, library: StashLibrary,
                                toast: ToastView) -> ListFolderNavigator {
        let list = StashGalleryList(variables: context.variables, finder: library.client)
        let lister = FolderNavigator()
        let tidy = Settings.shared.config.stashTitleTidy
        let say: @Sendable (String) -> Void = { text in Task { @MainActor in toast.show(text) } }
        return ListFolderNavigator(
            start: context.index,
            next: { index, step in
                switch try await list.step(from: index, step) {
                case .gallery(let gallery, let index, let count):
                    // `StashGalleryList` only gives galleries with a path.
                    let title = StashGalleryTitle.display(title: gallery.title, path: gallery.path, tidy: tidy)
                    return .item(title: title, path: gallery.path ?? "", index: index, count: count, id: gallery.id)
                case .end:
                    return .end
                }
            },
            resolve: { path in await library.resolve(path).mapError { $0 as Error } },
            contents: { url in try await lister.contents(of: url) },
            onEnd: { say("End of the Stash list") },
            onSkip: say)
    }
}
