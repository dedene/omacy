import XCTest
@testable import Omacy

@MainActor
final class OmacyAsciiConverterTests: XCTestCase {
    func testSuccessfulConversionReturnsSwiftStringAndFreesTextExactlyOnce() throws {
        let api = FakeAsciiAPI(status: OMACY_OK, text: "hello\nworld")

        let result = try OmacyAsciiConverter.convert(Data([1, 2, 3]), settings: .init(), api: api)

        XCTAssertEqual(result, "hello\nworld")
        XCTAssertEqual(api.freeCount, 1)
    }

    func testEngineFailureIncludesStatusDetailAndStillFreesReturnedText() {
        let api = FakeAsciiAPI(status: OMACY_ERR_ENGINE, text: "partial", detail: "engine")

        XCTAssertThrowsError(
            try OmacyAsciiConverter.convert(Data([1]), settings: .init(), api: api)
        ) { error in
            XCTAssertEqual(
                error as? OmacyAsciiConversionError,
                .engine(status: OMACY_ERR_ENGINE, detail: "engine")
            )
            XCTAssertEqual(error.localizedDescription, "Image conversion failed (status 4): engine")
        }
        XCTAssertEqual(api.freeCount, 1)
    }

    func testSuccessWithoutTextReportsContractViolationWithoutFreeing() {
        let api = FakeAsciiAPI(status: OMACY_OK, text: nil)

        XCTAssertThrowsError(
            try OmacyAsciiConverter.convert(Data([1]), settings: .init(), api: api)
        ) { error in
            XCTAssertEqual(error as? OmacyAsciiConversionError, .missingText)
        }
        XCTAssertEqual(api.freeCount, 0)
    }
}

private final class FakeAsciiAPI: OmacyAsciiConvertingAPI {
    let status: omacy_status
    let detail: String?
    private let handle = OpaquePointer(bitPattern: 0xCAFE)!
    private var storage: UnsafeMutablePointer<CChar>?
    private let count: Int
    private let returnsText: Bool
    private(set) var freeCount = 0

    init(status: omacy_status, text: String?, detail: String? = nil) {
        self.status = status
        self.detail = detail
        returnsText = text != nil
        let bytes = text.map { Array($0.utf8) } ?? []
        count = bytes.count
        if text != nil {
            let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count + 1)
            for (index, byte) in bytes.enumerated() {
                pointer[index] = CChar(bitPattern: byte)
            }
            pointer[bytes.count] = 0
            storage = pointer
        }
    }

    deinit {
        storage?.deallocate()
    }

    func convert(
        config: inout OmacyAsciiConfig,
        bytes: UnsafePointer<UInt8>?,
        count: Int,
        output: inout OpaquePointer?
    ) -> omacy_status {
        output = returnsText ? handle : nil
        return status
    }

    func utf8(_ text: OpaquePointer) -> UnsafePointer<CChar>? {
        guard let storage else { return nil }
        return UnsafePointer(storage)
    }

    func length(_ text: OpaquePointer) -> Int { count }

    func free(_ text: OpaquePointer) {
        XCTAssertEqual(text, handle)
        freeCount += 1
    }

    func statusDescription(_ status: omacy_status) -> String? { detail }
}
