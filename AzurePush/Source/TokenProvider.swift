//
//  TokenProvider.swift
//  AzurePush
//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License.
//

import Foundation
import AzureCore

internal class TokenProvider {
    private static let defaultTokenTimeToLive: TimeInterval = 1200

    private struct Token {
        let value: String
        let obtainedAt: Date
        let timeToLive: TimeInterval

        var isExpired: Bool { return obtainedAt.addingTimeInterval(timeToLive) > Date() }
    }

    private let connectionParams: ConnectionParams
    private var cache: [URL: Token] = [:]

    internal init(connectionParams params: ConnectionParams) {
        self.connectionParams = params
    }

    internal func getToken(for url: URL, completion: @escaping (Response<String>) -> Void) {
        if let token = cache[url], !token.isExpired {
            completion(Response(request: nil, data: nil, response: nil, result: .success(token.value)))
            return
        }

        if let sharedAccessKey = connectionParams.sharedAccessKeyValue {
            getToken(for: url, andSharedAccessKey: sharedAccessKey, completion: completion)
            return
        }

        guard let request = getTokenRequest(for: url) else {
            completion(Response(request: nil, data: nil, response: nil, result: .failure(AzurePush.Error.unknown)))
            return
        }

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let httpResponse = response as? HTTPURLResponse

            if let error = error {
                completion(Response(request: request, data: data, response: httpResponse, result: .failure(error)))
                return
            }

            if let statusCode = httpResponse?.statusCode,
                let data = data,
                statusCode == 200 || statusCode == 201,
                let token = self?.extractToken(from: data) {
                self?.cache[url] = Token(value: token, obtainedAt: Date(), timeToLive: TokenProvider.defaultTokenTimeToLive)
                completion(Response(request: request, data: data, response: httpResponse, result: .success(token)))
                return
            }

            completion(Response(request: request, data: data, response: httpResponse, result: .failure(AzurePush.Error.failedToRetrieveAuthorizationToken)))
        }
    }

    private func getTokenRequest(for url: URL) -> URLRequest? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil

        guard let uri = components?.string?.addingPercentEncodingWithAzureAllowedCharacters(),
            let secret = Data(base64Encoded: connectionParams.sharedSecretValue),
            let secretString = String(data: secret, encoding: .utf8)
        else {
            return nil
        }

        let issuer = "Issuer=\(connectionParams.sharedSecretIssuer)"
        let signature = CryptoProvider.hmacSHA256(issuer, withKey: secretString)?.addingPercentEncodingWithAzureAllowedCharacters()
        let webToken = signature.flatMap { "\(issuer)&HMACSHA256=\($0)" }?.addingPercentEncodingWithAzureAllowedCharacters()

        guard let body = webToken.flatMap({ "wrap_scope=\(uri)&wrap_assertion_format=SWT&wrap_assertion=\($0)" }),
            let httpBody = body.data(using: .utf8),
            let stsUrl = URL(string: "\(connectionParams.stsHostName.absoluteString)/WRAPv0.9/")
        else {
            return nil
        }


        var request = URLRequest(url: stsUrl, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60.0)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("0", forHTTPHeaderField: "ContentLength")
        request.httpBody = httpBody

        return request
    }

    private func getToken(for url: URL, andSharedAccessKey sharedAccessKey: String, completion: @escaping (Response<String>) -> Void) {
        let expiresOn = Date().addingTimeInterval(TokenProvider.defaultTokenTimeToLive).timeIntervalSince1970
        let audienceUri = url.absoluteString.replacingOccurrences(of: "https", with: "http").addingPercentEncodingWithAzureAllowedCharacters()?.lowercased()
        let signature = audienceUri.flatMap { CryptoProvider.hmacSHA256("\($0)\n\(expiresOn)", withKey: sharedAccessKey).addingPercentEncodingWithAzureAllowedCharacters() }

        if let sharedAccessKeyName = connectionParams.sharedAccessKeyName, let audienceUri = audienceUri, let signature = signature {
            let token = "SharedAccessSignature sr=\(audienceUri)&sig=\(signature)&se=\(expiresOn)&skn=\(sharedAccessKeyName)"
            completion(Response(request: nil, data: nil, response: nil, result: .success(token)))
            return
        }

        completion(Response(request: nil, data: nil, response: nil, result: .failure(AzurePush.Error.failedToRetrieveAuthorizationToken)))
    }

    private func extractToken(from data: Data) -> String? {
        guard let string = String(data: data, encoding: .utf8) else { return nil }

        let keyValuePairs = string.components(separatedBy: "&")
                                  .map { $0.components(separatedBy: "=") }

        guard let tokenKeyValuePair = keyValuePairs.first(where: { $0.count == 2 && $0[0] == "wrap_access_token" }) else { return nil }

        return "WRAP access_token=\"\(tokenKeyValuePair[1])\""
    }
}

extension String {
    func addingPercentEncodingWithAzureAllowedCharacters() -> String? {
        let allowed = NSMutableCharacterSet.alphanumeric()
        allowed.addCharacters(in: "!*'();:@&=+$,/?%#[]")
        return self.addingPercentEncoding(withAllowedCharacters: allowed as CharacterSet)
    }
}