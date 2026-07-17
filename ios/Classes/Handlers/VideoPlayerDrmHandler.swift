import AVFoundation
import Foundation

/// Handles DRM (Digital Rights Management) for protected content playback
/// Supports FairPlay Streaming and AES-128 (Standard HLS Encryption)
class VideoPlayerDrmHandler: NSObject {
    private var contentKeySession: AVContentKeySession?
    private var drmConfig: [String: Any]
    private var certificateData: Data?
    private var certificateError: Error?
    private var pendingKeyRequests: [AVContentKeyRequest] = []
    private var certificateUrl: URL?
    private var licenseUrl: URL?
    private var licenseHeaders: [String: String]?
    private let certificateEncoding: String
    private let licenseRequestFormat: String
    private let licenseResponseEncoding: String
    private let delegateQueue = DispatchQueue(label: "com.better_native_video_player.drm")
    
    init(drmConfig: [String: Any]) {
        self.drmConfig = drmConfig
        self.certificateEncoding = (drmConfig["certificateEncoding"] as? String)?.lowercased() ?? "binary"
        self.licenseRequestFormat = (drmConfig["licenseRequestFormat"] as? String)?.lowercased() ?? "binary"
        self.licenseResponseEncoding = (drmConfig["licenseResponseEncoding"] as? String)?.lowercased() ?? "binary"
        
        // Extract configuration values
        if let licenseUrlString = drmConfig["licenseUrl"] as? String {
            self.licenseUrl = URL(string: licenseUrlString)
        }
        
        if let certificateUrlString = drmConfig["certificateUrl"] as? String {
            self.certificateUrl = URL(string: certificateUrlString)
        }
        
        if let headers = drmConfig["headers"] as? [String: String] {
            self.licenseHeaders = headers
        }
        
        super.init()
    }
    
