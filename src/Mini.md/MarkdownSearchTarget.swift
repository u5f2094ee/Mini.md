import AppKit

struct SearchResultState {
    let count: Int
    let activeIndex: Int?
}

@MainActor
protocol MarkdownSearchTarget: AnyObject {
    func updateSearchQuery(_ query: String, completion: ((SearchResultState) -> Void)?)
    func activateNextSearchMatch(completion: ((SearchResultState) -> Void)?)
    func clearSearchHighlightsPreservingScroll()
    func focus()
}

extension MarkdownRenderView: MarkdownSearchTarget {
    func updateSearchQuery(_ query: String, completion: ((SearchResultState) -> Void)?) {
        updateSearchQuery(query) { count, activeIndex in
            completion?(SearchResultState(count: count, activeIndex: activeIndex))
        }
    }

    func activateNextSearchMatch(completion: ((SearchResultState) -> Void)?) {
        activateNextSearchMatch { count, activeIndex in
            completion?(SearchResultState(count: count, activeIndex: activeIndex))
        }
    }
}
