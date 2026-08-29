struct OmacyPinnedPreviewState {
    var desired: OmacyPinnedContent?
    private(set) var committed: OmacyPinnedContent?
    var usesPinnedLayout: Bool { committed != nil }

    func candidateUsesPinnedLayout(isPreview: Bool) -> Bool {
        desired != nil || isPreview
    }

    mutating func commitPinned(_ content: OmacyPinnedContent) {
        committed = content
    }

    mutating func commitPublic() {
        committed = nil
    }

    func suppressesRequest(_ content: OmacyPinnedContent) -> Bool {
        desired == content && committed == content
    }

    func shouldRetry(content: OmacyPinnedContent, rejectedIdentityMatches: Bool, canRun: Bool) -> Bool {
        desired == content && committed != content && !rejectedIdentityMatches && canRun
    }
}
