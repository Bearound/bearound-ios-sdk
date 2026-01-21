//
//  APIClientTests.swift
//  BearoundSDKTests
//
//  Tests for API communication
//

import Foundation
import Testing

@testable import BearoundSDK

@Suite("APIClient Tests")
struct APIClientTests {

    @Test("APIError descriptions")
    func apiErrorDescriptions() {
        let invalidURLError = APIError.invalidURL
        #expect(invalidURLError.errorDescription == "Invalid API URL")

        let invalidResponseError = APIError.invalidResponse
        #expect(invalidResponseError.errorDescription == "Invalid server response")

        let httpError = APIError.httpError(statusCode: 404)
        #expect(httpError.errorDescription == "HTTP error: 404")
    }

    @Test("APIError different status codes")
    func apiErrorStatusCodes() {
        let error400 = APIError.httpError(statusCode: 400)
        let error401 = APIError.httpError(statusCode: 401)
        let error500 = APIError.httpError(statusCode: 500)

        #expect(error400.errorDescription?.contains("400") == true)
        #expect(error401.errorDescription?.contains("401") == true)
        #expect(error500.errorDescription?.contains("500") == true)
    }

    @Test("APIClient initialization with configuration")
    func apiClientInitialization() {
        let config = SDKConfiguration(
            businessToken: "test-business-token-123",
            foregroundScanInterval: .seconds10,
            backgroundScanInterval: .seconds60
        )

        let apiClient = APIClient(configuration: config)

        // Verify client initializes without crashing
        #expect(apiClient != nil)
    }

    @Test("API payload structure validation")
    func apiPayloadStructure() {
        // Test that we can create the models needed for API payload
        let sdkInfo = SDKInfo(
            appId: "test-app",
            build: 100
        )

        #expect(sdkInfo.appId == "test-app")
        #expect(sdkInfo.build == 100)
        #expect(sdkInfo.version == "2.2.0")
        #expect(sdkInfo.platform == "ios")
    }
}
