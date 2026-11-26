import Foundation

public extension NodeState {
    /// Recorded files use an explicit-file fingerprint; older locks retain their folder encoding.
    func acceptanceTestsDigest(in directory: URL, testFolder: String) -> String {
        if let recordedTests {
            return Hashing.digest(ofRecordedFiles: recordedTests.files, in: directory)
        }
        return Hashing.digest(of: directory.appending(path: testFolder))
    }

    /// Snapshot before a harness-controlled move, so moving cannot legitimize an already broken lock.
    func testsLocksIntact(in directory: URL, testFolder: String) -> Bool {
        (testsDigest == nil || acceptanceTestsDigest(in: directory, testFolder: testFolder) == testsDigest)
            && updatedOtherTestsIntact(in: directory)
    }

    /// Renew intact locks together without changing the own-test record.
    func renewedTestsLocks(in directory: URL, testFolder: String, wasIntact: Bool) -> [EventKind] {
        guard wasIntact else { return [] }
        let digest = acceptanceTestsDigest(in: directory, testFolder: testFolder)
        if testsDigest != nil, digest != testsDigest {
            var events: [EventKind] = [.testsFixed(digest: digest)]
            // testsFixed clears the other-test lock, so restore even an unchanged fingerprint.
            if !updatedOtherTests.isEmpty {
                events.append(.otherTestsUpdated(
                    files: updatedOtherTests,
                    digest: Hashing.digest(ofFiles: updatedOtherTests, in: directory)))
            }
            return events
        }
        return renewedOtherTestsLock(in: directory, wasIntact: true).map { [$0] } ?? []
    }
}