    /// Sets up DRM for the given asset
    /// - Parameters:
    ///   - asset: The AVURLAsset to configure DRM for
    ///   - completion: Completion handler called when setup is complete
    func setupDRM(asset: AVURLAsset, completion: @escaping (Bool, Error?) -> Void) {
        guard let drmType = drmConfig["type"] as? String else {
            completion(false, NSError(domain: "VideoPlayerDrmHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "DRM type not specified"]))
            return
        }
        
        let drmTypeLower = drmType.lowercased()
        
        // For AES-128 (standard HLS encryption), headers passed to AVURLAsset should be sufficient
        // AVPlayer will automatically handle key requests for standard HLS encryption
        if drmTypeLower == "aes-128" {
            npLog("🔐 DRM: AES-128 detected - using standard HLS encryption")
            completion(true, nil)
            return
        }
        
        // For FairPlay, we need to set up AVContentKeySession
        if drmTypeLower == "fairplay" {
            setupFairPlay(asset: asset, completion: completion)
        } else {
            let error = NSError(domain: "VideoPlayerDrmHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported DRM type: \(drmType)"])
            completion(false, error)
        }
    }
    
    /// Sets up FairPlay DRM
    private func setupFairPlay(asset: AVURLAsset, completion: @escaping (Bool, Error?) -> Void) {
        guard let licenseUrl = licenseUrl else {
            let error = NSError(domain: "VideoPlayerDrmHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "License URL is required for FairPlay"])
            completion(false, error)
            return
        }

        guard let certificateUrl = certificateUrl else {
            let error = drmError("Certificate URL is required for FairPlay")
            completion(false, error)
            return
        }

        guard ["binary", "base64"].contains(certificateEncoding) else {
            let error = drmError("Unsupported FairPlay certificateEncoding: \(certificateEncoding)")
            completion(false, error)
            return
        }

        guard ["binary", "base64form"].contains(licenseRequestFormat) else {
            let error = drmError("Unsupported FairPlay licenseRequestFormat: \(licenseRequestFormat)")
            completion(false, error)
            return
        }

        guard ["binary", "base64"].contains(licenseResponseEncoding) else {
            let error = drmError("Unsupported FairPlay licenseResponseEncoding: \(licenseResponseEncoding)")
            completion(false, error)
            return
        }
        
        npLog("🔐 DRM: Setting up FairPlay - License URL: \(licenseUrl.absoluteString)")
        
        // Create content key session
        contentKeySession = AVContentKeySession(keySystem: AVContentKeySystem.fairPlayStreaming)

        // Set delegate and queue
        contentKeySession?.setDelegate(self, queue: delegateQueue)
        
        // Add asset to content key session
        contentKeySession?.addContentKeyRecipient(asset)
        
        fetchCertificate(url: certificateUrl) { [weak self] result in
            guard let self = self else { return }

            self.delegateQueue.async {
                switch result {
                case .success(let certificateData):
                    self.certificateData = certificateData
                    self.certificateError = nil
                    npLog("🔐 DRM: Certificate fetched successfully (\(certificateData.count) decoded bytes)")
                    completion(true, nil)

                    let pendingRequests = self.pendingKeyRequests
                    self.pendingKeyRequests.removeAll()
                    for keyRequest in pendingRequests {
                        self.processFairPlayKeyRequest(keyRequest)
                    }
                case .failure(let error):
                    self.certificateError = error
                    npLog("🔐 DRM: Failed to fetch certificate: \(error.localizedDescription)")
                    completion(false, error)

                    let pendingRequests = self.pendingKeyRequests
                    self.pendingKeyRequests.removeAll()
                    for keyRequest in pendingRequests {
                        keyRequest.processContentKeyResponseError(error)
                    }
                }
            }
        }
    }
    
    /// Fetches the FairPlay application certificate
    private func fetchCertificate(url: URL, completion: @escaping (Result<Data, Error>) -> Void) {
        npLog("🔐 DRM: Fetching certificate from: \(url.absoluteString)")
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        // Add custom headers if provided
        if let headers = licenseHeaders {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                npLog("🔐 DRM: Certificate fetch error: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let error = NSError(domain: "VideoPlayerDrmHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch certificate: Invalid response"])
                completion(.failure(error))
                return
            }
            
            guard let data = data else {
                let error = NSError(domain: "VideoPlayerDrmHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch certificate: No data"])
                completion(.failure(error))
                return
            }

            do {
                let decodedData = try self.decode(data, encoding: self.certificateEncoding, label: "FairPlay certificate")
                completion(.success(decodedData))
            } catch {
                completion(.failure(error))
            }
        }
        
        task.resume()
    }
    
    /// Cleans up DRM resources
    func cleanup() {
        // Note: We can't remove specific assets from the session without tracking them
        // The session will be cleaned up when deallocated
        contentKeySession = nil
        certificateData = nil
        certificateError = nil
        pendingKeyRequests.removeAll()
        npLog("🔐 DRM: Cleaned up DRM handler")
    }

    private func processFairPlayKeyRequest(_ keyRequest: AVContentKeyRequest) {
        guard let licenseUrl = licenseUrl else {
            let error = drmError("License URL not configured")
            npLog("🔐 DRM: Error - \(error.localizedDescription)")
            keyRequest.processContentKeyResponseError(error)
            return
        }

        if let certificateError = certificateError {
            keyRequest.processContentKeyResponseError(certificateError)
            return
        }

        guard let certificateData = certificateData else {
            npLog("🔐 DRM: Certificate is still loading; queueing content key request")
            pendingKeyRequests.append(keyRequest)
            return
        }

        guard let contentIdentifierData = contentIdentifierData(for: keyRequest) else {
            let error = drmError("FairPlay content key request has no usable identifier")
            npLog("🔐 DRM: Error - \(error.localizedDescription)")
            keyRequest.processContentKeyResponseError(error)
            return
        }

        keyRequest.makeStreamingContentKeyRequestData(
            forApp: certificateData,
            contentIdentifier: contentIdentifierData,
            options: nil
        ) { [weak self] spcData, error in
            guard let self = self else { return }

            if let error = error {
                npLog("🔐 DRM: SPC generation failed: \(error.localizedDescription)")
                keyRequest.processContentKeyResponseError(error)
                return
            }

            guard let spcData = spcData else {
                let error = self.drmError("SPC generation returned no data")
                npLog("🔐 DRM: Error - \(error.localizedDescription)")
                keyRequest.processContentKeyResponseError(error)
                return
            }

            self.sendLicenseRequest(spcData: spcData, to: licenseUrl, for: keyRequest)
        }
    }

    private func contentIdentifierData(for keyRequest: AVContentKeyRequest) -> Data? {
        if let identifierData = keyRequest.identifier as? Data, !identifierData.isEmpty {
            return identifierData
        }

        let identifierString: String
        if let identifierUrl = keyRequest.identifier as? URL {
            identifierString = identifierUrl.absoluteString
        } else if let identifierUrl = keyRequest.identifier as? NSURL {
            identifierString = identifierUrl.absoluteString ?? ""
        } else if let value = keyRequest.identifier as? String {
            identifierString = value
        } else {
            return nil
        }

        let skdPrefix = "skd://"
        let contentIdentifier: String
        if identifierString.lowercased().hasPrefix(skdPrefix) {
            contentIdentifier = String(identifierString.dropFirst(skdPrefix.count))
        } else {
            contentIdentifier = identifierString
        }

        guard !contentIdentifier.isEmpty else { return nil }
        return contentIdentifier.data(using: .utf8)
    }

    private func sendLicenseRequest(spcData: Data, to licenseUrl: URL, for keyRequest: AVContentKeyRequest) {
        var request = URLRequest(url: licenseUrl)
        request.httpMethod = "POST"

        switch licenseRequestFormat {
        case "base64form":
            var formValueAllowedCharacters = CharacterSet.alphanumerics
            formValueAllowedCharacters.insert(charactersIn: "-._~")
            guard let encodedSpc = spcData.base64EncodedString().addingPercentEncoding(
                withAllowedCharacters: formValueAllowedCharacters
            ), let body = "spc=\(encodedSpc)".data(using: .utf8) else {
                let error = drmError("Could not encode FairPlay SPC form body")
                keyRequest.processContentKeyResponseError(error)
                return
            }
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        default:
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = spcData
        }

        if let headers = licenseHeaders {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        npLog("🔐 DRM: Sending license request to: \(licenseUrl.absoluteString)")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                npLog("🔐 DRM: License request error: \(error.localizedDescription)")
                keyRequest.processContentKeyResponseError(error)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                let error = self.drmError("License request failed with status code: \(statusCode)")
                npLog("🔐 DRM: License request failed: \(error.localizedDescription)")
                keyRequest.processContentKeyResponseError(error)
                return
            }

            guard let data = data, !data.isEmpty else {
                let error = self.drmError("No data in license response")
                npLog("🔐 DRM: License response error: \(error.localizedDescription)")
                keyRequest.processContentKeyResponseError(error)
                return
            }

            do {
                let ckcData = try self.decode(data, encoding: self.licenseResponseEncoding, label: "FairPlay CKC")
                let keyResponse = AVContentKeyResponse(fairPlayStreamingKeyResponseData: ckcData)
                keyRequest.processContentKeyResponse(keyResponse)
                npLog("🔐 DRM: License response processed successfully")
            } catch {
                npLog("🔐 DRM: Error processing license response: \(error.localizedDescription)")
                keyRequest.processContentKeyResponseError(error)
            }
        }.resume()
    }

