// Copyright © 2024 Apple Inc. All Rights Reserved.

// APPLE INC.
// PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT
// PLEASE READ THE FOLLOWING PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT (“AGREEMENT”) CAREFULLY BEFORE DOWNLOADING OR USING THE APPLE SOFTWARE ACCOMPANYING THIS AGREEMENT(AS DEFINED BELOW). BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING TO BE BOUND BY THE TERMS OF THIS AGREEMENT. IF YOU DO NOT AGREE TO THE TERMS OF THIS AGREEMENT, DO NOT DOWNLOAD OR USE THE APPLE SOFTWARE. THESE TERMS AND CONDITIONS CONSTITUTE A LEGAL AGREEMENT BETWEEN YOU AND APPLE.
// IMPORTANT NOTE: BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING ON YOUR OWN BEHALF AND/OR ON BEHALF OF YOUR COMPANY OR ORGANIZATION TO THE TERMS OF THIS AGREEMENT.
// 1. As used in this Agreement, the term “Apple Software” collectively means and includes all of the Apple Private Cloud Compute materials provided by Apple here, including but not limited to the Apple Private Cloud Compute software, tools, data, files, frameworks, libraries, documentation, logs and other Apple-created materials. In consideration for your agreement to abide by the following terms, conditioned upon your compliance with these terms and subject to these terms, Apple grants you, for a period of ninety (90) days from the date you download the Apple Software, a limited, non-exclusive, non-sublicensable license under Apple’s copyrights in the Apple Software to download, install, compile and run the Apple Software internally within your organization only on a single Apple-branded computer you own or control, for the sole purpose of verifying the security and privacy characteristics of Apple Private Cloud Compute. This Agreement does not allow the Apple Software to exist on more than one Apple-branded computer at a time, and you may not distribute or make the Apple Software available over a network where it could be used by multiple devices at the same time. You may not, directly or indirectly, redistribute the Apple Software or any portions thereof. The Apple Software is only licensed and intended for use as expressly stated above and may not be used for other purposes or in other contexts without Apple's prior written permission. Except as expressly stated in this notice, no other rights or licenses, express or implied, are granted by Apple herein.
// 2. The Apple Software is provided by Apple on an "AS IS" basis. APPLE MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS, SYSTEMS, OR SERVICES. APPLE DOES NOT WARRANT THAT THE APPLE SOFTWARE WILL MEET YOUR REQUIREMENTS, THAT THE OPERATION OF THE APPLE SOFTWARE WILL BE UNINTERRUPTED OR ERROR-FREE, THAT DEFECTS IN THE APPLE SOFTWARE WILL BE CORRECTED, OR THAT THE APPLE SOFTWARE WILL BE COMPATIBLE WITH FUTURE APPLE PRODUCTS, SOFTWARE OR SERVICES. NO ORAL OR WRITTEN INFORMATION OR ADVICE GIVEN BY APPLE OR AN APPLE AUTHORIZED REPRESENTATIVE WILL CREATE A WARRANTY.
// 3. IN NO EVENT SHALL APPLE BE LIABLE FOR ANY DIRECT, SPECIAL, INDIRECT, INCIDENTAL OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION, COMPILATION OR OPERATION OF THE APPLE SOFTWARE, HOWEVER CAUSED AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE), STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
// 4. This Agreement is effective until terminated. Your rights under this Agreement will terminate automatically without notice from Apple if you fail to comply with any term(s) of this Agreement. Upon termination, you agree to cease all use of the Apple Software and destroy all copies, full or partial, of the Apple Software. This Agreement constitutes the entire understanding of the parties with respect to the subject matter contained herein, and supersedes all prior negotiations, representations, or understandings, written or oral. This Agreement will be governed and construed in accordance with the laws of the State of California, without regard to its choice of law rules.
// You may report security issues about Apple products to product-security@apple.com, as described here: https://www.apple.com/support/security/. Non-security bugs and enhancement requests can be made via https://bugreport.apple.com as described here: https://developer.apple.com/bug-reporting/
// EA1937
// 10/02/2024

