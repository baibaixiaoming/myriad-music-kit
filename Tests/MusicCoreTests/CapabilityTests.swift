import Testing
@testable import MusicCore

@Suite struct CapabilityStatusTests {
    @Test func onlyAvailableIsExecutable() {
        let all: [CapabilityStatus] = [.unsupported, .unverified, .checking, .available,
                                       .requiresLogin, .insufficientEntitlement,
                                       .resourceUnavailable, .temporaryFailure]
        #expect(all.filter(\.isExecutable) == [.available])
    }

    @Test func unknownStatesAreNotCachedAsFinal() {
        #expect(!CapabilityStatus.unverified.isCacheableAsFinal)
        #expect(!CapabilityStatus.temporaryFailure.isCacheableAsFinal)
        #expect(CapabilityStatus.unsupported.isCacheableAsFinal)
    }

    @Test func documentedEvidenceIsNotExposed() {
        #expect(!EvidenceLevel.documented.mayBeExposedInUI)
        #expect(!EvidenceLevel.invoked.mayBeExposedInUI)
        #expect(EvidenceLevel.implemented.mayBeExposedInUI)
    }

    @Test func pageWithCursorIsNotComplete() {
        let page = Page<Int>(items: [1], nextCursor: PageCursor("2"))
        #expect(!page.isLastPage)
    }

    @Test func authFailuresAreNotAutoRetried() {
        #expect(!MusicError(.credentialExpired, userMessage: "").isAutomaticallyRetryable)
        #expect(!MusicError(.resourceRemoved, userMessage: "").isAutomaticallyRetryable)
        #expect(MusicError(.network, userMessage: "").isAutomaticallyRetryable)
    }
}
