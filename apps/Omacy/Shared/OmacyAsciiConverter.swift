import Foundation

protocol OmacyAsciiConvertingAPI {
    func convert(
        config: inout OmacyAsciiConfig,
        bytes: UnsafePointer<UInt8>?,
        count: Int,
        output: inout OpaquePointer?
    ) -> omacy_status
    func utf8(_ text: OpaquePointer) -> UnsafePointer<CChar>?
    func length(_ text: OpaquePointer) -> Int
    func free(_ text: OpaquePointer)
    func statusDescription(_ status: omacy_status) -> String?
}

struct OmacyLiveAsciiAPI: OmacyAsciiConvertingAPI {
    func convert(
        config: inout OmacyAsciiConfig,
        bytes: UnsafePointer<UInt8>?,
        count: Int,
        output: inout OpaquePointer?
    ) -> omacy_status {
        omacy_ascii_from_bytes(&config, bytes, count, &output)
    }

    func utf8(_ text: OpaquePointer) -> UnsafePointer<CChar>? {
        omacy_text_utf8(text)
    }

    func length(_ text: OpaquePointer) -> Int {
        omacy_text_len(text)
    }

    func free(_ text: OpaquePointer) {
        omacy_text_free(text)
    }

    func statusDescription(_ status: omacy_status) -> String? {
        guard let value = omacy_status_string(status) else { return nil }
        return String(validatingUTF8: value)
    }
}

enum OmacyAsciiConversionError: LocalizedError, Equatable {
    case engine(status: omacy_status, detail: String?)
    case missingText
    case missingUTF8
    case invalidUTF8

    var errorDescription: String? {
        switch self {
        case let .engine(status, detail):
            let explanation = detail.map { ": \($0)" } ?? ""
            return "Image conversion failed (status \(status))\(explanation)"
        case .missingText:
            return "Image conversion returned no text"
        case .missingUTF8:
            return "Image conversion returned an invalid text buffer"
        case .invalidUTF8:
            return "Image conversion returned text that is not valid UTF-8"
        }
    }
}

/// Owns the complete C text-buffer lifecycle so UI code only sees Swift values.
@MainActor
enum OmacyAsciiConverter {
    static func convert(
        _ data: Data,
        settings: OmacySettings,
        api: any OmacyAsciiConvertingAPI = OmacyLiveAsciiAPI()
    ) throws -> String {
        var config = OmacyAsciiConfig()
        config.mode = settings.asciiModeCode
        config.width = 80
        config.height = 26
        config.threshold = UInt8(settings.threshold)
        config.invert = settings.invert ? 1 : 0
        config.trim = 1

        var output: OpaquePointer?
        let status = data.withUnsafeBytes { raw in
            api.convert(
                config: &config,
                bytes: raw.bindMemory(to: UInt8.self).baseAddress,
                count: data.count,
                output: &output
            )
        }

        if let output {
            defer { api.free(output) }
            guard status == OMACY_OK else {
                throw OmacyAsciiConversionError.engine(
                    status: status,
                    detail: api.statusDescription(status)
                )
            }
            guard let pointer = api.utf8(output) else {
                throw OmacyAsciiConversionError.missingUTF8
            }
            let bytes = UnsafeRawBufferPointer(start: pointer, count: api.length(output))
            guard let result = String(bytes: bytes, encoding: .utf8) else {
                throw OmacyAsciiConversionError.invalidUTF8
            }
            return result
        }

        guard status == OMACY_OK else {
            throw OmacyAsciiConversionError.engine(
                status: status,
                detail: api.statusDescription(status)
            )
        }
        throw OmacyAsciiConversionError.missingText
    }
}