//
//  TC2BatchedPrefetch.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import Foundation
import InternalSwiftProtobuf
@_spi(HTTP) @_spi(OHTTP) @_spi(NWActivity) import Network
import PrivateCloudCompute
import Security
import os.lock

enum TC2FetchType: Equatable {
    case fetchAllBatches
    case fetchSingleBatch(batchID: UInt)
}

private enum Constants {
    static let maximumConcurrentAttestationVerifications = 10
    static let maximumExpiryDuration: TimeInterval = 60 * 60 * 24 * 2
    static let prewarmAttestationsAvailabilityBatchCount = 3
}

// A TC2PrefetchRequest prefetches attestations from ROPES server
// This request does not talk to Thimble nodes directly
final class TC2BatchedPrefetch<
    ConnectionFactory: NWAsyncConnectionFactoryProtocol,
    AttestationStore: TC2AttestationStoreProtocol,
    RateLimiter: RateLimiterProtocol,
    AttestationVerifier: TC2AttestationVerifier,
    SystemInfo: SystemInfoProtocol
>: Sendable {
    private let encoder = tc2JSONEncoder()
    private let logger = tc2Logger(forCategory: .prefetchRequest)
    private let connectionFactory: ConnectionFactory
    private let attestationStore: AttestationStore
    private let rateLimiter: RateLimiter
    private let attestationVerifier: AttestationVerifier
    private let config: TC2Configuration
    private let serverDrivenConfig: TC2ServerDrivenConfiguration
    private let systemInfo: SystemInfo
    private let parameters: TC2RequestParameters
    private let eventStreamContinuation: AsyncStream<ThimbledEvent>.Continuation
    private let prewarm: Bool
    private let bundleIdentifier: String?
    private let featureIdentifier: String?
    private let fetchType: TC2FetchType
    private let batchUUID: UUID = UUID()

    init(
        connectionFactory: ConnectionFactory,
        attestationStore: AttestationStore,
        rateLimiter: RateLimiter,
        attestationVerifier: AttestationVerifier,
        config: TC2Configuration,
        serverDrivenConfig: TC2ServerDrivenConfiguration,
        systemInfo: SystemInfo,
        parameters: TC2RequestParameters,
        eventStreamContinuation: AsyncStream<ThimbledEvent>.Continuation,
        prewarm: Bool,
        fetchType: TC2FetchType,
        bundleIdentifier: String? = nil,
        featureIdentifier: String? = nil
    ) {
        self.connectionFactory = connectionFactory
        self.attestationStore = attestationStore
        self.rateLimiter = rateLimiter
        self.attestationVerifier = attestationVerifier
        self.config = config
        self.serverDrivenConfig = serverDrivenConfig
        self.systemInfo = systemInfo
        self.parameters = parameters
        self.eventStreamContinuation = eventStreamContinuation
        self.prewarm = prewarm
        self.bundleIdentifier = bundleIdentifier
        self.featureIdentifier = featureIdentifier
        self.fetchType = fetchType
    }

    private func fetchBatch(
        batchUUID: UUID,
        requestID: UUID,
        requestIDForReporting: UUID,
        batchID: UInt,
        fetchTime: Date,
        headers: HTTPFields,
        prefetchParameters: TC2RequestParameters,
        workloadParametersAsString: String,
        maxAttestations: Int
    ) async throws -> (response: Prefetch.Response, successfulSaveCount: Int) {
        var successfulSaveCount = 0
        var response = Prefetch.Response(id: requestID, nodes: [])

        let logPrefix = "\(requestID):"
        self.logger.log("\(logPrefix) executing prefetch request")
        defer {
            self.logger.log("\(logPrefix) finished prefetch request")
        }

        let environment = self.config.environment(systemInfo: self.systemInfo)

        try await self.connectionFactory.connect(
            parameters: .makeTLSAndHTTPParameters(
                ignoreCertificateErrors: self.config[.ignoreCertificateErrors],
                forceOHTTP: environment.forceOHTTP,
                useCompression: true,
                bundleIdentifier: self.bundleIdentifier
            ),
            endpoint: .url(environment.ropesUrl),
            activity: NWActivity(domain: .cloudCompute, label: .attestationPrefetch),
            on: .main,
            requestID: requestID
        ) { inbound, outbound, _ in
            self.logger.log("\(logPrefix) sending request with parameters: \(workloadParametersAsString)")

            // Client should hint maxAttestations to save attestations processed per request
            let prefetchRequest = Proto_Ropes_HttpService_PrefetchRequest.with {
                $0.capabilities.attestationStreaming = true
                $0.clientRequestedAttestationCount = UInt32(maxAttestations)
            }
            let prefetchRequestData = try prefetchRequest.serializedData()

            let httpRequest = HTTPRequest(
                method: .post,
                scheme: "https",
                authority: environment.ropesHostname,
                path: self.config[.prefetchRequestPath],
                headerFields: headers
            )

            self.logger.log("\(logPrefix) sending request: \(String(reflecting: httpRequest)) with parameters: \(workloadParametersAsString)")
            self.logger.log("\(logPrefix) headers: \(String(describing: headers))")
            try await outbound.write(
                content: prefetchRequestData,
                contentContext: .init(request: httpRequest),
                isComplete: true
            )

            self.logger.info("\(logPrefix) waiting for response")

            let deframed =
                inbound
                .onHTTPResponseHead { response in
                    self.logger.info("\(logPrefix) response head received: \(String(describing: response)); headers: \(String(describing: response.headerFields))")
                    guard response.status == .ok else {
                        throw PrefetchRequestError(
                            code: .unexpectedStatusCode,
                            underlying: PrefetchRequestError.UnexpectedStatusCode(statusCode: response.status.code)
                        )
                    }
                    await self.attestationStore.deleteEntries(withParameters: prefetchParameters, batchId: batchID)
                } onTrailers: { trailers in
                    self.logger.info("\(logPrefix) response trailers received: \(String(describing: trailers))")
                }
                .deframed(lengthType: UInt32.self, messageType: Proto_Ropes_HttpService_PrefetchResponse.self)

            var attestationsReceived = 0
            var nodeIDsReceived: [String] = []

            await withTaskGroup(of: Prefetch.Response.Node.self) { taskGroup in
                do {
                    var concurrentAttestationVerifications: Int = 0

                    for try await message in deframed {
                        messageProcessing: switch message.type {
                        case .attestation(let attestation):
                            self.logger.debug("\(logPrefix) attestation received")
                            attestationsReceived += 1
                            if concurrentAttestationVerifications == Constants.maximumConcurrentAttestationVerifications {
                                // save to bang! We have more than Constants.maximumConcurrentAttestationVerifications
                                // currently running, because of this there is definitely a task that we can await here.
                                let node = await taskGroup.next()!
                                concurrentAttestationVerifications -= 1

                                if node.savedToCache {
                                    successfulSaveCount += 1
                                }

                                // Having verified the attestation, we now can collect its hardware
                                // identifier for publishing to the event stream that tracks the
                                // distribution of nodes. See rdar://135384108 for details.
                                if let uniqueNodeIdentifier = node.uniqueNodeIdentifier {
                                    nodeIDsReceived.append(uniqueNodeIdentifier)
                                }

                                response.nodes.append(node)
                            }

                            if response.nodes.count >= maxAttestations {
                                // We should only process maxAttestations count of attestations, even if ROPES sends us more
                                break messageProcessing
                            }

                            concurrentAttestationVerifications += 1
                            taskGroup.addTask {
                                await self.verifyAndStore(
                                    attestation: attestation,
                                    prefetchParameters: prefetchParameters,
                                    prewarm: self.prewarm,
                                    requestID: requestID,
                                    requestIDForReporting: requestIDForReporting,
                                    batchID: batchID,
                                    fetchTime: fetchTime
                                )
                            }

                        case .rateLimitConfigurationList(let rateLimitConfigurationList):
                            self.logger.log("\(logPrefix) received rate limit configuration count \(rateLimitConfigurationList.rateLimitConfiguration.count)")
                            for proto in rateLimitConfigurationList.rateLimitConfiguration {
                                if let rateLimitConfig = RateLimitConfiguration(now: Date.now, proto: proto, config: config) {
                                    await self.rateLimiter.limitByConfiguration(rateLimitConfig)
                                } else {
                                    self.logger.error("\(logPrefix) unable to process rate limit configuration \(String(describing: proto))")
                                }
                            }
                            await self.rateLimiter.save()

                        case .none:
                            break
                        }
                    }

                    self.logger.info("\(logPrefix) response complete")

                    // the http stream has finished, lets await all the running verifications
                    while let node = await taskGroup.next() {
                        concurrentAttestationVerifications -= 1

                        if node.savedToCache {
                            successfulSaveCount += 1
                        }

                        // Having verified the attestation, we now can collect its hardware
                        // identifier for publishing to the event stream that tracks the
                        // distribution of nodes. See rdar://135384108 for details.
                        if let uniqueNodeIdentifier = node.uniqueNodeIdentifier {
                            nodeIDsReceived.append(uniqueNodeIdentifier)
                        }

                        response.nodes.append(node)
                    }
                    assert(concurrentAttestationVerifications == 0)
                } catch {
                    self.logger.error("\(logPrefix) response failed: \(String(describing: error))")
                }
            }

            if attestationsReceived == 0 {
                throw TrustedCloudComputeError(message: "prefetch returned empty response")
            }

            // note that we have received these attestations/nodes
            self.eventStreamContinuation.yield(.nodesReceived(nodeIDs: nodeIDsReceived, fromSource: self.prewarm ? .prewarm : .prefetch))
        }

        return (response, successfulSaveCount)
    }

    func sendRequest() async throws -> [Prefetch.Response] {
        let logPrefix = "\(self.batchUUID):"
        self.logger.log("\(logPrefix) executing batch of prefetch requests, prewarm=\(self.prewarm)")
        defer {
            self.logger.log("\(logPrefix) finished batch of prefetch requests")
        }

        var response: [Prefetch.Response] = []

        // Get the prefetch parameters needed from invoke parameters
        guard let prefetchParameters = TC2PrefetchParameters().prefetchParameters(invokeParameters: parameters) else {
            self.logger.error("\(logPrefix) invalid set of parameters for prefetching")
            return response
        }

        let workloadParametersAsJSON = try self.encoder.encode(prefetchParameters.pipelineArguments)
        let workloadParametersAsString = String(data: workloadParametersAsJSON, encoding: .utf8) ?? ""

        // maxPrefetchedAttestations is capped to 60
        let maxPrefetchedAttestationsFromConfig = self.config[.maxPrefetchedAttestations]
        let maxPrefetchedAttestationsFromServerConfig = self.serverDrivenConfig.maxPrefetchedAttestations ?? maxPrefetchedAttestationsFromConfig
        let maxAttestationsPerRequest = max(1, min(maxPrefetchedAttestationsFromServerConfig, maxPrefetchedAttestationsFromConfig))
        let maxPrefetchBatches = max(1, self.serverDrivenConfig.maxPrefetchBatches ?? self.config[.maxPrefetchBatches])

        let batchIDsToFetch: ClosedRange<UInt>
        switch self.fetchType {
        case .fetchAllBatches:
            batchIDsToFetch = 0...UInt(maxPrefetchBatches - 1)
        case .fetchSingleBatch(let batchID):
            batchIDsToFetch = batchID...batchID
        }

        let prewarmAttestationsAvailability = maxAttestationsPerRequest * Constants.prewarmAttestationsAvailabilityBatchCount
        self.logger.log(
            "\(logPrefix) configuration: maxPrefetchedAttestations: \(maxAttestationsPerRequest), clientCacheSize: \(maxAttestationsPerRequest * batchIDsToFetch.count), maxPrefetchRequests: \(batchIDsToFetch.count), maxPrefetchBatches: \(maxPrefetchBatches), prewarmAttestationsAvailability: \(prewarmAttestationsAvailability)"
        )

        // Check if we have valid prefetched or prewarmed attestations before issuing a prewarm for the set of parameters
        // Skip the check if we are fetching just a single batch to top up the cache after an invoke request consumed a batch
        if fetchType == .fetchAllBatches {
            let attestationsValidityInSeconds = serverDrivenConfig.prewarmAttestationsValidityInSeconds ?? self.config[.prewarmAttestationsValidityInSeconds]
            let fetchTime = Date() - attestationsValidityInSeconds
            if await self.attestationStore.attestationsExist(
                forParameters: prefetchParameters,
                clientCacheSize: prewarmAttestationsAvailability,
                fetchTime: fetchTime
            ) {
                self.logger.error("\(logPrefix) not prefetching, attestations exist for workload")
                throw TrustedCloudComputeError(message: "attestations exist for workload")
            }
        }

        var headers = HTTPFields([
            .init(name: .appleClientInfo, value: self.systemInfo.osInfo),
            .init(name: .appleWorkload, value: prefetchParameters.pipelineKind),
            .init(name: .appleWorkloadParameters, value: workloadParametersAsString),
            .init(name: .contentType, value: HTTPField.Constants.contentTypeApplicationXProtobuf),
            .init(name: .userAgent, value: HTTPField.Constants.userAgentTrustedCloudComputeD),
        ])

        if prewarm {
            // Caller should have supplied a featureIdentifier and a bundleIdentifier here
            guard let bundleID = bundleIdentifier else {
                self.logger.error("\(logPrefix) not prefetching, missing bundleIdentifier")
                throw TrustedCloudComputeError(message: "missing bundleIdentifier")
            }
            guard let featureID = featureIdentifier else {
                self.logger.error("\(logPrefix) not prefetching, missing featureIdentifier")
                throw TrustedCloudComputeError(message: "missing featureIdentifier")
            }
            headers[HTTPField.Name.appleBundleID] = bundleID
            headers[HTTPField.Name.appleFeatureID] = featureID
        } else {
            // Prefetches carry default values for these fields
            headers[HTTPField.Name.appleBundleID] = Bundle.main.bundleIdentifier
            headers[HTTPField.Name.appleFeatureID] = "backgroundActivity.prefetchRequest"
        }

        if let automatedDeviceGroup = self.systemInfo.automatedDeviceGroup {
            headers[.appleAutomatedDeviceGroup] = automatedDeviceGroup
        }

        if let testOptionsHeader = self.config[.testOptions] {
            headers[HTTPField.Name.appleTestOptions] = testOptionsHeader
        }

        if let overrideCellID = self.config[.overrideCellID] {
            // if there is an overriden cell id, we want to send the server hint even in prefetch
            headers[HTTPField.Name.appleServerHint] = overrideCellID

            // and we need to mark that this is an override, so server knows to force it.
            headers[HTTPField.Name.appleServerHintForReal] = "true"
        }

        // Is fetchTime actually supposed to be the same for every batch? It winds up in the
        // attestation store so it is hard to know what the impact will be.
        let fetchTime = Date()
        self.logger.log("\(logPrefix) fetchTime: \(fetchTime)")

        for batchID in batchIDsToFetch {
            let logPrefix = "\(self.batchUUID)#\(batchID):"

            // We will only ever try requestCount number of requests. It is a best case effort to try and fill up
            // the cache upto clientCacheSize, but if ROPES doesn't have any more attestations, we will need to bail
            let requestID = UUID()

            let requestIDForReporting: UUID
            switch self.config.environment(systemInfo: self.systemInfo) {
            case .production:
                // we need to have a different UUID for reporting for PROD due to privacy concerns
                requestIDForReporting = UUID()
                self.logger.log("\(logPrefix) Request: \(requestID) RequestIDForReporting: \(requestIDForReporting)")
            default:
                requestIDForReporting = requestID
            }

            headers[HTTPField.Name.appleRequestUUID] = requestID.uuidString

            do {

                let batchResponse: Prefetch.Response
                let saveCount: Int
                (batchResponse, saveCount) = try await fetchBatch(
                    batchUUID: self.batchUUID,
                    requestID: requestID,
                    requestIDForReporting: requestIDForReporting,
                    batchID: batchID,
                    fetchTime: fetchTime,
                    headers: headers,
                    prefetchParameters: prefetchParameters,
                    workloadParametersAsString: workloadParametersAsString,
                    maxAttestations: maxAttestationsPerRequest
                )

                // batchResponse is just for thtool to print out the nodes, it will have duplicate nodes as well
                response.append(batchResponse)
                let duplicates = batchResponse.nodes.count - saveCount
                self.logger.log("\(logPrefix) attestations saved: \(saveCount) duplicates: \(duplicates)")
            } catch {
                self.logger.error("\(logPrefix) failed to fetch batch error: \(error)")
                throw error
            }
        }

        return response
    }

    private func verifyAndStore(
        attestation: Proto_Ropes_Common_Attestation,
        prefetchParameters: TC2RequestParameters,
        prewarm: Bool,
        requestID: UUID,
        requestIDForReporting: UUID,
        batchID: UInt,
        fetchTime: Date
    ) async -> Prefetch.Response.Node {
        let logPrefix = "\(requestID):"

        // Check if we have this attestation in our store already
        do {
            // Get the unique identifier for the node received from ROPES
            if let uid = try await self.attestationVerifier.uniqueNodeIdentifier(attestation: .init(attestation: attestation, requestParameters: prefetchParameters)) {
                if await self.attestationStore.nodeExists(withUniqueIdentifier: uid) {
                    self.logger.log("\(logPrefix) node exists in store for attestation \(uid) \(attestation.nodeIdentifier)")
                    // Track this node for the parameter set
                    let nodeAlreadyTrackedInBatch = await self.attestationStore.trackNodeForParameters(
                        forParameters: prefetchParameters,
                        withUniqueIdentifier: uid,
                        prefetched: !prewarm,
                        batchID: batchID,
                        fetchTime: fetchTime)
                    if nodeAlreadyTrackedInBatch {
                        // Batch contains the node already, mark this as a duplicate node for the current batch
                        return .init(
                            identifier: attestation.nodeIdentifier,
                            cloudOSVersion: attestation.cloudosVersion,
                            cloudOSReleaseType: attestation.cloudosReleaseType,
                            validationResult: .nodeAlreadyExistsInBatch,
                            savedToCache: false,
                            uniqueNodeIdentifier: uid
                        )
                    } else {
                        // We did add tracking, but didn't need to validate the node because a validated one exists already
                        return .init(
                            identifier: attestation.nodeIdentifier,
                            cloudOSVersion: attestation.cloudosVersion,
                            cloudOSReleaseType: attestation.cloudosReleaseType,
                            validationResult: .validationNotNeeded,
                            savedToCache: true,
                            uniqueNodeIdentifier: uid
                        )
                    }
                }
            } else {
                self.logger.error("\(logPrefix) unique identifier for attestation \(attestation.nodeIdentifier) missing")
                return .init(
                    identifier: attestation.nodeIdentifier,
                    cloudOSVersion: attestation.cloudosVersion,
                    cloudOSReleaseType: attestation.cloudosReleaseType,
                    validationResult: .noUniqueIdentifier,
                    savedToCache: false,
                    uniqueNodeIdentifier: nil
                )
            }
        } catch {
            self.logger.error("\(logPrefix) unable to check the unique id of the attestation and hence skipping validation: \(attestation.nodeIdentifier)")
            return .init(
                identifier: attestation.nodeIdentifier,
                cloudOSVersion: attestation.cloudosVersion,
                cloudOSReleaseType: attestation.cloudosReleaseType,
                validationResult: .invalid(error: String(describing: error)),
                savedToCache: false,
                uniqueNodeIdentifier: nil
            )
        }

        // Validate the received attestation
        let validationStartTime = Date()
        do {
            let validatedAttestation = try await self.attestationVerifier.validate(
                attestation: .init(attestation: attestation, requestParameters: prefetchParameters)
            )
            var savedToCache = false

            // Check if we ever got a unique identifier for this attestation before storing
            guard let uniqueNodeIdentifier = validatedAttestation.uniqueNodeIdentifier else {
                self.logger.error("\(logPrefix) attestation validation did not return a unique id for attestation: \(attestation.nodeIdentifier)")
                return .init(
                    identifier: attestation.nodeIdentifier,
                    cloudOSVersion: attestation.cloudosVersion,
                    cloudOSReleaseType: attestation.cloudosReleaseType,
                    validationResult: .noUniqueIdentifier,
                    savedToCache: savedToCache,
                    uniqueNodeIdentifier: nil
                )
            }

            // Check attestation expiry times
            if validatedAttestation.attestationExpiry.timeIntervalSinceNow > Constants.maximumExpiryDuration {
                self.logger.error("\(logPrefix) attestation validation returned too long expiration for attestation: \(attestation.nodeIdentifier); expiry: \(validatedAttestation.attestationExpiry)")
                return .init(
                    identifier: attestation.nodeIdentifier,
                    cloudOSVersion: attestation.cloudosVersion,
                    cloudOSReleaseType: attestation.cloudosReleaseType,
                    validationResult: .validatedExpiryTooLarge,
                    savedToCache: savedToCache,
                    uniqueNodeIdentifier: nil
                )
            }

            // Attempt to save the validated attestation to the cache
            if await self.attestationStore.saveValidatedAttestation(validatedAttestation, for: prefetchParameters, prefetched: !prewarm, batch: batchID, fetchTime: fetchTime) {
                self.logger.log("\(logPrefix) successfully saved attestation for node: \(attestation.nodeIdentifier)")
                savedToCache = true
            } else {
                self.logger.log("\(logPrefix) failed to save attestation for node: \(attestation.nodeIdentifier)")
            }

            return .init(
                identifier: attestation.nodeIdentifier,
                cloudOSVersion: attestation.cloudosVersion,
                cloudOSReleaseType: attestation.cloudosReleaseType,
                validationResult: .valid(publicKey: validatedAttestation.publicKey, expiry: validatedAttestation.attestationExpiry),
                savedToCache: savedToCache,
                uniqueNodeIdentifier: uniqueNodeIdentifier
            )
        } catch {
            self.logger.error("\(logPrefix) attestation validation failed for node: \(attestation.nodeIdentifier) with error: \(error)")

            // we need to report this error
            var verificationErrorMetric = TC2AttestationnVerificationErrorMetric(bundleID: self.bundleIdentifier)
            verificationErrorMetric.fields[.clientRequestid] = .string(requestIDForReporting.uuidString)
            verificationErrorMetric.fields[.eventTime] = .int(Int64(Date().timeIntervalSince1970))
            verificationErrorMetric.fields[.environment] = .string(self.config.environment(systemInfo: self.systemInfo).name)
            verificationErrorMetric.fields[.clientInfo] = .string(self.systemInfo.osInfo)
            if let featureID = self.featureIdentifier {
                verificationErrorMetric.fields[.featureID] = .string(featureID)
            }
            if let bundleID = self.bundleIdentifier {
                verificationErrorMetric.fields[.bundleID] = .string(bundleID)
            }
            verificationErrorMetric.fields[.locale] = .string(Locale.current.identifier)
            // this is true because we are on prefetch flow here
            verificationErrorMetric.fields[.isPrefetchedAttestation] = true
            verificationErrorMetric.fields[.attestationVerificationNodeIdentifier] = .string(attestation.nodeIdentifier)
            verificationErrorMetric.fields[.attestationVerificationError] = error.telemetryString
            let validationDurationMs = Int64(Date().timeIntervalSince(validationStartTime) * 1000)
            verificationErrorMetric.fields[.attestationVerificationTime] = .int(validationDurationMs)
            self.eventStreamContinuation.yield(.exportMetric(verificationErrorMetric))

            return .init(
                identifier: attestation.nodeIdentifier,
                cloudOSVersion: attestation.cloudosVersion,
                cloudOSReleaseType: attestation.cloudosReleaseType,
                validationResult: .invalid(error: String(describing: error)),
                savedToCache: true,
                uniqueNodeIdentifier: nil
            )
        }
    }
}