    private func decode(_ data: Data, encoding: String, label: String) throws -> Data {
        guard encoding == "base64" else { return data }

        guard let encodedValue = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let decodedData = Data(base64Encoded: encodedValue),
              !decodedData.isEmpty else {
            let responseText = String(data: data, encoding: .utf8)?.prefix(512) ?? ""
            let suffix = responseText.isEmpty ? "" : ": \(responseText)"
            throw drmError("Invalid Base64-encoded \(label) response\(suffix)")
        }

        return decodedData
    }

    private func drmError(_ message: String) -> NSError {
        return NSError(
            domain: "VideoPlayerDrmHandler",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

// MARK: - AVContentKeySessionDelegate

extension VideoPlayerDrmHandler: AVContentKeySessionDelegate {
    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        npLog("🔐 DRM: Content key request received")
        processFairPlayKeyRequest(keyRequest)
    }
    
    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVPersistableContentKeyRequest) {
        // Handle persistable content key requests (for offline playback)
        npLog("🔐 DRM: Persistable content key request received")
        // For now, we'll handle it the same way as regular key requests
        contentKeySession(session, didProvide: keyRequest as AVContentKeyRequest)
    }
    
    func contentKeySession(_ session: AVContentKeySession, didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest) {
        // Handle renewing content key requests
        npLog("🔐 DRM: Renewing content key request received")
        contentKeySession(session, didProvide: keyRequest)
    }
    
    func contentKeySession(_ session: AVContentKeySession, shouldRetry keyRequest: AVContentKeyRequest, reason retryReason: String) -> Bool {
        npLog("🔐 DRM: Content key request should retry - reason: \(retryReason)")
        // Retry once for network errors
        return retryReason.contains("network") || retryReason.contains("timeout")
    }
}
